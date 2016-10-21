#!/usr/bin/env perl
# EPN, Mon Aug 10 10:39:33 2015 [development began on dnaorg_annotate_genomes.pl]
# EPN, Mon Feb  1 15:07:43 2016 [dnaorg_build.pl split off from dnaorg_annotate_genomes.pl]
#
use strict;
use warnings;
use Getopt::Long;
use Time::HiRes qw(gettimeofday);
use Bio::Easel::MSA;
use Bio::Easel::SqFile;

require "dnaorg.pm"; 
require "epn-options.pm";

#######################################################################################
# What this script does: 
#
# Preliminaries: 
#   - process options
#   - create the output directory
#   - output program banner and open output files
#   - parse the optional input files, if necessary
#   - make sure the required executables are executable
#
# Step 1. Gather and process information on reference genome using Edirect
#
# Step 2. Fetch and process the reference genome sequence
#
# Step 3. Build and calibrate models
#######################################################################################

# first, determine the paths to all modules, scripts and executables that we'll need
# we currently use hard-coded-paths for Infernal, HMMER and easel executables:
my $inf_exec_dir      = "/usr/local/infernal/1.1.1/bin/";
my $hmmer_exec_dir    = "/usr/local/hmmer/3.1/bin/";
my $esl_exec_dir      = "/usr/local/infernal/1.1.1/bin/";

# make sure the DNAORGDIR environment variable is set
my $dnaorgdir = $ENV{'DNAORGDIR'};
if(! exists($ENV{'DNAORGDIR'})) { 
    printf STDERR ("\nERROR, the environment variable DNAORGDIR is not set, please set it to the directory where you installed the dnaorg scripts and their dependencies.\n"); 
    exit(1); 
}
if(! (-d $dnaorgdir)) { 
    printf STDERR ("\nERROR, the dnaorg directory specified by your environment variable DNAORGDIR does not exist.\n"); 
    exit(1); 
}    
 
# determine other required paths to executables relative to $dnaorgdir
my $esl_fetch_cds     = $dnaorgdir . "/esl-fetch-cds/esl-fetch-cds.pl";
my $nnop  = 0; # number of sequences for which an origin is not predicted
my $npred = 0; # number of sequences for which an origin is predicted
my $npred_len = 0; # number of sequences for which an origin is predicted that is the correct length
my %nmismatch_H = ();

#########################################################
# Command line and option processing using epn-options.pm
#
# opt_HH: 2D hash:
#         1D key: option name (e.g. "-h")
#         2D key: string denoting type of information 
#                 (one of "type", "default", "group", "requires", "incompatible", "preamble", "help")
#         value:  string explaining 2D key:
#                 "type":          "boolean", "string", "int" or "real"
#                 "default":       default value for option
#                 "group":         integer denoting group number this option belongs to
#                 "requires":      string of 0 or more other options this option requires to work, each separated by a ','
#                 "incompatiable": string of 0 or more other options this option is incompatible with, each separated by a ','
#                 "preamble":      string describing option for preamble section (beginning of output from script)
#                 "help":          string describing option for help section (printed if -h used)
#                 "setby":         '1' if option set by user, else 'undef'
#                 "value":         value for option, can be undef if default is undef
#
# opt_order_A: array of options in the order they should be processed
# 
# opt_group_desc_H: key: group number (integer), value: description of group for help output
my %opt_HH = ();      
my @opt_order_A = (); 
my %opt_group_desc_H = ();

# Add all options to %opt_HH and @opt_order_A.
# This section needs to be kept in sync (manually) with the &GetOptions call below
$opt_group_desc_H{"1"} = "basic options";
#     option            type       default               group   requires incompat    preamble-output                          help-output    
opt_Add("-h",           "boolean", 0,                        0,    undef, undef,      undef,                                   "display this help",                                  \%opt_HH, \@opt_order_A);
opt_Add("--hmmonly",    "boolean", 0,                        1,    undef, undef,      "search with HMMs not CMs",              "search with HMMs not CMs",                           \%opt_HH, \@opt_order_A);

# This section needs to be kept in sync (manually) with the opt_Add() section above
my %GetOptions_H = ();
my $usage    = "Usage: dnaorg_test_origin_s1.pl [-options] <CM file with 5p and 3p origin models> <fasta file> <output directory> <consensus sequence>\n";
my $synopsis = "dnaorg_test_origin_s1.pl :: search for origin sequences [TEST SCRIPT]";

my $options_okay = 
    &GetOptions('h'            => \$GetOptions_H{"-h"}, 
                'hmmonly'      => \$GetOptions_H{"--hmmonly"});

my $total_seconds = -1 * secondsSinceEpoch(); # by multiplying by -1, we can just add another secondsSinceEpoch call at end to get total time
my $executable    = $0;
my $date          = scalar localtime();
my $version       = "0.11";
my $releasedate   = "July 2016";

# print help and exit if necessary
if((! $options_okay) || ($GetOptions_H{"-h"})) { 
  outputBanner(*STDOUT, $version, $releasedate, $synopsis, $date);
  opt_OutputHelp(*STDOUT, $usage, \%opt_HH, \@opt_order_A, \%opt_group_desc_H);
  if(! $options_okay) { die "ERROR, unrecognized option;"; }
  else                { exit 0; } # -h, exit with 0 status
}

# check that number of command line args is correct
if(scalar(@ARGV) != 4) {   
  print "Incorrect number of command line arguments.\n";
  print $usage;
  print "\nTo see more help on available options, do dnaorg_build.pl -h\n\n";
  exit(1);
}
my ($model_file, $fasta_file, $dir_out, $cons_seq) = (@ARGV);

if(defined $dir_out) { 
  $dir_out =~ s/\/$//; # remove final '/' if there is one
}
my $dir_out_tail   = $dir_out;
$dir_out_tail   =~ s/^.+\///; # remove all but last dir
my $out_root   = $dir_out .   "/" . $dir_out_tail   . ".dnaorg_test_origin_s1";

my $cmd;
if(! -d $dir_out) {
  $cmd = "mkdir $dir_out";
  runCommand($cmd, 0, undef);
}

# set options in opt_HH
opt_SetFromUserHash(\%GetOptions_H, \%opt_HH);

# validate options (check for conflicts)
opt_ValidateSet(\%opt_HH, \@opt_order_A);

#############################################
# output program banner and open output files
#############################################
# output preamble
my @arg_desc_A = ("model file with 5 prime origin model and 3 prime origin model", "fasta file", "output file root", "consensus origin sequence");
my @arg_A      = ($model_file, $fasta_file, $dir_out, $cons_seq);
outputBanner(*STDOUT, $version, $releasedate, $synopsis, $date);
opt_OutputPreamble(*STDOUT, \@arg_desc_A, \@arg_A, \%opt_HH, \@opt_order_A);

# open the log and command files:
# set output file names and file handles, and open those file handles
my %ofile_info_HH = ();  # hash of information on output files we created,
                         # 1D keys: 
                         #  "fullpath":  full path to the file
                         #  "nodirpath": file name, full path minus all directories
                         #  "desc":      short description of the file
                         #  "FH":        file handle to output to for this file, maybe undef
                         # 2D keys:
                         #  "log": log file of what's output to stdout
                         #  "cmd": command file with list of all commands executed

# open the log and command files 
openAndAddFileToOutputInfo(\%ofile_info_HH, "log", $out_root . ".log", 1, "Output printed to screen");
openAndAddFileToOutputInfo(\%ofile_info_HH, "cmd", $out_root . ".cmd", 1, "List of executed commands");
openAndAddFileToOutputInfo(\%ofile_info_HH, "list", $out_root . ".list", 1, "List and description of all output files");
my $log_FH = $ofile_info_HH{"FH"}{"log"};
my $cmd_FH = $ofile_info_HH{"FH"}{"cmd"};
# output files are all open, if we exit after this point, we'll need
# to close these first.

# now we have the log file open, output the banner there too
outputBanner($log_FH, $version, $releasedate, $synopsis, $date);
opt_OutputPreamble($log_FH, \@arg_desc_A, \@arg_A, \%opt_HH, \@opt_order_A);

my $cons_len = length($cons_seq);
my @cons_seq_A = split("", $cons_seq);
###################################################
# make sure the required executables are executable
###################################################
my %execs_H = (); # hash with paths to all required executables
$execs_H{"cmscan"}       = $inf_exec_dir . "cmscan";
validateExecutableHash(\%execs_H, $ofile_info_HH{"FH"});

#####################################################
# Determine length of all sequences in the fasta file
#####################################################
if(-e $fasta_file . ".ssi") { 
  unlink $fasta_file . ".ssi";
}
my $sqfile = Bio::Easel::SqFile->new({ fileLocation => $fasta_file }); # the sequence file object
my $nseq = $sqfile->nseq_ssi;
my %seqlen_H = ();
my @seq_order_A = ();
for(my $i = 0; $i < $nseq; $i++) { 
  my ($seqname, $seqlen) = $sqfile->fetch_seq_name_and_length_given_ssi_number($i);
  $seqlen_H{$seqname} = $seqlen / 2;
  push(@seq_order_A, $seqname);
}

###############################
# Run cmscan on all sequences
###############################
my $tblout_file = $out_root . ".tbl";
my $stdout_file = $out_root . ".cmscan";
my $opts = " --cpu 0 --tblout $tblout_file --verbose ";
if(! opt_Get("--hmmonly", \%opt_HH)) { 
  $opts .= " --nohmmonly --F1 0.02 --F2 0.001 --F2b 0.001 --F3 0.00001 --F3b 0.00001 --F4 0.0002 --F4b 0.0002 --F5 0.0002 --F6 0.0001 ";
}

$cmd = $execs_H{"cmscan"} . " " . $opts . " $model_file $fasta_file > $stdout_file";

runCommand($cmd, 0, $ofile_info_HH{"FH"});

addClosedFileToOutputInfo(\%ofile_info_HH, "tblout", "$tblout_file", 1, "cmscan tabular output");
addClosedFileToOutputInfo(\%ofile_info_HH, "stdout", "$stdout_file", 1, "cmscan standard output");

################################################
# Parse cmscan tabular output and output results
################################################

my %hit1_HH     = (); # 2D hash of top hits, 1st dim key is sequence name, 2nd is attribute, e.g. "start"    
my %hit2_HH     = (); # 2D hash of rank 2 hits, 1st dim key is sequence name, 2nd is attribute, e.g. "start"    
my $start_5p; 
my $stop_5p; 
my $start_3p; 
my $stop_3p; 
parse_cmscan_tblout($tblout_file, \%seqlen_H, \%hit1_HH, \%hit2_HH, $ofile_info_HH{"FH"});

foreach my $seqname (@seq_order_A) { 
  my $seqlen = $seqlen_H{$seqname};
  my $has_hit1 = (defined $hit1_HH{$seqname}) ? 1 : 0;
  my $has_hit2 = (defined $hit2_HH{$seqname}) ? 1 : 0;
  my $has_5p_and_3p = 0;
  if((exists $hit1_HH{$seqname}{"5p"} && ($hit1_HH{$seqname}{"5p"} == 1)) && 
     (exists $hit2_HH{$seqname}{"3p"} && ($hit2_HH{$seqname}{"3p"} == 1))) { 
    $has_5p_and_3p = 1;
  }
  if((exists $hit1_HH{$seqname}{"3p"} && ($hit1_HH{$seqname}{"3p"} == 1)) && 
     (exists $hit2_HH{$seqname}{"5p"} && ($hit2_HH{$seqname}{"5p"} == 1))) { 
    $has_5p_and_3p = 1;
  }
  #printf("seqname: $seqname has_5p_and_3p: $has_5p_and_3p\n");
  if($has_5p_and_3p) { 
    if($hit1_HH{$seqname}{"5p"}) { 
      #printf("$seqname 1 is 5p, 2 is 3p\n");
      $start_5p = $hit1_HH{$seqname}{"start"};
      $stop_5p  = $hit1_HH{$seqname}{"stop"};
      $start_3p = $hit2_HH{$seqname}{"start"};
      $stop_3p  = $hit2_HH{$seqname}{"stop"};
    }
    elsif($hit2_HH{$seqname}{"5p"}) { 
      #printf("$seqname 1 is 3p, 2 is 5p\n");
      $start_5p = $hit2_HH{$seqname}{"start"};
      $stop_5p  = $hit2_HH{$seqname}{"stop"};
      $start_3p = $hit1_HH{$seqname}{"start"};
      $stop_3p  = $hit1_HH{$seqname}{"stop"};
    }
    # determine strand 
    if($start_5p < $stop_5p) { 
      # positive strand
      if($start_3p >= $stop_3p)  { die "ERROR positive strand but 3p_start ($start_5p) >= 3p_stop ($stop_5p) $seqname"; }
      if($start_5p >= $start_3p) { 
        # special case, example is: 
        #NC_001346.dnaorg_build.origin.5p -         FJ882131:dnaorg-duplicated:FJ882131:1:2690:+:FJ882131:1:2690:+: -         hmm        1       59     2641     2699      +     -    6 0.56   0.0   75.0   4.8e-23 !   -
        #NC_001346.dnaorg_build.origin.3p -         FJ882131:dnaorg-duplicated:FJ882131:1:2690:+:FJ882131:1:2690:+: -         hmm        1       59        1       59      +     -    6 0.54   0.0   72.9   1.8e-22 !   -
        if($start_3p <= $seqlen && $stop_3p <= $seqlen) { 
          $start_3p += $seqlen;
          $stop_3p += $seqlen;
        }
        if($start_5p >= $start_3p) { 
          die "ERROR 5p_start ($start_5p) >= 3p_start($start_3p) after testing for special case $seqname"; 
        }
      }
      
      my $nres_overlap = getOverlap($start_5p, $stop_5p, $start_3p, $stop_3p, $ofile_info_HH{"FH"});
      my $origin_coords = "?";
      my $origin_seq = "?";
      my $nmismatch  = $cons_len;
      if($nres_overlap > 0) { 
        if($nres_overlap != ($stop_5p - $start_3p + 1)) { 
          die "ERROR overlap nres doesn't match assumption.";
        }
        $origin_coords = sprintf("%d..%d", $start_3p, $stop_5p);
        my $origin_fasta_seq = $sqfile->fetch_subseq_to_fasta_string($seqname, $start_3p, $stop_5p, -1, 0);
        $origin_seq = $origin_fasta_seq;
        $origin_seq =~ s/^\>.+\n//;
        chomp $origin_seq;
        $nmismatch = compare_to_consensus($origin_seq, \@cons_seq_A);
      } 
      outputString($ofile_info_HH{"FH"}{"log"}, 1, sprintf("%-80s  %10s  %2d  %10s  %2d  + %s\n", $seqname, $origin_coords, $nres_overlap, $origin_seq, $nmismatch, ($nmismatch == 0) ? "PASS" : "FAIL"));
      $npred++;
      if($nres_overlap == $cons_len) { 
        $nmismatch_H{$nmismatch}++;
        $npred_len++;
      }
    } # end of 'if($start_5p < $stop_5p)'
    else { 
      # negative strand
      if($start_3p <= $stop_3p)  { die "ERROR positive strand but 3p_start ($start_5p) >= 3p_stop ($stop_5p) $seqname"; }
      if($start_5p <= $start_3p) { 
        die "That special case you thought might happen, just happened.";
        # see analogous special case for positive strand, above
      }
      my $nres_overlap = getOverlap($stop_5p, $start_5p, $stop_3p, $start_3p, $ofile_info_HH{"FH"});
      my $origin_coords = "?";
      my $origin_seq = "?";
      my $nmismatch  = $cons_len;
      if($nres_overlap > 0) { 
        if($nres_overlap != ($start_3p - $stop_5p + 1)) { 
          die "ERROR overlap nres doesn't match assumption.";
        }
        $origin_coords = sprintf("%d..%d", $start_3p, $stop_5p);
        my $origin_fasta_seq = $sqfile->fetch_subseq_to_fasta_string($seqname, $start_3p, $stop_5p, -1, 0);
        $origin_seq = $origin_fasta_seq;
        $origin_seq =~ s/^\>.+\n//;
        chomp $origin_seq;
        $nmismatch = compare_to_consensus($origin_seq, \@cons_seq_A);
      } 
      outputString($ofile_info_HH{"FH"}{"log"}, 1, sprintf("%-80s  %10s  %2d  %10s  %2d  - %s\n", $seqname, $origin_coords, $nres_overlap, $origin_seq, $nmismatch, ($nmismatch == 0) ? "PASS" : "FAIL"));
      $nmismatch_H{$nmismatch}++;
      $npred++;
      if($nres_overlap == $cons_len) { 
        $nmismatch_H{$nmismatch}++;
        $npred_len++;
      }
    } # end of 'else' entered if(! ($start_5p < $stop_5p))'
  }
  else { 
    outputString($ofile_info_HH{"FH"}{"log"}, 1, sprintf("%-80s  %10s  %2s  %10s  %2d  ? FAIL\n", $seqname, "?", "?", "?", $cons_len));
    $nnop++;
  } 
}
##########
# Conclude
##########

# print summary
outputString($ofile_info_HH{"FH"}{"log"}, 1, "#\n# Summary:\n#\n");
outputString($ofile_info_HH{"FH"}{"log"}, 1, sprintf("# Number of sequences:                       %4d\n", $nseq));
outputString($ofile_info_HH{"FH"}{"log"}, 1, sprintf("# Number of no predictions:                  %4d (%.3f)\n", $nnop, $nnop / $nseq));
outputString($ofile_info_HH{"FH"}{"log"}, 1, sprintf("# Number of predictions of unexpected len:   %4d (%.3f)\n", ($npred-$npred_len), ($npred-$npred_len) / $nseq));
outputString($ofile_info_HH{"FH"}{"log"}, 1, sprintf("# Number of predictions of expected len:     %4d (%.3f)\n", $npred_len, $npred_len / $nseq));
for(my $z = 0; $z <= $cons_len; $z++) { 
  my $cur_nmismatch = (exists $nmismatch_H{$z}) ? $nmismatch_H{$z} : 0;
  outputString($ofile_info_HH{"FH"}{"log"}, 1, sprintf("# Number of predictions with %2d mismatches:  %4d (%.3f)\n", $z, $cur_nmismatch, $cur_nmismatch / $npred_len));
}

$total_seconds += secondsSinceEpoch();
outputConclusionAndCloseFiles($total_seconds, $dir_out, \%ofile_info_HH);
exit 0;


#################################################################
# Subroutine : parse_cmscan_tblout()
# Incept:      EPN, Tue Jul 12 08:54:07 2016
#
# Purpose:    Parse Infernal 1.1 cmscan --tblout output and store
#             results in $mdl_results_AAH.
#
# Arguments: 
#  $tblout_file: tblout file to parse
#  $seqlen_HR:    REF to hash, key is sequence name, value is length
#  $hit1_HHR:     REF to 2D hash of top hits, 1st dim key is sequence name, 2nd is attribute, e.g. "start"    
#  $hit2_HHR:     REF to 2D hash of rank 2 hits, 1st dim key is sequence name, 2nd is attribute, e.g. "start"    
#  $FH_HR:        REF to hash of file handles
#
# Returns:    void
#
#################################################################
sub parse_cmscan_tblout { 
  my $sub_name = "parse_cmscan_tblout()";
  my $nargs_exp = 5;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }
  
  my ($tblout_file, $seqlen_HR, $hit1_HHR, $hit2_HHR, $FH_HR) = @_;
  
  open(IN, $tblout_file) || fileOpenFailure($tblout_file, $sub_name, $!, "reading", $FH_HR);

  my $did_field_check = 0; # set to '1' below after we check the fields of the file
  my $line_ctr = 0;  # counts lines in tblout_file
  my $HHR = undef; # pointer to either $hit1_HHR or $hit2_HHR
  while(my $line = <IN>) { 
    $line_ctr++;
    if(($line =~ m/^\#/) && (! $did_field_check)) { 
      # sanity check, make sure the fields are what we expect
      if($line !~ m/#target name\s+accession\s+query name\s+accession\s+mdl\s+mdl\s+from\s+mdl to\s+seq from\s+seq to\s+strand\s+trunc\s+pass\s+gc\s+bias\s+score\s+E-value inc description of target/) { 
        DNAORG_FAIL("ERROR in $sub_name, unexpected field names in $tblout_file\n$line\n", 1, $FH_HR);
      }
      $did_field_check = 1;
    }
    elsif($line !~ m/^\#/) { 
      chomp $line;
      if($line =~ m/\r$/) { chop $line; } # remove ^M if it exists
      # example line:
      # NC_001346.dnaorg_build.origin.5p -         KJ699341             -         hmm        1       59     2484     2542      +     -    6 0.59   0.1   78.5     2e-24 !   -
      my @elA = split(/\s+/, $line);
      my ($mdlname, $seqname, $mod, $mdlfrom, $mdlto, $seqfrom, $seqto, $strand, $score, $evalue) = 
          ($elA[0], $elA[2], $elA[4], $elA[5], $elA[6], $elA[7], $elA[8], $elA[9], $elA[14], $elA[15]);

      my $seqlen = $seqlen_HR->{$seqname};

      # only consider hits where either the start or end are less than the total length
      # of the genome. Since we sometimes duplicate all genomes, this gives a simple 
      # rule for deciding which of duplicate hits we'll store 
      if(($seqfrom <= $seqlen) || ($seqto <= $seqlen)) { 
        $HHR = $hit1_HHR;
        #printf("\n$seqname HHR is hit1\n");
        if(exists $hit1_HHR->{$seqname}) { 
          $HHR = $hit2_HHR;
          #printf("$seqname HHR is hit2\n");
          if(exists $hit2_HHR->{$seqname}) { 
            $HHR = undef; # 2 hits already exist for this hit, don't store it
            #printf("$seqname HHR is undef\n");
          }
        }
        if(defined $HHR) {
          %{$HHR->{$seqname}} = ();
          $HHR->{$seqname}{"start"}  = $seqfrom;
          $HHR->{$seqname}{"stop"}   = $seqto;
          $HHR->{$seqname}{"score"}  = $score;
          $HHR->{$seqname}{"evalue"} = $evalue;
          if($mdlname =~ m/5p$/) { 
            #printf("\t5p\n");
            $HHR->{$seqname}{"5p"} = 1;
            $HHR->{$seqname}{"3p"} = 0;
          }
          elsif($mdlname =~ m/3p$/) { 
            #printf("\t3p\n");
            $HHR->{$seqname}{"5p"} = 0;
            $HHR->{$seqname}{"3p"} = 1;
          }
          else { 
            die "ERROR can't parse model name $mdlname"; 
          }
        } 
      }
    }
  }
}

#################################################################
# Subroutine : compare_to_consensus()
# Incept:      EPN, Tue Jul 12 14:33:02 2016
#
# Purpose:    Given a predicted origin sequence, compare the
#             it to the consensus sequence, and report number
#             of mismatches.
#
# Arguments: 
#  $pred_seq:    predicted consensus sequence
#  $cons_seq_AR: REF to an array that is the consensus sequence, each element is an array element
#
# Returns:    void
#
#################################################################
sub compare_to_consensus { 
  my $sub_name = "compare_to_consensus()";
  my $nargs_exp = 2;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }
  
  my ($pred_seq, $cons_seq_AR) = @_;

  my @pred_A = split("", $pred_seq);
  my $cons_len = scalar(@{$cons_seq_AR});
  my $pred_len = scalar(@pred_A);

  my $nmatch = 0;
  my $min_len = ($cons_len < $pred_len) ? $cons_len : $pred_len;

  for(my $i = 0; $i < $min_len; $i++) { 
    if(uc($cons_seq_AR->[$i]) eq uc($pred_A[$i])) { 
      $nmatch++; 
    }
  }
  
  return $cons_len - $nmatch;
}  
