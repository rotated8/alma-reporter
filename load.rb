# frozen_string_literal:true
require 'faraday'
require 'faraday/retry'
require 'logger'
require 'marc'
require 'nokogiri'
require 'rsolr'

################### LOGGING SETUP
# Check out Ruby's standard library logging module for more documentation.
log = Logger.new('import.log')
log.level = Logger::INFO
log.debug('Starting')

################### ALMA CONSTANTS
ALMA = 'na03'
INST = '01GALI_EMORY'
SET  = ENV['ALMA_SET'] || 'blacklighttest'

OAI_BASE  = "https://#{ALMA}.alma.exlibrisgroup.com/view/oai/#{INST}/request"
NAMESPACE = { oai: 'http://www.openarchives.org/OAI/2.0/' }
qs = "?verb=ListRecords&set=#{SET}&metadataPrefix=marc21"

################### SOLR CONSTANTS
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
RETRY_OPTIONS = {
  max: 3,
  interval: 12,
  interval_randomness: 0.9,
  backoff_factor: 5,
  methods: %i[get post],
  exceptions: [Errno::ETIMEDOUT, Timeout::Error, Faraday::TimeoutError, Faraday::ConnectionFailed, Net::ReadTimeout, RSolr::Error::Timeout]
}

# With nokogiri required above, this should force XMLReader to use it.
MARC::XMLReader.best_available!

# Setup Faraday to retry Alma connection errors. https://github.com/lostisland/faraday-retry
oai_options = RETRY_OPTIONS.merge({ retry_block: -> (env:, options:, retry_count:, exception:, will_retry_in:) { log.error("Retrying OAI request. #{exception}") } })
oai_conn = Faraday.new do |conn|
  conn.request(:retry, oai_options)
end

# Setup Faraday to retry for Solr connection errors, too.
solr_options = RETRY_OPTIONS.merge({ retry_block: -> (env:, options:, retry_count:, exception:, will_retry_in:) { log.error("Retrying Solr request. #{exception}") } })
solr_conn = Faraday.new do |conn|
  conn.request(:retry, solr_options)
  # conn.ssl.verify = false # Self-signed or expired cert? Uncomment this line, get work done.
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
    log.info("#{deleted_ids.count} records removed")
    log.debug("Deleted record ids: #{deleted_ids}")
  end

  record_count = document.xpath('/oai:OAI-PMH/oai:ListRecords/oai:record', NAMESPACE).count
  log.info("#{record_count} records to index")
  if record_count.positive?
    ############### INDEX RECORDS
    # Collect each solr doc from this file.
    docs = []

    reader = MARC::XMLReader.new(StringIO.new(document.to_s))

    log.debug('Creating solr docs')
    for record in reader
      record.fields.freeze # Perf improvement. Makes the fields immutable.

      # Solr doc accumulators. One for data, one for counts. All data fields are multivalued.
      doc_values = Hash.new { |hash, key| hash[key] = [] }
      doc_counts = Hash.new(0)

      if record.fields('001').count == 1
        doc_values['id'] = record.fields('001').first.value
      else
        # Record does not have one and only one identifier, use our backup to give it a fake one.
        # Remember: all the values are stored in `c_001_ssim`, if you store values.
        log.error("Missing/multiple 001s: #{backup_identifier} used for #{record.fields('001')}")
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
        if solr_tag != field.tag
          log.info("Stripped #{field.tag} for #{doc_values['id']}")
          doc_values['escaped_tags'] << field.tag if VALUES or COUNTS
        end

        doc_counts["f_#{solr_tag}_isi"] += 1 if COUNTS # Always count the field as present.

        if MARC::ControlField.control_tag?(field.tag)
          # Control field, so add the value. No indicators, subfields.
          doc_values["c_#{solr_tag}_ssim"] << field.value if VALUES
        else
          # Data field, so store the unique subfields and count all of them.
          doc_values["d_#{solr_tag}_ssim"].concat(field.codes).uniq! if VALUES
          doc_counts["d_#{solr_tag}_isi"] += field.codes(dedup=false).count if COUNTS

          # Data fields may have indicators
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
            if solr_code != subfield.code
              log.info("Stripped #{subfield.code} for a #{solr_tag} in #{doc_values['id']}")
              doc_values['escaped_codes'] << "#{solr_tag}_#{subfield.code}" if VALUES or COUNTS
            end

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

  # Grab the resumption token from the OAI response. If there is none, no more records to process.
  resumption_token = document.xpath('/oai:OAI-PMH/oai:ListRecords/oai:resumptionToken', NAMESPACE).text
  break if resumption_token == ''

  qs = "?verb=ListRecords&resumptionToken=#{resumption_token}"
  log.debug('Resuming')
end

log.debug("Finished- #{total_docs} docs loaded in total")
log.debug("Backup identifiers used #{backup_identifier} times")
log.close
