# frozen_string_literal:true
require 'faraday'
require 'marc'
require 'nokogiri'
require 'rsolr'

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

# Global counter for missing identifiers, for Solr.
identifier = 0

################### SETUP
# With nokogiri required above, this should force XMLReader to use it.
MARC::XMLReader.best_available!

solr = RSolr.connect(url: SOLR_URL)

loop do
  ################# GET RECORDS
  puts "@ #{Time.now}"
  puts '@ getting records'
  oai_response = Faraday.get("#{OAI_BASE}#{qs}")
  document = Nokogiri::XML::Document.parse(oai_response.body)

  deleted_records = document.xpath('/oai:OAI-PMH/oai:ListRecords/oai:record[oai:header/@status="deleted"]', NAMESPACE)
  if deleted_records.count.positive?
    deleted_ids = deleted_records.map { |record| record.at('header/identifier').text.split(':').last }
    # Remove deleted-status records from the indexing set, and delete them from Solr.
    deleted_records.remove
    solr.delete_by_id(deleted_ids)
    solr.commit
  end

  record_count = document.xpath('/oai:OAI-PMH/oai:ListRecords/oai:record', NAMESPACE).count
  puts "@ #{record_count} records"
  if record_count.positive?
    ############### INDEX RECORDS
    # Collect each solr doc from this file.
    docs = []

    # Rather than writing to disk only to read it right back, let's use StringIO
    reader = MARC::XMLReader.new(StringIO.new(document.to_s))

    puts '@ creating solr docs'
    for record in reader
      # Perf improvement. Makes the fields immutable.
      record.fields.freeze

      # Solr doc accumulators. One for data, one for counts. All data fields are multivalued.
      doc_values = Hash.new { |hash, key| hash[key] = [] }
      doc_counts = Hash.new(0)

      if record.fields('001').count == 1
        doc_values['id'] = record.fields('001').first.value
      else
        # Record has no identifier???
        puts "!!! missing/multiple 001"
        doc_values['id'] = identifier
        identifier += 1
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

      doc_values["raw_tsi"] = record.to_s if RAW_MARC

      doc_values.merge!(doc_counts) if COUNTS
      docs << doc_values
    end

    puts "@ committing solr docs"
    solr.add(docs)
    solr.commit
  end

  resumption_token = document.xpath('/oai:OAI-PMH/oai:ListRecords/oai:resumptionToken', NAMESPACE).text
  break if resumption_token == ''

  qs = "?verb=ListRecords&resumptionToken=#{resumption_token}"
  puts '@ resuming'
end

puts '@ finished!'
puts "@ #{Time.now}"
