package Match ;
#!/usr/bin/perl

##
## Copyright (C) 2015 IXA Taldea, University of the Basque Country UPV/EHU
##
## This file is part of ixa-pipe-domainterms.
##                                                                    
## ixa-pipe-domainterms is free software: you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by                                          
## the Free Software Foundation, either version 3 of the License, or                                                                             
## (at your option) any later version.                                                                                                          

## ixa-pipe-domainterms is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
## GNU General Public License for more details.                                                                                                 

## You should have received a copy of the GNU General Public License 
## along with ixa-pipe-domainterms. If not, see <http://www.gnu.org/licenses/>.  
##

#
# Erabiltzeko;
#
# use Match ;
#
# script-a Match.pm dagoen direktorio berean badago, hau jarri:
#
# use FindBin qw($Bin);
# use lib $Bin;
# use Match;
#
# Object Oriented interface:
#
#  my $vocab = new Match($dictionaryfile);
#
#  @multiwords = $vocab->do_match($words)        # splits input using spaces, ouputs multiwords with _
#  @multiwords = $vocab->do_match(\@wordsArray)  # output multiwords with _
#
#  $multiwords = $vocab->do_match($words)        # returns a join with spaces
#
# using indices one can work on the tokens at wish:
#
#   foreach my $idx ($vocab->match_idx(\@wordsArray)) {
#     my ($left, $right) = @{ $idx };
#     next if ($left == $right);       # malformed entity, ignore
#     print join("_", @wordsArray[$left .. $right-1])."\n";
#
# Traditional interface:
#
# matchinit($dictionaryfile) ;
# $multiwords = match($tokenizedlemmatizedtext) ;

use Exporter () ;
@ISA = qw(Exporter) ;
@EXPORT = qw(matchinit match) ;

use strict;
use Encode;
use DB_File;
use JSON;
use utf8;
binmode STDOUT, ":utf8";

use Carp qw(croak);

my $vocab;

sub matchinit {
  $vocab = new Match($_[0]);
}

sub match {
  $vocab->match_str($_[0]);
}

sub new {

  my $that = shift;
  my $class = ref($that) || $that;

  croak "Error: must pass dictionary filename"
    unless @_;
  my $fname = $_[0];
  my $fformat = $_[1];

  my $self = {
	      fname => $fname,
	      fformat => $fformat,
	      trie => {}
	     };
  bless $self, $class;

  $self->_init();
  return $self;
}


##########################################
# member functions

sub in_dict {

	my $self = shift;
	my $hw = shift;
	return 0 unless $hw;
	return 0 unless $self->{trie}->{$hw};
	return 1;
}

#
# returns matches as indices over tokens
#
sub match_idx {

  my $self = shift;
  my $ctx = shift;
  my $lmin = shift; # minimum lenght of the match minus one (default is zero)

  $lmin = 0 unless defined $lmin;

  croak "Match object not initialized!\n"
    unless $self->{trie};

  my $words = [];
  my %idxmap;
  #my $words = ref($ctx) ? $ctx : [split(/\s+/, $ctx)];
  my $j = 0;
  for (my $i = 0; $i < @{ $ctx }; $i++) {
	  my $w = $ctx->[$i];
	  $w =~ s/[-_]/ /g;
	  if ($w =~ /^\s+$/) {
		  push @{ $words }, " ";
		  $idxmap{$j} = $i;
		  $j++;
		  next;
	  }
	  foreach my $ww (split(/\s+/, $w)) {
		  push @{ $words }, $ww;
		  $idxmap{$j} = $i;
		  $j++;
	  }
  }
  my $Idx = [];
  my $Lemmas = [];
  my $Gazid = [];
  for (my $i=0; $i < @$words; $i++) {
    my ($j, $str, $gazid) = $self->_match($words,$i, $lmin);
    if ($j >= 0) {
		# there is a match
		push @{ $Idx }, [$idxmap{ $i }, $idxmap{ $i+$j }];
		push @{ $Lemmas }, $str;
		push @{ $Gazid }, $gazid;
		$i += $j ;
    } else {
      # there is no match
      ##push @A, $words->[$i];
    }
  }
  return ($Idx, $Lemmas, $Gazid);
}

#
# returns matches in lowercase
#
sub do_match {

  my $self = shift;
  my $ctx = shift;

  croak "Match object not initialized!\n"
    unless $self->{trie};

  my $words = ref($ctx) ? $ctx : [split(/\s+/, $ctx)];

  my @A;
  foreach my $ipair ($self->match_idx($words)) {
    my ($left, $right) = @{ $ipair };
    next if ($left == $right);
    push @A, join("_", @{$words}[$left..$right - 1]);
  }
  return wantarray ? @A : "@A";
}


#
# these two functions are kept for backwards compatibility
#

sub match_str {
  my $self = shift;
  return $self->do_match($_[0]);
}

sub match_arr {
  my $self = shift;
  return $self->do_match($_[0]);
}

# build structure trie-style
# $trie{'Abomination'} =>
# 0  HASH(0x83f5af8)
#    1 => ARRAY(0x83f5b40)   length 1
#       0  ''                     'Abomination'
#    2 => ARRAY(0x83f5ba0)   length 2
#       0  '(Bible)'              'Abomination (Bible)'
#       1  '(Dune)'               'Abomination (Dune)'
#       2  '(comics)'             'Abomination (comics)'
#       3  '(disambiguation)'     'Abomination (disambiguation)'
#    3 => ARRAY(0x83f5bf4)   length 3
#       0  'of Desolation'     'Abomination of Desolation'
#    4 => ARRAY(0x83f5c54)   length 4
#       0  'that Makes Desolate'     'Abomination that Makes Desolate'
#       1  'that causes Desolation'  'Abomination that causes Desolation'

sub _match {

  my $self = shift;
  my($words,$i, $lmin) = @_ ;
  my ($string,$k,$length) ;

  
  my $wkey = lc($words->[$i]);

  return -1 if ! defined $self->{trie}->{$wkey} ;

  foreach $length (reverse sort keys %{  $self->{trie}->{$wkey} }) {
	  next if $length < $lmin;
	  next if ($i+$length) > $#{ $words } ;
	  my $context = lc(join(" ",  @{$words}[$i+1..$i+$length])) ;
	  foreach my $entry (@{ $self->{trie}->{$wkey}{$length} }) {
	      return ($length, $entry->[1], $entry->[2]) if $context eq $entry->[0] ;
	  }
  }
  return -1 ;
}

sub _init {

  my ($self) = @_;

  my $fname = $self->{fname};
  my $fformat = $self->{fformat};

  if($fformat eq "txt"){
      my $fh;
      if ($fname =~ /\.bz2$/) {
	  open($fh, "-|:encoding(UTF-8)", "bzcat $fname");
      } else {
	  open($fh, "<:encoding(UTF-8)", "$fname");
      }
      while (<$fh>) {
	  chomp;
	  my $entry = $_;
	  if($entry !~ /\|\|/){
	      die "ERROR: Malformed dictionary entry\nEntry example: tiempo de reformas||ID-89||CID-445\nIf you are using a JSON format dictionary, add -j parameter\n";
	  }
	  my ($words,$id,$classid) = split('\|\|',$entry);
	  my ($firstword, @rwords) = split(/[_-\s]+/,lc($words));
	  next unless $firstword;
	  #next unless @rwords;
	  my $length = @rwords ;
	  push @{ $self->{trie}->{$firstword}->{$length} },
	  [join(" ", @rwords), $entry, $id]
      }
  }
  elsif($fformat eq "json"){
      my $json_text = do {
	  my $fh;
	  if ($fname =~ /\.bz2$/) {
      	      open ($fh, "-|:encoding(UTF-8)", "bzcat $fname")
		  or die("Can't open \$fname\": $!\n");
 	  } else {
	      open($fh, "<:encoding(UTF-8)", $fname)
		  or die("Can't open \$fname\": $!\n");
	  }
	  local $/;
	  <$fh>
      };
      my $json = JSON->new;
      my $data = $json->decode($json_text);
      for my $entry ( @{$data->{data}} ) {
	  my($firstword,@rwords) = split(/[_-\s]+/,lc($entry->{desc}));
	  my $id = $entry->{id};
	  my $classid = $entry->{idclass};
	  my $length = @rwords ;
	  push @{ $self->{trie}->{$firstword}->{$length} },
	  [join(" ", @rwords), $entry, $id]
      }
  }
}



sub poss {

	my $S = shift;
	my %P;
	foreach my $s (@{ $S } ) {
		$s =~ s/:\d+$//;
		next unless $s =~ /-([^-]+)$/;
		$P{$1} = 1;
	}
	return join("", sort keys %P);
}

sub remove_freq {

  my @res;
  foreach my $str (@_) {
    my @aux = split(/:/, $str);
    if (@aux > 1 && $aux[-1] =~ /\d+/) {
      pop @aux;
    }
    push @res, join(":", @aux);
  }
  return @res;
}

(1) ;
