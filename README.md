# Alma Reporter

Inspect MARC data from Alma via OAI-PMH using Solr

## Usage
Install the required gems with bundle

`bundle install`

If needed, start a Solr instance (you may want to use a separate terminal for this)

`bundle exec solr_wrapper`

Load data from Alma (see the configuration section for more)

`ruby ./load.rb`

Get a CSV with some stats (see the reporting section for more)

`ruby ./report.rb # ==> ./data.csv`

Clear all the data out of Solr

`ruby ./clean.rb`

## Configuration
There are two configuration options: The URL to Solr, and the name of the OAI set in Alma. The former is used
by all three scripts in this repo, while the latter is only used by `load.rb`.
These can be changed by setting the environment variables `SOLR_URL`, and `ALMA_SET` respectively.
By default, the Solr URL is the one used by solr_wrapper: `http://127.0.0.1:8983/solr/alma-data-core`, and the
Alma set is `blacklighttest`.

If you wanted to use a set called `sunspot`, you could run `ALMA_SET=sunspot ruby ./load.rb`, or if you have a
permanent Solr at http://example.com/solr/sunspot-core, you could run
`SOLR_URL="http://example.com/solr/sunspot-core" ruby ./report.rb`

## Mapping MARC to Solr
Example Solr fields could be `f_001_isi`, `d_040_ssim`, `i_028_ind2_ssim`, or `s_040_a_isi`.

The pieces of a fieldname between the underscores each have some meaning starting with the prefix.

### Prefix Piece
Prefixes come in five flavors:
- `f_` fields count the number of times that field occured in a MARC record.
- `c_` fields are for control fields, and contain the value of the MARC field.
- `d_` fields are for data fields, and contain the subfield codes from that MARC field.
- `s_` fields are for subfields, and contain the values for that subfield.
- `i_` fields are for indicators, and contain the non-empty values for that indicator.

### MARC Field Piece
The next piece is the fieldname from the MARC record.

### Subfield and Indicator Piece
`s_` and `i_` Solr fields have an extra piece here. For `i_` fields, it is either `ind1` or `ind2`,
corresponding to which indicator they describe. For `s_` fields, this piece is the subfield code.

### Suffix Piece
Finally, each field has a suffix: either `_isi` or `_ssim`. Generally, if the suffix is `_isi`, the Solr field
is a count of how many times a field was found in the MARC record. If the suffix is `_ssim`, the Solr field
contains the values from the MARC field.

With suffixes, there are some caveats:
- There are no `f_*_ssim` fields, as the data there is present in other places (`c_*_ssim` or `s_*_ssim` fields).
- There are no `c_*_isi` fields, as that data would match the `f_` fields
- `d_*_ssim` fields only contain unique elements, rather than all the subfield codes.
- `d_*_isi` fields do count the total number of times the subfields appeared.

### Examples
Using the example fields from above (`f_001_isi`, `d_040_ssim`, `i_028_ind2_ssim`, or `s_040_a_isi`), we now
know that, for a single MARC record or Solr document
- `f_001_isi` counts how many times the 001 field appeared
- `d_040_ssim` contains all the unique subfield codes for the 040 field
- `i_028_ind2_ssim` contains all the non-empty, non-unique values for the second indicator for the 028 field
- `s_040_a_isi` counts how many times the 040$a subfield occurred.

### Unique fields
Additionally, each document contains some other fields. `id`, which should be the same as the `c_001_ssim` field.
`l_ldr_ssim` contains the value of the leader, and `l_ldr_isi` counts the number of times a leader was found, for
completeness.

If the `load.rb`  script is rewritten, it can also populate the `raw_tsi` Solr field with the raw MARC record.

## Reporting
The report takes all the different `_isi` fields, and produces two statistics for each: how many MARC records
(or Solr documents) have that field, and how many occurances of that field exist across all the records.

WARNING! Rerunning the report script will overwrite the data.csv file.
