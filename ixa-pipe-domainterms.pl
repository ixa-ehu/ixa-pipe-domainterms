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


use strict;

use XML::LibXML;
use File::Temp;
use File::Basename;
use IPC::Open3;
use IO::Select;
use Symbol;						# for gensym
use Sys::Hostname;
use FindBin qw($Bin);
use lib $Bin;
use Match;
use Data::Dumper;
use 5.010;

binmode STDOUT;

use Getopt::Std;

my %opts;

my $VERSION = "1.0.0"; # @@ TODO
my $SOURCE = "ixa-pipe-domainterms";

getopts('m:D:j', \%opts);

my $dict_file = $opts{'D'};
$dict_file = $opts{'D'} unless $dict_file;

my $fname;

if (!@ARGV || $ARGV[0] eq "--") {
	$fname = "<-";
} else {
	$fname = shift;
}

&usage("Error: no dictionary") unless -f $dict_file;

# @@ By now, mw is done with --nopos

my $opt_nopos = 1;

# default POS mapping for KAF

my %POS_MAP = ("^N.*" => 'n',
			   "^R.*" => 'n',
			   "^G.*" => 'a',
			   "^V.*" => 'v',
			   "^A.*" => 'r');

%POS_MAP = &read_pos_map( $opts{'m'} ) if $opts{'m'};

open(my $fh_fname, $fname);
binmode $fh_fname;

my $dict_format = "txt";
$dict_format = "json" if $opts{'j'};

my $VOCAB = new Match($dict_file,$dict_format);

my $parser = XML::LibXML->new();
my $doc;

eval {
	$doc = $parser->parse_fh($fh_fname);
};
die $@ if $@;

my $root = $doc->getDocumentElement;

my $beg_tstamp = &get_datetime();

# $idRef -> array with sentence id's
# $docRef -> docs
# e.g.
# $idRef->[0] -> id of first setence
# $docRef->[0] first sentence ([ { lema => word_form(s) id => markid, xref => string, spanid => [wid1, wid2] } ...])

my ($idRef, $docRef) = &getSentences($root);

my $Sents;    # [ ["lemma#pos#mid", "lemma#pos#mid" ...], ... ]
my $id2mark;  # { mid => mark_elem }

($Sents, $id2mark) = &create_markables_layer($doc, $idRef, $docRef);

# $doc->toFH(\*STDOUT, 1);
# die;

&add_lp_header($doc, $beg_tstamp, &get_datetime());

$doc->toFH(\*STDOUT, 1);

sub wid {
	my $wf_elem = shift;
	my $wid = $wf_elem->getAttribute('id');
	return $wid if defined $wid;
	return $wf_elem->getAttribute('wid');
}

sub tid {
	my $term_elem = shift;
	my $tid = $term_elem->getAttribute('id');
	return $tid if defined $tid;
	return $term_elem->getAttribute('tid');
}

sub getSentences {

	my ($root) = @_;

	my %tid2telem;

	my $wid2sent;	   # { wid => sid }
	my $wid2off;	   # { wid => off } note: offset is position in sentence
	my $WW;			   # { sid => { V => [ w1, w2, w3, ...], ids => [ wid1, wid2 ] }
	my $Sids;		   # [ sid1, sid2, ... ]

	($Sids, $WW, $wid2sent, $wid2off) = &sentences_words($root);

	my $MW = {}; # { sid => [ { lemma => lema, xref => string, span = >[ a1, b1 ], spanid => [ w1, w2 ] }, ... ] }
	# note: spans are inervals with [a, b]

	$MW = &sentences_match_spans($Sids, $WW);

	my $Ctxs = [];
	foreach my $sid (@{ $Sids }) {

		my $ctx = [];
		my $mws = $MW->{$sid};
		my $m_mw = scalar @{ $mws };
		for (my $i = 0; $i < $m_mw; $i++) {
			&push_ctx($ctx, $mws->[$i]);
		}
		push @{ $Ctxs }, $ctx if @{ $ctx };
	}

	return ($Sids, $Ctxs);
	# $idRef->[0] -> id of first setence
	# $docRef->[0] firt sentence ([ { lema => word_form(s) id => markid, xref => string, spanid => [wid1, wid2] } ...])
}

sub push_ctx {

	my ($ctx, $tmw) = @_;
	state $id_n = 0;

	$id_n++;
	my $id = "m".$id_n;
	push @{ $ctx }, { lemma => $tmw->{lemma}, xref => $tmw->{xref}, id=> $id, spanid => $tmw->{spanid} } ;
}

sub sentences_term_spans {

	my ($root, $wid2sent, $wid2off) = @_;

	my $Terms = {}; # { sid => [ { id => tid, lemma => lema, pos=>pos, span => [ a1, b1 ] }, ... ] }

	foreach my $term_elem ($root->findnodes('terms/term')) {

		my $lemma = &filter_lemma($term_elem->getAttribute('lemma'));
		my $pos = $term_elem->getAttribute('pos');
		$pos = &trans_pos($pos);
		my $tid = &tid($term_elem);

		my %sids;
		my @spanids;
		my ($a, $b);			# span interval
		foreach my $target_elem ($term_elem->getElementsByTagName('target')) {
			my $wid = $target_elem->getAttribute('id');
			my $wsid = $wid2sent->{$wid};
			next unless defined $wsid;
			my $off = $wid2off->{$wid};
			next unless defined $off;
			push @spanids, $wid;
			$sids{$wsid} = 1;
			$a = $off if not defined $a or $off < $a;
			$b = $off if not defined $b or $off > $b;
		}
		next unless defined $a;
		my @sent_ids= keys %sids;
		next unless @sent_ids;
		warn "Error: term $tid crosses sentence boundaries!\n" if @sent_ids > 1;
		my $sid = shift @sent_ids;
		push @{ $Terms->{$sid} }, { lemma => $lemma, valid => $VOCAB->in_dict($lemma), pos => $pos, span => [$a, $b], spanid => \@spanids };
	}
	my $Result = {};
	# sort all according the spans
	while (my ($k, $v) = each %{ $Terms }) {
		my @sv = sort { $a->{span}->[0] <=> $b->{span}->[0] } @{ $v } ;
		$Result->{$k} = \@sv;
	}
	return $Result;
}

sub sentences_match_spans {

	my ($Sids, $WW) = @_;
	my $MW = {}; # { sid => [ { lemma => lema, xref => string, span = >[ a1, b1 ], spanid => [ w1, w2 ] }, ... ] }

	foreach my $sid ( @{ $Sids } ) {
		my $mw = [];
		my $W = $WW->{$sid};
		my ($spans, $lemmas, $gazids) = $VOCAB->match_idx($W->{V}, 1);
		for (my $i = 0; $i < @{ $spans }; $i++) {
			my @ids = @{ $W->{ids} }[ $spans->[$i]->[0] .. $spans->[$i]->[1] ];
			my $wforms = join(" ", @{ $W->{V} }[ $spans->[$i]->[0] .. $spans->[$i]->[1] ]);
			push @{ $mw }, { lemma => $wforms, xref => $gazids->[$i], span => $spans->[$i], spanid => \@ids };
		}
		$MW->{$sid} = $mw;
	}
	return $MW;
}

sub sentences_words {

	my ($root) = @_;

	my $wid2sent = {} ;	# { wid => sid }
	my $wid2off = {};   # { wid => off } note: offset is position in sentence
	my $WW;			    # { sid => { V => [ w1, w2, w3, ...], ids => [ wid1, wid2 ] }
	my $S = [];		    # [ sid1, sid2, ... ]
	my $W = [];
	my $ID = [];
	my $last_sid = undef;
	my $last_off = 0;
	foreach my $wf_elem ($root->findnodes('text//wf')) {
		my $wid = &wid($wf_elem);
		my $str = $wf_elem->textContent;
		next unless $str;
		my $sent_id = $wf_elem->getAttribute('sent');
		$sent_id ="fake_sent" unless $sent_id;
		substr($sent_id, 0, 0) = "s" if $sent_id =~ /^\d/;
		if (not defined $last_sid or $sent_id ne $last_sid) {
			if (defined $last_sid) {
				$WW->{$last_sid} = { V => $W, ids => $ID } if @{ $W };
				push @{ $S }, $last_sid;
			}
			$last_sid = $sent_id;
			$W = [];
			$ID = [];
			$last_off = 0;
		}
		$wid2sent->{$wid}= $sent_id;
		push @{ $W }, $str;
		push @{ $ID }, $wid;
		$wid2off->{$wid} = $last_off;
		$last_off++;
	}
	if ( @{ $W } ) {
		$WW->{$last_sid} = { V => $W, ids => $ID };
		push @{ $S }, $last_sid;
	}

	return ($S, $WW, $wid2sent, $wid2off);
}

sub span_cmp {

	my ($s1, $s2) = @_;
	return -1 if ($s1->[1] < $s2->[0]);
	return +1 if ($s1->[0] > $s2->[1]);
	return 0;
}


sub filter_lemma {

	my $lemma = shift;

	return undef unless $lemma;
	return undef if $lemma =~ /\#/;	# ukb does not like '#' characters in lemmas
	$lemma =~s/\s/_/go;	     # replace whitespaces with underscore (for mws)
	return $lemma;
}

sub w_count {

	my $aref = shift;
	my $n = 0;
	foreach (@{$aref}) {
		$n+=scalar @{$_};
	}
	return $n;
}

sub trans_pos {

	my ($pos) = @_;

	my @k = keys %POS_MAP;
	return $pos unless @k;		# if no map, just return input.

	foreach my $posre (keys %POS_MAP) {
		return $POS_MAP{$posre} if $pos =~ /$posre/i ;
	}
	return undef;				# no match
}

sub read_pos_map {

	my $fname = shift;

	open(my $fh, $fname) || die "Can't open $fname:$!\n";
	my %H;
	while (<$fh>) {
		chomp;
		my ($k, $v) = split(/\s+/, $_);
		$H{$k}=$v;
	}
	return %H;
}

sub try_wsd {

	my $cmd = shift;
	my $v = qx($cmd --version);
	my $ok = ($? == 0);
	chomp $v;
	return "" unless $ok;
	return $v;
}

sub create_markables_layer {

	my ($xmldoc, $idRef, $docRef) = @_;

	my $naf_elem = $xmldoc->getDocumentElement;
	my $markables_elem = $xmldoc->createElement("markables");
	$markables_elem->setAttribute("source", $SOURCE);
	foreach my $doc ( @{ $docRef } ) {
		my $ctx = [];
		foreach my $cw ( @{ $doc } ) {
			my $mark_elem = $xmldoc->createElement("mark");
			my $markid = $cw->{id};
			$mark_elem->setAttribute("id", $markid);
			$mark_elem->setAttribute("lemma", $cw->{lemma});
			$mark_elem->setAttribute("pos", $cw->{pos}) if $cw->{pos};
			my $span_elem = $xmldoc->createElement("span");
			foreach my $wid ( @{ $cw->{spanid} } ) {
				my $tgt_elem = $xmldoc->createElement("target");
				$tgt_elem->setAttribute("id", $wid);
				$span_elem->addChild($tgt_elem);
			}
			$mark_elem->addChild($span_elem);
			my $xrefs_elem = $xmldoc->createElement('externalReferences');
			my $xref_elem = $xmldoc->createElement('externalRef');
			$xref_elem->setAttribute('resource', $dict_file);
			$xref_elem->setAttribute('reference', $cw->{xref});
			$xrefs_elem->addChild($xref_elem);
			$mark_elem->addChild($xrefs_elem);
			$markables_elem->addChild($mark_elem);
		}
	}
	$naf_elem->addChild($markables_elem);
}

sub add_lp_header {

	my ($doc, $beg_tstamp, $end_tstamp) = @_;

	# see if kafHeader exists and create if not

	my ($doc_elem_name, $hdr_elem) = &locate_hdr_elem($doc);
	if (! defined($hdr_elem)) {
		# create and insert as first child of KAF element
		my ($kaf_elem) = $doc->findnodes("/$doc_elem_name");
		die "root <$doc_elem_name> element not found!\n" unless defined $kaf_elem;
		my ($fchild_elem) = $doc->findnodes("/$doc_elem_name/*");
		my $hdr_name = lc($doc_elem_name)."Header";
		$hdr_elem = $doc->createElement($hdr_name);
		$kaf_elem->insertBefore($hdr_elem, $fchild_elem);
	}

	# see if <linguisticProcessor layer="terms"> exists and create if not

	my ($lingp_elem) = $hdr_elem->findnodes('//linguisticProcessors[@layer="markables"]');
	if (! defined($lingp_elem)) {
		$lingp_elem = $doc->createElement('linguisticProcessors');
		$lingp_elem->setAttribute('layer', 'markables');
		$hdr_elem->addChild($lingp_elem);
	}

	my $lp_elem = $doc->createElement('lp');
	$lp_elem->setAttribute('name', 'ixa-pipe-domainterms');
	$lp_elem->setAttribute('version', $VERSION);
	$lp_elem->setAttribute('beginTimestamp', $beg_tstamp);
	$lp_elem->setAttribute('endTimestamp', $end_tstamp);
	$lp_elem->setAttribute('hostname', hostname);
	$lingp_elem->addChild($lp_elem);
}

# second level element, ending with "*Header"
sub locate_hdr_elem {
	my $doc = shift;
	my $doc_elem = $doc->getDocumentElement;
	foreach my $child_elem ($doc_elem->childNodes) {
		next unless $child_elem->nodeType == XML::LibXML::XML_ELEMENT_NODE;
		return ($doc_elem->nodeName, $child_elem) if $child_elem->nodeName =~ /Header$/;
	}
	return ($doc_elem->nodeName, undef);
}

sub get_datetime {

	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=gmtime(time);
	return sprintf "%4d-%02d-%02dT%02d:%02d:%02dZ", $year+1900,$mon+1,$mday,$hour,$min,$sec;

}

sub usage {

	my $str = shift;

	print STDERR $str."\n";
#	die "usage: $0 [-m pos_mapping_file ] -D dict.json [-j] naf_input.txt \n";
	die "usage: $0 -D dict.json -j naf_input.txt \n";
}
