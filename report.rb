# frozen_string_literal: true
require 'rsolr'
require 'csv'

SOLR_URL = ENV['SOLR_URL'] || 'http://127.0.0.1:8983/solr/alma-data-core'
solr = RSolr.connect(url: SOLR_URL)

#total_docs = solr.get('select', params: {q: '*:*', rows: 0, facet: false})['response']['numFound']

# Query all fields, return zero as CSV to get headers. These are all fields present in at least one Solr doc.
fields = solr.get('select', params: {q: '*:*', rows: 0, wt: 'csv'}).strip().split(',').sort!
puts "@ got fields"
# Only select fields ending in `_isi` to get counts but no data.
fields.select! { |f| f.end_with?('_isi') }
# Move the leader to the front, just because
fields.delete('l_ldr_isi')
fields.prepend('l_ldr_isi')
puts "@ ordered fields"

headers = ['field', 'docs', 'occurs']
CSV.open('./data.csv', 'w', write_headers: true, headers: headers) do |csv|
  for field in fields
    puts "@ #{Time.now}"
    puts "@ getting #{field}"
    # Get count and sum stats for this field.
    resp = solr.get('select', params: { rows: 0, stats: true, 'stats.field': "{!count=true sum=true}#{field}" })
    # This is the number of documents the field occurs in
    docs = resp['stats']['stats_fields'][field]['count']
    # This is the number of times the field occurs across all docs
    occurs = resp['stats']['stats_fields'][field]['sum']

    csv << [field, docs, occurs]
  end
end
