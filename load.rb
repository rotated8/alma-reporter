# frozen_string_literal:true
require 'faraday'
require 'faraday/retry'
require 'logger'
require 'marc'
require 'nokogiri'
require 'rsolr'

################### LOGGING SETUP
log = Logger.new('./import.log')
log.level = Logger::INFO
log.info('Starting')

################### ALMA CONSTANTS
ALMA = 'na03'
INST = '01GALI_EMORY'
SET  = ENV['ALMA_SET'] || 'blacklighttest'

OAI_BASE  = "https://#{ALMA}.alma.exlibrisgroup.com/view/oai/#{INST}/request"
NAMESPACE = { oai: 'http://www.openarchives.org/OAI/2.0/' }
qs = "?verb=ListRecords&set=#{SET}&metadataPrefix=marc21"

################### INDEXING CONSTANTS
# Controls what data gets passed into Solr.
COUNTS   = true
VALUES   = true
RAW_MARC = false
SOLR_URL = ENV['SOLR_URL'] || 'http://127.0.0.1:8983/solr/alma-data-core'

# Fallback identifier used if we encounter issues. Increments for each issue found.
backup_identifier = 0
# Counts the records sent to Solr.
total_docs = 0

################### SETUP
# With nokogiri required above, this should force XMLReader to use it.
MARC::XMLReader.best_available!

# Setup Faraday to retry Alma connection errors. https://github.com/lostisland/faraday-retry
oai_retry_options = {
  max: 3,
  interval: 2,
  interval_randomness: 0.9,
  backoff_factor: 2,
  exceptions: [Errno::ETIMEDOUT, Timeout::Error, Faraday::TimeoutError, Faraday::ConnectionFailed, Net::ReadTimeout],
  retry_block: -> (env:, options:, retry_count:, exception:, will_retry_in:) { log.error("Retrying OAI request. #{exception}") }
}
oai_conn = Faraday.new do |conn|
  conn.request(:retry, oai_retry_options)
  # You ought to verify SSL for your OAI source, but I won't tell if you don't.
  # conn.ssl.verify = false
end

# Setup Faraday to retry for Solr connection errors, too.
solr_retry_options = {
  max: 3,
  interval: 12,
  interval_randomness: 0.9,
  backoff_factor: 5,
  methods: %i[get post],
  exceptions: [Errno::ETIMEDOUT, Timeout::Error, Faraday::TimeoutError, Faraday::ConnectionFailed, Net::ReadTimeout, RSolr::Error::Timeout],
  retry_block: -> (env:, options:, retry_count:, exception:, will_retry_in:) { log.error("Retrying Solr commit. #{exception}") }
}
solr_conn = Faraday.new do |conn|
  conn.request(:retry, solr_retry_options)
  # Self-signed or expired cert? Uncomment the line below.
  # conn.ssl.verify = false
end
solr = RSolr.connect(solr_conn, url: SOLR_URL)

loop do
  ################# GET RECORDS
  log.debug('Getting records from OAI')
  begin
    oai_response = oai_conn.get("#{OAI_BASE}#{qs}")
  rescue => err
    log.fatal("Error retrieving OAI data: #{err}")
    log.close
    raise
  end
  document = Nokogiri::XML::Document.parse(oai_response.body)

  deleted_records = document.xpath('/oai:OAI-PMH/oai:ListRecords/oai:record[oai:header/@status="deleted"]', NAMESPACE)
  if deleted_records.count.positive?
    deleted_ids = deleted_records.map { |record| record.at('header/identifier').text.split(':').last }
    # Remove deleted-status records from the indexing set, and delete them from Solr.
    deleted_records.remove
    begin
      solr.delete_by_id(deleted_ids)
      solr.soft_commit
    rescue => err
      log.fatal("Error deleting docs: #{err}")
      log.close
      raise
    end
    log.info("Deleted records: #{deleted_ids}")
  end

  record_count = document.xpath('/oai:OAI-PMH/oai:ListRecords/oai:record', NAMESPACE).count
  log.info("#{record_count} records found")
  if record_count.positive?
    ############### INDEX RECORDS
    # Collect each solr doc from this file.
    docs = []

    # Rather than writing to disk only to read it right back, let's use StringIO
    reader = MARC::XMLReader.new(StringIO.new(document.to_s))

    log.debug('Creating solr docs')
    for record in reader
      # Perf improvement. Makes the fields immutable.
      record.fields.freeze

      # Solr doc accumulators. One for data, one for counts. All data fields are multivalued.
      doc_values = Hash.new { |hash, key| hash[key] = [] }
      doc_counts = Hash.new(0)

      if record.fields('001').count == 1
        doc_values['id'] = record.fields('001').first.value
      else
        # Record does not have one and only one identifier, use our backup to give it a fake one.
        log.error('Missing/multiple 001 tags')
        log.info("001s: #{record.fields('001')} mapped to #{backup_identifier}")
        doc_values['id'] = backup_identifier
        backup_identifier += 1
      end

      if !record.leader.strip.empty?
        doc_values['l_ldr_ssim'] << record.leader if VALUES
        doc_counts['l_ldr_isi'] += 1 if COUNTS
      end

      for field in record.fields
        # Strip non-alphanumeric characters from the tag. Solr can't handle them in fieldnames.
        solr_tag = field.tag.gsub(/[^A-z0-9]/, '_')

        # Always count the field as present.
        doc_counts["f_#{solr_tag}_isi"] += 1 if COUNTS

        if MARC::ControlField.control_tag?(field.tag)
          # Control field, so add the value. No indicators, subfields.
          doc_values["c_#{solr_tag}_ssim"] << field.value if VALUES
        else
          # Store the unique subfield codes in the this field
          doc_values["d_#{solr_tag}_ssim"].concat(field.codes).uniq! if VALUES
          doc_counts["d_#{solr_tag}_isi"] += field.codes(dedup=false).count if COUNTS

          # Data fields have indicators and subfields
          if !field.indicator1.strip.empty?
            doc_values["i_#{solr_tag}_ind1_ssim"] << field.indicator1 if VALUES
            doc_counts["i_#{solr_tag}_ind1_isi"] += 1 if COUNTS
          end

          if !field.indicator2.strip.empty?
            doc_values["i_#{solr_tag}_ind2_ssim"] << field.indicator2 if VALUES
            doc_counts["i_#{solr_tag}_ind2_isi"] += 1 if COUNTS
          end

          # Subfields have the actual data.
          for subfield in field.subfields
            # Strip non-alphanumeric characters from the subfield code, for Solr.
            solr_code = subfield.code.gsub(/[^A-z0-9]/, '_')

            doc_values["s_#{solr_tag}_#{solr_code}_ssim"] << subfield.value if VALUES
            doc_counts["s_#{solr_tag}_#{solr_code}_isi"] += 1 if COUNTS
          end
        end
      end

      # Store the whole MARC record, if required
      doc_values["raw_tsi"] = record.to_s if RAW_MARC

      doc_values.merge!(doc_counts) if COUNTS
      docs << doc_values
    end

    # Commit docs to Solr, catch errors.
    begin
      solr.add(docs, add_attributes: {commitWithin: 1000})
      # solr.commit # Hard commits can thrash your Solr. Avoid this unless necessary.
    rescue => err
      log.fatal("Error committing to Solr: #{err}")
      log.close
      raise
    end
    total_docs += docs.count
    log.info("#{docs.count} docs committed to Solr")
  end

  resumption_token = document.xpath('/oai:OAI-PMH/oai:ListRecords/oai:resumptionToken', NAMESPACE).text
  break if resumption_token == ''

  qs = "?verb=ListRecords&resumptionToken=#{resumption_token}"
  log.debug('Resuming')
end

log.info("Finished- #{total_docs} docs loaded in total")
log.close
