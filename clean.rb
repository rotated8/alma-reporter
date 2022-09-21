# frozen_string_literal: true
require 'faraday'
require 'rsolr'

SOLR_URL = ENV['SOLR_URL'] || 'http://127.0.0.1:8983/solr/alma-data-core'

# Setup the Faraday connection Solr will use.
solr_conn = Faraday.new() do |conn|
  # Self-signed or expired cert? Uncomment the line below.
  # conn.ssl.verify = false
end
solr = RSolr.connect(solr_conn, url: SOLR_URL)

solr.delete_by_query('*:*')
solr.commit()
