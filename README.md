# Alma Reporter

Inspect MARC data from Alma via OAI-PMH using Solr

## Usage
Install the required gems with bundle

`bundle install`

Don't need the solr\_wrapper dependency?

`bundle install --without=development`

If needed, start a Solr instance (you may want to use a separate terminal for this)

`bundle exec solr_wrapper`

Load data from Alma (see the configuration section for more)

`bundle exec ruby ./load.rb`

Get a CSV with some stats (see the reporting section for more)

`bundle exec ruby ./report.rb # ==> ./data.csv`

Clear all the data out of Solr

`bundle exec ruby ./clean.rb`

## Configuration
There are two configuration options: The URL to Solr, and the name of the OAI set in Alma.
The former is used by all three scripts in this repo, while the latter is only used by `load.rb`.
These can be changed by setting the environment variables `SOLR_URL`, and `ALMA_SET` respectively.
By default, the Solr URL is the one used by solr\_wrapper: `http://127.0.0.1:8983/solr/alma-data-core`, and the Alma set is `blacklighttest`.

If you wanted to use a set called 'sunspot', you could run `ALMA_SET=sunspot bundle exec ruby ./load.rb`, or if you have a permanent Solr at https://example.com/solr/sunspot-core, you could run `SOLR_URL="https://example.com/solr/sunspot-core" bundle exec ruby ./report.rb`

## Mapping MARC to Solr
Example Solr fields could be `f_001_isi`, `d_040_ssim`, `i_028_ind2_ssim`, or `s_040_a_isi`.

The pieces of a fieldname between the underscores each have some meaning starting with the prefix.

### Prefix Piece
Prefixes come in five flavors:
- `f_` fields count the number of times that field occured in a MARC record.
- `c_` fields are for control fields, and contain the value of the MARC field.
- `d_` fields are for data fields, and contain the subfield codes from that MARC field.
- `s_` fields are for subfields, and contain the values for that subfield.
- `i_` fields are for indicators, and contain the values for that indicator.

### MARC Field Piece
The next piece is the field's tag from the MARC record.

### Subfield and Indicator Piece
`s_` and `i_` Solr fields have an extra piece here.
For `i_` fields, it is either `ind1` or `ind2`, corresponding to which indicator they describe.
For `s_` fields, this piece is the subfield code.

### Suffix Piece
Finally, each field has a suffix: either `_isi` or `_ssim`.
If the suffix is `_isi`, the Solr field is a count of how many times the field was found in the MARC record.
If the suffix is `_ssim`, the Solr field contains the values from the MARC field.

With suffixes, there are some caveats:
- There are no `f_*_ssim` fields, as the values in tags are present in other places (`c_*_ssim` or `s_*_ssim` fields).
- There are no `c_*_isi` fields, as that data would match the `f_*_isi` fields
- `d_*_ssim` fields only contain unique elements, rather than all the subfield codes.
- `d_*_isi` fields do count the total number of times the subfields appeared.

### Examples
Using the example fields from above (`f_001_isi`, `d_040_ssim`, `i_028_ind2_ssim`, or `s_040_a_isi`), we now know that, for a single MARC record or Solr document:
- `f_001_isi` counts how many times the 001 field appeared
- `d_040_ssim` contains all the unique subfield codes for the 040 field
- `i_028_ind2_ssim` contains all the values for the second indicator for the 028 field
- `s_040_a_isi` counts how many times the 040$a subfield occurred.

### Unique fields
Additionally, each document contains some other fields.
- `id`, which should be the same as the `c_001_ssim` field.
- `l_ldr_ssim` contains the value of the leader, and (for completeness) `l_ldr_isi` counts the number of times a leader was found.
- `escaped_tags_ssim` and `escaped_codes_ssim` will have any tags and subfield codes (respectively) that had to be changed to fit Solr's field name limitations.
- `raw_tsi` contains the raw MARC xml, if the correct variable was set in the `load.rb` script when it was run.

## Ingest safety
The `load.rb` script takes some effort to ensure an ingest completes successfully.

The most common issue is with non-conforming MARC data.
Solr does not allow certain non-alphanumeric characters in its fieldnames, so the two fields `escaped_tags_ssim` and `escaped_codes_ssim` capture offenders for easy identification.
For example, if a record has a 856 tag with a '|' subfield code, the `escaped_codes_ssim` field will have '856\_|' in its values.
You can still find the value of that subfield- it will be in the `s_856___ssim` field on the Solr doc.
All offending characters are replaced with underscores ('\_').

Less likely, but still handled are multiple instances of or missing 001s, leaders, or other control fields.
In these cases, the script will use a fallback identifier rather than guessing what value is correct.
The fallback identifiers start at zero and increment by one for each case found.

Finally, the script will retry it's OAI and Solr queries a limited number of times before accepting defeat.

WARNING! Rerunning the ingest script will overwrite the import.log file.

## Reporting
The report takes all the different `_isi` fields, and produces two statistics for each: how many MARC records (or Solr documents) have that field, and how many occurances of that field exist across all the records.

WARNING! Rerunning the report script will overwrite the data.csv file.

## Example Solr queries
Coming soon!
