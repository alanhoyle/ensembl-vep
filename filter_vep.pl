#!/usr/bin/env perl

=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

=head1 CONTACT

  Please email comments or questions to the public Ensembl
  developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

  Questions may also be sent to the Ensembl help desk at
  <http://www.ensembl.org/Help/Contact>.

=cut

=head1 NAME

filter_vep.pl - a script to filter results from the Variant Effect Predictor

http://www.ensembl.org/info/docs/tools/vep/script/vep_filter.html

by Will McLaren (wm2@ebi.ac.uk)
=cut

use strict;
use Getopt::Long;
use FileHandle;
use FindBin qw($RealBin);
use lib $RealBin;
use lib $RealBin.'/modules';

use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Bio::EnsEMBL::VEP::FilterSet;
use Bio::EnsEMBL::VEP::Utils qw(merge_hashes merge_arrays get_compressed_filehandle);

# configure from command line opts
my $config = configure(scalar @ARGV);

# run the main sub routine
main($config);

sub configure {
  my $args = shift;
  
  # set defaults
  my $config = {
    start => 1,
    limit => 1e12,
    output_file => 'stdout',

    host => 'ensembldb.ensembl.org',
    port => 3306,
    user => 'anonymous',
  };
  
  GetOptions(
    $config,
    'help|h',                  # displays help message
    
    'test=i',                  # test run on n lines
    'count|c',                 # only print a count
    'list|l',                  # list available columns
    
    'input_file|i=s',          # input file
    'output_file|o=s',         # output file
    'force_overwrite',         # force overwrite output
    'format=s',                # input format
    'gz',                      # force read as gzipped
    'only_matched',            # rewrite CSQ field in VCF with only matched "blobs"
    
    'ontology|y',              # use ontology for matching consequence terms
    'host=s',                  # DB options
    'user=s',
    'pass=s',
    'port=i',
    'version=i',
    'registry=s',
    
    'start|s=i',               # skip first N results
    'limit|l=i',               # return max N results
    
    'filter|f=s@',             # filter
  ) or throw("ERROR: Failed to parse command-line flags\n");
  
  # print usage message if requested or no args supplied
  if($config->{help} || !$args) {
    &usage;
    exit(0);
  }
  
  throw("ERROR: No valid filters given\n") unless $config->{filter} || $config->{list};

  if($config->{ontology}) {
    my $changed = 0;
    foreach my $f(@{$config->{filter}}) {
      if($f =~ m/(con[a-z]+)\sis(_child)?/i) {
        $f =~ s/$&/Consequence is_child/g;
        $changed = 1;
      }
    }

    throw("ERROR: At least one filter must contain \"Consequence is [value]\" when using --ontology\n") unless $changed;

    connect_to_db($config);

    my $oa = $config->{reg}->get_adaptor('Multi','Ontology','OntologyTerm');
    throw("ERROR: Could not fetch OntologyTerm adaptor\n") unless $oa;

    $config->{filter_set} = Bio::EnsEMBL::VEP::FilterSet->new(@{$config->{filter}});

    $config->{filter_set}->ontology_adaptor($oa);
    $config->{filter_set}->ontology_name('SO');    
  }
  
  else {
    # parse filters
    $config->{filter_set} = Bio::EnsEMBL::VEP::FilterSet->new(@{$config->{filter}});
  }
  
  return $config;
}

sub main {
  my $config = shift;
  
  # input
  my $in_fh;
    
  if(my $input_file = $config->{input_file}) {
    # check defined input file exists
    throw("ERROR: Could not find input file $input_file\n") unless -e $input_file;
    
    if($input_file =~ /\.gz$/ || -B $input_file || $config->{gz}) {
      $in_fh = get_compressed_filehandle($input_file, 1);
    }
    else {
      $in_fh = FileHandle->new();
      $in_fh->open( $config->{input_file} ) or throw("ERROR: Could not read from input file ", $config->{input_file}, "\n");
    }
  }
  else {
    $in_fh = 'STDIN';
  }
  
  # output
  my $out_fh = FileHandle->new();
  
  if(-e $config->{output_file} && !$config->{force_overwrite}) {
    throw("ERROR: Output file ", $config->{output_file}, " already exists. Specify a different output file with --output_file or overwrite existing file with --force_overwrite\n");
  }
  elsif($config->{output_file} =~ /stdout/i) {
    $out_fh = *STDOUT;
  }
  else {
    $out_fh->open(">".$config->{output_file}) or throw("ERROR: Could not write to output file ".$config->{output_file}."\n");
  }
  
  my (@raw_headers, @headers, $count, $line_number);
  
  while(<$in_fh>) {
    chomp;
    
    $config->{line_number}++;
    
    # header line?
    if(/^\#/) {
      push @raw_headers, $_;
    }
    else {
      $line_number++;
      last if $config->{test} && $line_number > $config->{test};
      
      # parse headers before processing input
      if(!(scalar @headers)) {
        throw("ERROR: No headers found in input file\n") unless scalar @raw_headers;
        
        # write headers to output
        unless(defined($config->{count}) || defined($config->{list})) {
          print $out_fh join("\n", @raw_headers);
          print $out_fh "\n";
        }
        
        # parse into data structures
        parse_headers($config, \@raw_headers);
        @headers = @{$config->{headers} || $config->{col_headers}};
        $config->{allowed_fields}->{$_} = 1 for (@{$config->{headers}}, @{$config->{col_headers}});
        
        if(defined($config->{list})) {
          print "Available fields:\n\n";
          print "$_\n" for sort keys %{$config->{allowed_fields}};
          exit(0);
        }
      }
      
      my $line = $_;
      
      # get format
      $config->{format} ||= detect_format($line);
      throw("ERROR: Could not detect input file format - perhaps you need to specify it with --format?\n") unless $config->{format};
      throw("ERROR: --only_matched is compatible only with VCF files\n") if $config->{format} ne 'vcf' && $config->{only_matched};
      
      my (@data, @chunks, $vcf_info_field);
      
      if($config->{format} eq 'tab') {
        push @data, parse_line($line, \@headers, "\t");
        push @chunks, $line;
      }
      elsif($config->{format} eq 'vcf') {
        
        # get main data
        my $main_data = parse_line($line, $config->{col_headers}, "\t");
        
        # get info fields
        foreach my $info_field(split /\;/, (split /\s+/, $line)[7]) {
          my ($field, $value) = split /\=/, $info_field;
          $main_data->{$field} = $value;
        }
        
        # get CSQ stuff
        if($line =~ m/(CSQ|ANN)\=(.+?)(\;|$|\s)/) {
          $vcf_info_field = $1;
          @chunks = split('\,', $2);
          push @data,
            map {merge_hashes($_, $main_data)}
            map {parse_line($_, \@headers, '\|')}
            @chunks;
        }
      }
      else {
        throw("ERROR: Unable to parse data in format ".$config->{format}."\n");
      }
      
      my ($line_pass, @new_chunks);
      
      # test each chunk
      foreach my $i(0..$#data) {
        my $chunk_pass;
        my $parsed_chunk = $data[$i];
        my $raw_chunk = $chunks[$i];
        
        $chunk_pass = $config->{filter_set}->evaluate($parsed_chunk);
        $line_pass += $chunk_pass;
        
        push @new_chunks, $raw_chunk if $chunk_pass;
      }
      
      # update CSQ if using only_matched
      if(defined($config->{only_matched}) && scalar @new_chunks != scalar @chunks) {
        my $new_csq = join(",", @new_chunks);
        $line =~ s/$vcf_info_field\=(.+?)(\;|\s|$)/$vcf_info_field\=$new_csq$2/;
      }
      
      $count++ if $line_pass;
      
      next unless $count >= $config->{start};
      
      print $out_fh "$line\n" if $line_pass && !defined($config->{count});
      
      last if $count >= $config->{limit} + $config->{start} - 1;
    }
  }
  
  print $out_fh "$count\n" if defined($config->{count});
}

sub parse_headers {
  my $config = shift;
  my $raw_headers = shift;
  
  foreach my $raw_header(@$raw_headers) {
    
    # remove and count hash characters
    my $hash_count = $raw_header =~ s/\#//g;
    
    # field definition (VCF)
    if($hash_count == 2) {
      if($raw_header =~ /INFO\=\<ID\=(CSQ|ANN)/) {
        $raw_header =~ m/Format\: (.+?)\"/;
        $config->{headers} = [split '\|', $1];
      }
      elsif($raw_header =~ /INFO\=\<ID\=(.+?)\,/) {
        $config->{allowed_fields}->{$1} = 1;
      }
      elsif($raw_header =~ m/ (.+?) \:/) {
        $config->{allowed_fields}->{$1} = 1;
      }
    }
    
    # column headers
    else {
      $config->{col_headers} = [split "\t", $raw_header];
    }
  }
}

sub parse_line {
  my $line = shift;
  my $headers = shift;
  my $delimiter = shift;
  
  chomp $line;
  my @split = split($delimiter, $line);
  
  my %data = map {$headers->[$_] => $split[$_]} 0..$#split;
  
  if(defined($data{Extra})) {
    foreach my $chunk(split /\;/, $data{Extra}) {
      my ($key, $value) = split /\=/, $chunk;
      $data{$key} = $value;
    }
  }
  
  # clean
  foreach my $key(keys %data) {
    $data{$key} = undef if
      $data{$key} eq '' || ($key ne 'Allele' && $data{$key} eq '-');
  }
  
  return \%data;
}


# sub-routine to detect format of input
sub detect_format {
  my $line = shift;
  my @data = split /\s+/, $line;
  
  # VCF: 20  14370  rs6054257  G  A  29  0  NS=58;DP=258;AF=0.786;DB;H2  GT:GQ:DP:HQ
  if (
    $data[0] =~ /(chr)?\w+/ &&
    $data[1] =~ /^\d+$/ &&
    $data[3] && $data[3] =~ /^[ACGTN\-\.]+$/i &&
    $data[4]
  ) {
    return 'vcf';
  }
  else {
    return 'tab';
  }
}

sub connect_to_db {
  my $config = shift;

  eval q{
    use Bio::EnsEMBL::Registry;
  };
  
  if($@) {
    throw("ERROR: Could not load Ensembl API modules\n");
  }
  
  $config->{reg} = 'Bio::EnsEMBL::Registry';
  
  # registry file for local DBs?
  if(defined($config->{registry})) {
    $config->{reg}->load_all($config->{registry});
  }
  
  # otherwise manually connect to DB server
  else {    
    $config->{reg}->load_registry_from_db(
      -host       => $config->{host},
      -user       => $config->{user},
      -pass       => $config->{password},
      -port       => $config->{port},
      -db_version => $config->{version},
    );
  }
}

sub usage {
  print qq{#---------------#
# filter_vep.pl #
#---------------#

By Will McLaren (wm2\@ebi.ac.uk)

http://www.ensembl.org/info/docs/variation/vep/vep_script.html#filter

Usage:
perl filter_vep.pl [arguments]
  
--help               -h   Print usage message and exit

--input_file [file]  -i   Specify the input file (i.e. the VEP results file).
                          If no input file is specified, the script will
                          attempt to read from STDIN. Input may be gzipped - to
                          force the script to read a file as gzipped, use --gz
--format [vcf|tab]        Specify input file format (tab for any tab-delimited
                          format, including default VEP output format)

--output_file [file] -o   Specify the output file to write to. If no output file
                          is specified, the script will write to STDOUT
--force_overwrite         Force the script to overwrite the output file if it
                          already exists

--filter [filters]   -f   Add filter. Multiple --filter flags may be used, and
                          are treated as logical ANDs, i.e. all filters must
                          pass for a line to be printed

--list               -l   List allowed fields from the input file
--count              -c   Print only a count of matched lines

--only_matched            In VCF files, the CSQ field that contains the
                          consequence data will often contain more than one
                          "block" of consequence data, where each block
                          corresponds to a variant/feature overlap. Using
                          --only_matched will remove blocks that do not pass the
                          filters. By default, the script prints out the entire
                          VCF line if any of the blocks pass the filters.
                          
--ontology           -y   Use Sequence Ontology to match consequence terms. Use
                          with operator "is" to match against all child terms of
                          your value.
                          e.g. "Consequence is coding_sequence_variant" will
                          match missense_variant, synonymous_variant etc.
                          Requires database connection; defaults to connecting
                          to ensembldb.ensembl.org. Use --host, --port, --user,
                          --password, --version as per
                          variant_effect_predictor.pl to change connection
                          parameters.
};
}