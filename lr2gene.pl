#!/usr/bin/env perl

# Normalize the coverage from targeted sequencing to CNV log2 ratio.  The algorithm assumes the medium 
# is diploid, thus not suitable for homogeneous samples (e.g. parent-child).

use warnings;
use FindBin;
use lib "$FindBin::Bin/libraries/";
use Stat::Basic;
use Statistics::TTest;
use Getopt::Std;
use strict;

our ($opt_c, $opt_s, $opt_A, $opt_D, $opt_M, $opt_d, $opt_p, $opt_H, $opt_R, $opt_N, $opt_t, $opt_P, $opt_y, $opt_E, $opt_e);

getopts( 'HcyF:s:A:D:d:M:p:R:N:t:P:E:e:' ) || USAGE();
$opt_H && USAGE();

my $MINMAD = defined($opt_M) ? $opt_M : 10;
my $MINDIFF = defined($opt_d) ? $opt_d : 0.7;
my $PVALUE = defined($opt_p) ? $opt_p : 0.00001;
my $AMP = defined($opt_A) ? $opt_A : 1.5;
my $DEL = defined($opt_D) ? $opt_D : -2.00;
my $EXONDIFF = defined($opt_E) ? $opt_E : 1.25;
my $MAXRATE = defined($opt_R) ? $opt_R : 0.1; # maximum 
my $MAXCNT = defined($opt_N) ? $opt_N : 5;
my $MINTTDIFF = defined($opt_t) ? $opt_t : 0.7;
my $TTPVALUE = defined($opt_P) ? $opt_P : 0.000001;
my $MINBPEXONS = defined($opt_e) ? $opt_e : 8;

my $MINSEGS = $opt_s ? $opt_s : 1;
#print join("\t", qw(Sample Gene Chr Start Stop Length Log2Ratio Significance Breakpoint Type Aff_segs Total_segs Aff_segs_lr)), "\n";
my %g2amp;
my $stat = new Stat::Basic;
my $ttest = new Statistics::TTest;
my %loc;
while( <> ) {
    s/\r//g;
    chomp;
    next if ( /^Sample/ );
    my @a = split(/\t/);
    my ($sample, $gene, $chr, $s, $e, $desc, $len, $depth) = @a;
    $loc{ $gene }->{ chr } = $chr;
    $loc{ $gene }->{ start } = $s unless( $loc{ $gene }->{ start } && $loc{ $gene }->{ start } < $s );
    $loc{ $gene }->{ end } = $e unless( $loc{ $gene }->{ end } && $loc{ $gene }->{ end } > $e );
    $loc{ $gene }->{ len } += $e - $s + 1;
    push(@{ $g2amp{ $sample }->{ $gene } }, \@a);
}

my @results =();
my %callcnt;
while(my ($s, $v) = each %g2amp) {
    while(my ($g, $vv) = each %$v) {
	my @segs = sort { $a->[3] <=> $b->[3] } @$vv;
	my @lr = map { $opt_c ? $_->[11] : $_->[10]; } @segs;
	my $lr = @lr > 1 ? $stat->median(\@lr) : $lr[0];
	my ($sig, $bp, $type, $affected, $total, $siglr, $sigseg, $sigdiff) = checkBP(\@segs);
	if ($sig eq "-1") {
	    if ( $lr >= $AMP ) {
		($sig, $bp, $type, $affected, $total, $siglr, $sigseg, $sigdiff) = ("0", "Whole", "Amp", @lr+0, @lr+0, $lr, "ALL", $lr);
	    } elsif ( $lr <= $DEL ) {
		($sig, $bp, $type, $affected, $total, $siglr, $sigseg, $sigdiff) = ("0", "Whole", "Del", @lr+0, @lr+0, $lr, "ALL", $lr);
	    }
	}
	$sig = "" if ( $sig == -1 );
	$sigdiff = sprintf("%.2g", $sigdiff) if ( $sigdiff);
	if (  $sigseg && $sigseg =~ /\d/ ) {
	    my @exons = split(/,/, $sigseg);
	    my $estart = $segs[$exons[0]-1]->[3];
	    my $eend = $segs[$exons[$#exons]-1]->[4];
	    $sigseg .= "($estart-$eend)";
	}
	push(@results, [$s, $g, $loc{$g}->{chr}, $loc{$g}->{start}, $loc{$g}->{end}, $loc{$g}->{len}, $lr, $sig, $bp, $type, $affected, $total, $siglr, $sigdiff, $sigseg]); # if ( $sig ne "-1" );
	$callcnt{ "$g:$bp:$sigseg" }++ if ( $sigseg && $bp eq "BP" );
    }
}

my @samples = keys %g2amp;
print join("\t", qw(Sample Gene Chr Start End Length Log2ratio Sig BP_Whole Amp_Del Ab_Seg Total_Seg Ab_log2ratio Log2r_Diff Ab_Seg_Loc Ab_Samples Ab_Samples_Pcnt)), "\n";
foreach my $r (@results) {
    my ($g, $bp, $sigseg) = ($r->[1], $r->[8], $r->[14]);
    my ($cnt, $pcnt) = $callcnt{ "$g:$bp:$sigseg" } ? ($callcnt{ "$g:$bp:$sigseg" }, sprintf("%.3g", $callcnt{ "$g:$bp:$sigseg" }/(@samples+0))) : ("", "");
    my @tmp = @$r;
    if ( $pcnt && $pcnt > $MAXRATE && $cnt > $MAXCNT ) { # remove frequency breakpoints, likely due to systematic sequencing yields
        @tmp = (@tmp[0..6], "", "", "", "", $r->[10], "", "", "");
    }
    print join("\t", @tmp, $cnt, $pcnt), "\n";
}

sub checkBP {
    my $ref = shift;
    return (-1, "", "", "", @$ref+0, "", "", "") if ( @$ref < 4 );
    my @a = map { $opt_c ? [$_->[3], $_->[11]] : [$_->[3], $_->[10]]; } @$ref;
    my @lr = map { $_->[1]; } @a;
    for(my $i = 0; $i < @a; $i++) {
        $a[$i]->[2] = $i+1;
    }
    my $max = $stat->max(\@lr);
    my $min = $stat->min(\@lr);
    my $mid = ($max + $min)/2;
    #print STDERR join(" ", (map { $stat->prctile(\@lr, $_); } (20, 40, 60, 80))), "\n";
    my @bps = getBPS(\@lr);
    #print STDERR "BPS: @bps\n";
    my @sigbp = ();
    my @sigmd = ();
    my $minbp = 1;
    my $maxmd = 1;
    my $maxdiff = "";
    foreach my $bp (@bps) {
	my @up = ();
	my @bm = ();
	my @lrup = ();
	my @lrbm = ();
	my @upseg = ();
	my @bmseg = ();
	for(my $i = 0; $i < @a; $i++) {
	    my $a = $a[$i];
	    $a->[1] > $bp ? push(@up, $a) : push(@bm, $a);
	    $a->[1] > $bp ? push(@lrup, $a->[1]) : push(@lrbm, $a->[1]);
	    $a->[1] > $bp ? push(@upseg, $i+1) : push(@bmseg, $i+1);
	}
	my $upseg = join(",", @upseg);
	my $bmseg = join(",", @bmseg);
	my $lrupm = $stat->median(\@lrup);
	my $lrbmm = $stat->median(\@lrbm);
	my $cn = $lrbmm < -0.35 ? "Del" : ($lrupm > 0.35 && abs($lrbmm) < abs($lrupm) ? "Amp" : "NA");
	next if ($cn eq "NA");
	my @calls = ();
	my ($bmisc, $bmi, $bmii) = isConsecutive(\@bm);
	my ($upisc, $upi, $upii) = isConsecutive(\@up);
	if ( $bmisc ) {
	    if ( $bmi != -1 ) {
		my $ti;
	        for(my $i = 0; $i < @up; $i++) {
		    $ti = $i if ( $up[$i]->[2] == $bmi );
		}
		splice(@bm, $bmii, 0, splice(@up, $ti, 1));
	    }
	    @calls = ("BP", getCalls(\@bm, \@up));
	    my ($sig, $sdiff) = isSig(\@bm, \@up);
	    if ( $sig >= 0 && $sig < $minbp ) {
		@sigbp = ($sig, @calls, $sdiff);
		$minbp = $sig;
	    } elsif ( $sig > $maxmd ) {
		@sigmd = ($sig, @calls, $sdiff);
	        $maxmd = $sig;
	    }
	#} elsif ( $upisc && $cn ne "NA" ) {
	} elsif ( $upisc ) {
	    if ( $upi != -1 ) {
	        my $ti;
	        for(my $i = 0; $i < @bm; $i++) {
		    $ti = $i if ( $bm[$i]->[2] == $upi );
		}
		splice(@up, $upii, 0, splice(@bm, $ti, 1));
	    }
	    @calls = ("BP", getCalls(\@up, \@bm));
	    my ($sig, $sdiff) = isSig(\@up, \@bm);
	    if ( $sig >= 0 && $sig < $minbp ) {
		@sigbp = ($sig, @calls, $sdiff);
		$minbp = $sig;
	    } elsif ($sig > $maxmd ) {
		@sigmd = ($sig, @calls, $sdiff);
		$maxmd = $sig;
	    }
	}
    }
    return @sigbp if ( @sigbp );
    return @sigmd if ( @sigmd );
    my ($sig, $bpi, $cn, $siglr, $sigdiff, $sigseg) = findBP(\@lr);
    if ($sig != -1 ) {
	return (sprintf("%.3g", $sig), "BP", $cn, $bpi, @a+0, sprintf("%.3g", $siglr), $sigseg, $sigdiff);
    }
    return ("-1", "", "", "", @a+0, "", "", "");
}

sub getCalls {
    my ($ref1, $ref2) = @_;
    my @tlr1 = map { $_->[1]; } @$ref1;
    my @ti1 = map { $_->[2]; } @$ref1;
    my @tlr2 = map { $_->[1]; } @$ref2;
    my @ti2 = map { $_->[2]; } @$ref2;
    my $mean1 = sprintf("%.3g", $stat->mean(\@tlr1));
    my $mean2 = sprintf("%.3g", $stat->mean(\@tlr2));
    my $cn = "NA";
    my $segs = "";
    my $mean;
    my $ti = "";
    if ( abs($mean1) > abs($mean2) ) {
        $cn = $mean1 < -0.35 ? "Del" : ($mean1 > 0.35 ? "Amp" : "NA");
	$segs = @tlr1+0;
	$mean = $mean1;
	$ti = join(",", @ti1);
    } else {
        $cn = $mean2 < -0.35 ? "Del" : ($mean2 > 0.35 ? "Amp" : "NA");
	$segs = @tlr2+0;
	$mean = $mean2;
	$ti = join(",", @ti2);
    }
    
    return ($cn, $segs, @$ref1+@$ref2, $mean, $ti);
}

# Find the candidate breakpoint values
sub getBPS {
    my $lr = shift;
    my @lrs = sort {$a <=> $b} @$lr;
    my @dis = ();
    for(my $i = 1; $i < @lrs; $i++) {
        push(@dis, [$lrs[$i] - $lrs[$i-1], $lrs[$i], $lrs[$i-1]]);
    }
    @dis = sort {$b->[0] <=> $a->[0]} @dis;
    my @bps = ();
    foreach my $bp (@dis) {
        last if ( $bp->[0] < 0.1 );
	push(@bps, ($bp->[1]+$bp->[2])/2);
    }
    return @bps;
}

# Find the breakpoint in the middle, assuming resulting in two significant segments, where each
# segment has at least 4 amplicons/exons
sub findBP {
    my $lr = shift;
    return (-1, "", "", "", "", "") if (@$lr < 15);
    my ($minp, $bpi, $siglr, $cn, $mindiff, $sigseg) = (1, 0, 0, "NA", 0, "");
    for(my $i = $MINBPEXONS; $i < @$lr - $MINBPEXONS; $i++) {
        my @x = sort { $a <=> $b } (map { $lr->[$_]; } (0 .. ($i-1)));
        my @y = sort { $a <=> $b } (map { $lr->[$_]; } ($i .. (@$lr-1)));
	my $bpleft = $stat->mean(\@x);
	my $bpright = $stat->mean(\@y);
	next if ( $bpleft > $bpright && $x[1] < $y[$#y-1] );
	next if ( $bpleft < $bpright && $y[1] < $x[$#x-1] );
	$ttest->load_data(\@x, \@y);
	my $p = $ttest->{ t_prob };
	my $diff = $ttest->mean_difference();
	print STDERR "FindBP: $i $p $diff $bpleft $bpright\n" if ( $opt_y );
	if (($p < $minp || ( ($p > 0 && $minp/$p < 10 && abs($diff) > $mindiff ) || ($p == 0 && abs($diff) > $mindiff) )) && (($p < $TTPVALUE && abs($diff) > $MINTTDIFF) || ($p < 0.001 && abs($diff) >= $MINTTDIFF && (abs($bpleft) > 0.80 || abs($bpright) > 0.80 )))) {
	    $minp = $p;
	    $bpi = abs($bpleft) > abs($bpright) ? $i : (@$lr - $i + 1);
	    $siglr = abs($bpleft) > abs($bpright) ? $bpleft : $bpright;
	    $sigseg = abs($bpleft) > abs($bpright) ? join(",", (1 .. $i)) : join(",", (($i+1) .. (@$lr+0)));
	    $cn = abs($bpleft) > abs($bpright) ? ($bpleft < -0.5 ? "Del" : ($bpleft > 0.5 ? "Amp" : "NA") ) : ($bpright < -0.5 ? "Del" : ($bpright > 0.5 ? "Amp" : "NA" ));
	    $mindiff = abs($diff);
	}
    }
    if ($minp < 1) {
        return ($minp, $bpi, $cn, $siglr, $mindiff, $sigseg); 
    }
    return (-1, "", "", "", "", "");
}


sub isSig {
    my ($a, $b) = @_;
    my @x = map { $_->[1]; } @$a;
    my @y = map { $_->[1]; } @$b;
    if (@$a >= 3 && @$b >= 3) {
	$ttest->load_data(\@x, \@y);
	my $p = $ttest->{ t_prob };
	my $diff = $ttest->mean_difference();
	print STDERR "p: $p $diff ", @x+0, "\n" if ( $opt_y );
	return (sprintf("%.3g", $p), abs($diff)) if ( ($p < $PVALUE && abs($diff) >= $MINDIFF ) || ($p < 0.001 && abs($diff) >= $MINDIFF && (abs($stat->mean(\@x)) > 0.80 || abs($stat->mean(\@y)) > 0.80 )) );
    } elsif( @$a >= $MINSEGS && @$b >= 3 ) {
	my $med = $stat->median(\@y);
	my $mad = $stat->mad(\@y, 1);
	$mad += 0.1 unless($mad);
	my @t = map { ($_->[1]-$med)/$mad; } @$a;
	my $mean = $stat->mean(\@t);
	my $sum = $stat->sum(\@t);
	my $diff = abs($stat->mean(\@x)-$stat->mean(\@y));
	print STDERR "MAD: $mean $diff\n" if ( $opt_y );
	return (sprintf("%.2g", abs($mean)), $diff) if ( abs($sum) > $MINMAD && $diff > $EXONDIFF ); # || abs($stat->mean(\@x)-$stat->mean(\@y)) > 1.0 );
    } elsif( @$b >= $MINSEGS && @$a >= 3 ) {
	my $med = $stat->median(\@x);
	my $mad = $stat->mad(\@x, 1);
	#print STDERR join("\t", @x, $mad), "\n" unless($mad);
	$mad += 0.1 unless($mad);
	my @t = map { ($_->[1]-$med)/$mad; } @$b;
	my $mean = $stat->mean(\@t);
	my $sum = $stat->sum(\@t);
	my $diff = abs($stat->mean(\@x)-$stat->mean(\@y));
	print STDERR "MAD: '@t' $mean $diff\n" if ( $opt_y );
	return (sprintf("%.2g", abs($mean)), $diff) if ( abs($sum) > $MINMAD && $diff > $EXONDIFF ); # || abs($stat->mean(\@x)-$stat->mean(\@y)) > 1.0 );
    }
    return (-1, "");  # Either too few to tell or not sig
}

sub isConsecutive {
    my $ref = shift;
    my $skip = 0;
    my ($si, $sii) = (-1, -1);
    for(my $i = 1; $i < @$ref; $i++) {
	$skip += $ref->[$i]->[2] - $ref->[$i-1]->[2] - 1;
	($si, $sii) = ($ref->[$i]->[2] - 1, $i) if ( $ref->[$i]->[2] - $ref->[$i-1]->[2] == 2 );
    }
    return (1, $si, $sii) if ( $skip == 0 );
    if ( $skip == 1 && @$ref >=10  ) {  # one outlier allowed
        return (1, $si, $sii);
    }
    return (0, $si, $sii);
}

sub USAGE {
getopts( 'aPc:F:s:A:D:' );
print <<USAGE;
    Usage: $0 [-aPH] [-c control] [-F float] [-s min_amplicon_#] [-A float] [-D float] mapping_reads coverage.txt

    The $0 program will convert a coverage file to copy number profile.

    Arguments are:
    mapping_reads: Required.  A file containing # of mapped or sequenced reads for samples.  At least two columns.
                   First is the sample name, 2nd is the number of mapped or sequenced reads.
    coverage.txt:  The coverage output file from checkCov.pl script.  Can also take from standard in or more than
                   one file.

    Options are:

    -c Indidate that control sample is used for normalization
    -B Debugging mode

    -s int
       The minimum consecutive amplicons to look for deletions and amplifications.  Default: 1.  Use with caution
       when it's less than 3.  There might be more false positives.  Though it has been successfully applied with
       option "-s 1" and identified one-exon deletion of PTEN and TP53 that were confirmed by RNA-seq.

    -A float
       Minimum log2 ratio for a whole gene to be considered amplified.  Default: 1.50
       
    -D float
       Minimum log2 ratio for a whole gene to be considered deleted.  Default: -2.00

    -E float
       Minimum mean log2 ratio difference for <3 exon deletion/amplification to be called.  Default: 1.25
       
    -M float
       When considering partial deletions less than 3 exons/amplicons, the minimum MAD value, in addition to -d,
       before considering it to be amplified or deleted.  Default: 10

    -d float
       When considering >=3 exons deletion/amplification within a gene, the minimum differences between the log2 of two segments.
       Default: 0.7

    -t float
       When considering breakpoint in the middle of a gene, the minimum differences between the log2 of two segments.
       Default: 0.7

    -e float
       When considering breakpoint in the middle of a gene, the minimum number of exons.  Default: 8
       
    -p float (0-1)
       The p-value for t-test when consecutive exons/amplicons are >= 3.  Default: 0.00001

    -P float (0-1)
       The p-value for t-test when the breakpoint is in the middle with min exons/amplicons >= [-e].  Default: 0.000001

    -R float (0-1)
       If a breakpoint has been detected more than "float" fraction of samples, it's considered false positive and removed.
       Default: 0.1, or 10%.  Use in combination with -N

    -N int
       If a breakpoint has been detected more than "int" samples, it's considered false positives and removed.
       Default: 5.  Use in combination with -R.

AUTHOR
       Written by Zhongwu Lai, AstraZeneca, Boston, USA

REPORTING BUGS
       Report bugs to zhongwu\@yahoo.com

COPYRIGHT
       This is free software: you are free to change and redistribute it.  There is NO WARRANTY, to the extent permitted by law.

USAGE
exit(0);
}
