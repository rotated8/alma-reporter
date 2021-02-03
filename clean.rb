# frozen_string_literal: true
require 'rsolr'
SOLR_URL = ENV['SOLR_URL'] || 'http://127.0.0.1:8983/solr/alma-data-core'

solr = RSolr.connect(url: SOLR_URL)
solr.delete_by_query('*:*')
solr.commit()
