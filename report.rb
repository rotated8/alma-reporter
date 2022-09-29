# frozen_string_literal: true
require 'csv'
require 'faraday'
require 'rsolr'

# File the report will be saved as.
REPORT_FILE = './data.csv'

SOLR_URL = ENV['SOLR_URL'] || 'http://127.0.0.1:8983/solr/alma-data-core'
# Setup the Faraday connection Solr will use.
solr_conn = Faraday.new() do |conn|
  # Self-signed or expired cert? Uncomment the line below.
  # conn.ssl.verify = false
end
solr = RSolr.connect(solr_conn, url: SOLR_URL)

#total_docs = solr.get('select', params: {q: '*:*', rows: 0, facet: false})['response']['numFound']

# Query all fields, return zero as CSV to get headers. These are all fields present in at least one Solr doc.
fields = solr.get('select', params: {q: '*:*', rows: 0, wt: 'csv'}).strip().split(',').sort!
# Only select fields ending in `_isi` to get counts but no data.
fields.select! { |f| f.end_with?('_isi') }
# Move the leader to the front, just because
fields.delete('l_ldr_isi')
fields.prepend('l_ldr_isi')

headers = ['field', 'docs', 'occurs']
CSV.open(REPORT_FILE, 'w', write_headers: true, headers: headers) do |csv|
  for field in fields
    # Get count and sum stats for this field.
    resp = solr.get('select', params: { rows: 0, stats: true, 'stats.field': "{!count=true sum=true}#{field}" })
    # This is the number of documents the field occurs in
    docs = resp['stats']['stats_fields'][field]['count']
    # This is the number of times the field occurs across all docs
    occurs = resp['stats']['stats_fields'][field]['sum']

    csv << [field, docs, occurs]
  end
end
