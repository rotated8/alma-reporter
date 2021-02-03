# Alma Reporter

Inspect MARC data from Alma via OAI-PMH using Solr

## Usage
Install the required gems with bundle
```bundle install```

If needed, start a solr instance (you may want to use a separate terminal for this)
```bundle exec solr_wrapper```

Load data from Alma (see the configuration section for more)
```ruby ./load.rb```

Get a CSV with some stats
```ruby ./report.rb # ==> ./data.csv```

Clear all the data out of Solr
```ruby ./clean.rb```

## Configuration
There are two configuration options: The URL to Solr, and the name of the OAI set in Alma. The former is used
by all three scripts in this repo, while the latter is only used by `load.rb`.
These can be changed by setting the environment variables `SOLR_URL`, and `ALMA_SET` respectively.
By default, the Solr URL is the one used by solr_wrapper: `http://127.0.0.1:8983/solr/alma-data-core`, and the
Alma set is `blacklighttest`.

If you wanted to use a set called `sunspot`, you could run `ALMA_SET=sunspot ruby ./load.rb`, or if you have a
permanent Solr at http://example.com/solr/sunspot-core, you could run
`SOLR_URL="http://example.com/solr/sunspot-core" ruby ./report.rb`
