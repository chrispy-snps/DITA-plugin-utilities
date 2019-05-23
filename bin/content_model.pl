#!/usr/bin/perl
# content_model.pl - show the content model of a DITA topicshell or mapshell module
#
# Prerequisites on linux:
#
#  sudo apt update
#  sudo apt install cpanminus default-jre jing trang
#  sudo cpanm install XML::Twig

use strict;
use warnings;

use Getopt::Long 'HelpMessage';
use XML::Twig;
use File::Path qw(remove_tree);
use File::Copy;
use Cwd qw(realpath);
use File::Spec qw(rel2abs);
use File::Basename;
use Carp qw(croak);

if (!`which jing` || !`which trang`) {
 print "Error: 'jing' not found\n" if !`which jing`;
 print "Error: 'trang' not found\n" if !`which trang`;
 print "\njing and trang can be installed with:\n";
 print "\n  sudo apt update\n  sudo apt install default-jre jing trang\n";
 die;
}

my $ditaot = '';  # you can put your own default here, if you want
my $attributes = 'common';
my $attvalues = '';  # default is --noattvalues
my $split = '';   # default is --nosplit

GetOptions(
  'ditaot=s'     => \$ditaot,
  'attributes=s' => \$attributes,
  'attvalues'    => \$attvalues,
  'split'        => \$split,
  'verbose'      => sub {$split = 1; $attributes = 'all'; $attvalues = 1;},
  'help'         => sub { HelpMessage(0) }
  ) or HelpMessage(1);
do { print "Invalid value for --attributes\n\n"; HelpMessage(1); } if $attributes !~ m!^(none|common|all)$!;
my $filename = shift or HelpMessage(1);

# get DITA-OT directory path
my $ditaotfull = '';
if ($ditaot) {
 $ditaotfull = File::Spec->rel2abs($ditaot);  # use the provided path
 croak "Can't find '${ditaot}'\n" if !-e $ditaotfull;
 croak "'$ditaot' is not a directory\n" if !-d $ditaotfull;
} elsif (my $dita = `which dita`) {
 # try to find catalog file automatically (by finding 'dita' in search path)
 $dita =~ s!(^\s+|\s+$)!!m;
 croak "'$dita' is not a file\n" if !-f $dita;
 $ditaotfull = realpath(dirname(realpath(dirname(realpath($dita)))));
 croak "'$ditaotfull' is not a directory\n" if !-d $ditaotfull;
}

my $catopt = '';
if ($ditaotfull) {
 my $catfile = File::Spec->catdir($ditaotfull, "plugins/org.dita.base/catalog-dita.xml");
 croak "Can't find '${catfile}'\n" if !-e $catfile;
 $catopt = "-C $catfile";
}

# make temporary working directory
remove_tree('/tmp/cm');
mkdir '/tmp/cm' or croak "Can't mkdir /tmp/cm\n";

# gather files in RelaxNG format
run_cmd("trang $catopt $filename /tmp/cm/1.rng");  # even if the input is already RNG, this chases down catalog-based include files for us

# apply RelaxNG schema simplification
run_cmd("jing $catopt -s /tmp/cm/1.rng > /tmp/cm/2.rng");

# read RelaxNG XML into memory
my $twig=XML::Twig->new ( keep_encoding => 1, pi => 'process', comments => 'drop' )->parsefile('/tmp/cm/2.rng');

# perform any attribute pruning
if ($attributes eq 'none') {
 $_->delete for $twig->root->descendants('attribute');
} elsif ($attributes eq 'common') {
 my %attcount = ();
 my @elements = grep {$_->att('name') !~ m!^(title|row|entry)$!} $twig->root->descendants('element[@name]');
 $attcount{$_->att('name')}++ for map {$_->descendants('attribute[@name]')} @elements;
 foreach my $common_att (grep {(1.0 * $attcount{$_} / scalar(@elements)) > 0.95} keys %attcount) {
  $_->delete for $twig->root->descendants("attribute[\@name='$common_att']");
 }
}

# delete empty groups (recursively)
while (my @empty_groups = (grep {!$_->has_children('#ELT')} $twig->root->descendants('choice|zeroOrMore|oneOrMore|optional|group|interleave'))) {
 $_->delete for @empty_groups;
}
$_->insert_new_elt('first_child', 'empty') for grep {!$_->has_children('#ELT')} $twig->root->descendants('element');

# add <empty/> to otherwise-empty elements
$twig->root->sort_children(sub {$_[0]->{'att'}->{"name"} or ''});

# convert RelaxNG to RNC
$twig->print_to_file('/tmp/cm/3.rng', pretty_print => 'indented');
run_cmd("trang /tmp/cm/3.rng /tmp/cm/4.rnc");

# perform some string-based postprocessing
my $contents = `cat /tmp/cm/4.rnc`;
$contents =~ s!attribute\s+(\S+)\s+\{!\@$1 \{!gs;
$contents =~ s!(\@\S+)\s+\{.*?\}!$1!gs if !$attvalues;
$contents =~ s!\n\s+\| ! \| !gs if !$split;
$contents =~ s!,\n\s+\s+!, !gs if !$split;
$contents =~ s!=\n\s+element != element !gs;
$contents =~ s!\n\s+! !gs if !$split;

print $contents;

remove_tree('/tmp/cm');  # clean up after ourselves

sub run_cmd {  # print command line for debugging if errors are detected
 my $cmd = shift;
 if (system $cmd) {croak "Can't execute:\n  $cmd\n";}
}




=head1 NAME

content_model - show content model of DITA topicshell or mapshell module

=head1 SYNOPSIS

  <module_filename>
          Path to <topicshell> or <mapshell> DITA module (.rnc or .rng)
  [--ditaot <path>]
          Location of DITA-OT directory
          (default is to use DITA-OT of 'dita' found in search path)
  [--attributes none | common | all]
          Determine which attributes to show
          (default 'common')
  [--attvalues, --noattvalues]
          Determine whether to show attribute value content models
          (default is no values)
  [--split, --nosplit]
          Determine whether to allow element definitions to split across lines
          (default is not to split)
  [--verbose, -v]
          Show maximal information about the content model
          (equivalent to '--attributes all --attvalues --split')

=head1 VERSION

0.50

=cut
