# frozen_string_literal: true
require 'rsolr'
require 'csv'

SOLR_URL = ENV['SOLR_URL'] || 'http://127.0.0.1:8983/solr/alma-data-core'
solr = RSolr.connect(url: SOLR_URL)

#total_docs = solr.get('select', params: {q: '*:*', rows: 0, facet: false})['response']['numFound']

# Query all fields, return zero as CSV to get headers. These are all fields present in at least one Solr doc.
fields = solr.get('select', params: {q: '*:*', rows: 0, wt: 'csv'}).strip().split(',').sort!
# Only select fields ending in `_isi` to get counts but no data.
fields.select! { |f| f.end_with?('_isi') }
# Move the leader to the front, just because
fields.delete('l_ldr_isi')
fields.prepend('l_ldr_isi')

docs = []
occurs = []
for field in fields
  # Get count and sum stats for this field.
  resp = solr.get('select', params: { rows: 0, stats: true, 'stats.field': "{!count=true sum=true}#{field}" })
  # This is the number of documents the field occurs in
  docs.append(resp['stats']['stats_fields'][field]['count'])
  # This is the number of times the field occurs across all docs
  occurs.append(resp['stats']['stats_fields'][field]['sum'])
end

headers = ['field', 'docs', 'occurs']
data = fields.zip(docs, occurs)

CSV.open('./data.csv', 'w', write_headers: true, headers: headers) do |csv|
  for line in data
    csv << line
  end
end
