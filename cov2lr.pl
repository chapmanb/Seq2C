#!/usr/bin/env perl

# Normalize the coverage from targeted sequencing to CNV log2 ratio.  The algorithm assumes the medium 
# is diploid, thus not suitable for homogeneous samples (e.g. parent-child).

use Stat::Basic;
use Statistics::TTest;
use Getopt::Std;
use strict;

our ($opt_c, $opt_a, $opt_H, $opt_F, $opt_G, $opt_Y, $opt_M, $opt_y, $opt_Z, $opt_z);

getopts( 'HaMyZc:F:G:z:' ) || USAGE();
$opt_H && USAGE();
my $FAILEDFACTOR = $opt_F ? $opt_F : 0.2;
my $YRATIO = $opt_Y ? $opt_Y : 0.15; # for gender testing

if ( $opt_Z ) {
    open( FZ, ">Seq2C.frozen.txt" );
}

my $CNT = shift;
my %cnt;
open( CNT, $CNT );
my @cnt;
while(<CNT>) {
    chomp;
    next if ( /Undetermined/ );
    next if ( /Sample/ || /Total/ );
    my @a = split(/\t/);
    $cnt{$a[0]} = $a[1];
    push(@cnt, $a[1]);
}
close(CNT);
my %gender;
my @males = ();
my @females = ();
if ( $opt_G ) {
    open(GEN, $opt_G);
    while( <GEN> ) {
	my ($s, $g) = split;
	$gender{ $s } = $g =~ /^m/i ? "M" : ($g =~ /^f/i ? "F" : "U");
	if ( $gender{ $s } eq "M" ) {
	    push(@males, $s);
	} elsif ( $gender{ $s } eq "F" ) {
	    push(@females, $s);
	}
    }
    close( GEN );
}

my %polygene = ( "GSTM1" => 1, "GSTT1" => 1, GSTT2 => 1, CYP2D6 => 1, OPN1LW => 1, OPN1MW => 1, OPN1MW2 => 1, UGT2B17 => 1 );

my $stat = new Stat::Basic;
#my $meanreads = $stat->prctile(\@cnt, 50);
my $meanreads = $stat->median(\@cnt);
print FZ "MedianReads:\t$meanreads\n" if ( $opt_Z );
my %factor; # to adjust sequencing coverage
while(my ($k, $v) = each %cnt) {
    $factor{ $k } = $meanreads/$v;
    print FZ "SampleMedian:\t$k\t$factor{ $k }\t$v\n";
}
my %raw; # key: gene value: hash of (key: sample; value: raw depth)
my %norm1; # key: gene value: hash of (key: sample; value: normalized depth by sequencing distribution)
my %norm1b; # key: gene value: hash of (key: sample; value: normalized depth by gene)
my %norm2; # key: gene value: hash of (key: sample; value: normalized by gene median scaling log2)
my %norm3; # key: gene value: hash of (key: sample; value: normalized by sample median scaling log2)
my %norm_c;
my %samples;
my %data;
my %loc;
while( <> ) {
    chomp;
    next if ( /Whole-/ );
    next if ( /_CONTROL_/ );
    next if ( /^Sample/ );
    my ($sample, $gene, $chr, $s, $e, $desc, $len, $depth) = split(/\t/);
    next if ( $sample eq "Undetermined" );
    next if ( $gene =~ /^HLA-/ );
    next if ( $polygene{ $gene } );
    my $k = $opt_a ? join("\t", $gene, $chr, $s, $e, $len) : $gene;
    $loc{ $k }->{ chr } = $chr;
    $loc{ $gene }->{ start } = $s unless( $loc{ $gene }->{ start } && $loc{ $gene }->{ start } < $s );
    $loc{ $gene }->{ end } = $e unless( $loc{ $gene }->{ end } && $loc{ $gene }->{ end } > $e );
    $loc{ $gene }->{ len } += $len;
    $data{ $k }->{ $sample }->{ len } += $len;
    $data{ $k }->{ $sample }->{ cov } += $depth;
}

my @depth;
my %Adepth; # autosomes
my %Xdepth; # chrX
my %Ydepth; # chrY
while(my($k, $v) = each %data) {
    while( my($sample, $dv) = each %$v ) {
	$raw{ $k }->{ $sample } = $dv->{cov};
	$norm1{ $k }->{ $sample } = sprintf("%.2f", $raw{ $k }->{ $sample }*$factor{ $sample });
	$samples{ $sample } = 1;
	if ( $loc{$k}->{ chr } =~ /X/ ) {
	    push(@{$Xdepth{ $sample }}, $norm1{ $k }->{ $sample } );
	} elsif ( $loc{$k}->{ chr } =~ /Y/ ) {
	    push(@{$Ydepth{ $sample }}, $norm1{ $k }->{ $sample } );
	} else {
	    push(@depth, $norm1{ $k }->{ $sample } );
	    push(@{$Adepth{ $sample }}, $norm1{ $k }->{ $sample } );
	}
    }
}

my @samples = keys %samples;
# Predict gender from the coverage
if( %Xdepth && %Ydepth && (! $opt_G )) { # only do it if it's not specified and both X and Y have coverages
    open(GENR, ">gender_predicted.txt");
    print GENR join("\t", qw(Sample Gender X_median Y_25 A_median X/A_ratio)), "\n";
    foreach my $s (@samples) {
        my $xmed = $stat->median($Xdepth{ $s });
        my $amed = $stat->median($Adepth{ $s });
	print STDERR "$s $xmed $amed\n";
        my $xa = $xmed/$amed;
        my $y25 = $stat->prctile($Ydepth{ $s }, 25);
	$gender{ $s } = $y25 < $xmed * $YRATIO ? ($xa >= 0.7 ? "F" : "U") : "M";
	print GENR "$s\t$gender{ $s }\t$xmed\t$y25\t$amed\t$xa\n";
	if ( $gender{ $s } eq "M" ) {
	    push(@males, $s);
	} elsif ($gender{ $s } eq "F" ) {
	    push(@females, $s);
	}
    }
    close(GENR);
}
my $meddepth = $stat->median(\@depth);
@depth = (); # free memory
%Adepth = ();
%Xdepth = ();
%Ydepth = ();

# remove genes/amplicons that failed
my %bad;
my @gooddepth = ();
my $probes = 0; # number of genomic segments
while(my($k, $v) = each %data) {
    my @tmp = map { $norm1{ $k }->{ $_} } @samples;
    next if ( $loc{$k}->{chr} =~ /X/ || $loc{$k}->{chr} =~ /Y/ );
    my $kp80 = $stat->prctile(\@tmp, 80);
    if ( $kp80 < $meddepth*$FAILEDFACTOR ) {
        $bad{ $k } = 1;
    } else {
        push(@gooddepth, @tmp);
	$probes++;
    }
}
$meddepth = $stat->median(\@gooddepth); # re-adjust median depth using only those from good amplicons/genes
#$meddepth = $stat->prctile(\@gooddepth, 25); # re-adjust median depth using only those from good amplicons/genes
@gooddepth = (); # free memory

my %factor2;  # Gene/amplicon factor
my %rawmed;  # the raw median of coverage
while( my ($k, $v) = each %norm1) {
    next if ( $bad{ $k } );
    my @t = values %$v;
    if ( $loc{ $k }->{ chr } =~ /X/ ) {
        @t = map { $gender{ $_ } eq "F" ? $v->{ $_ } : $v->{ $_ } * 2; } @samples;
    } elsif (  $loc{ $k }->{ chr } =~ /Y/ ) {
        @t = map { $v->{ $_ } * 2; } @males;
    }
    $rawmed{ $k } = $stat->median(\@t);
    $factor2{ $k } = $rawmed{ $k } ? $meddepth/$rawmed{ $k } : 0;
}

while( my ($k, $v) = each %norm1) {
    next if ( $bad{ $k } );
    foreach my $s (@samples) {
	my $normdp = $opt_M ? sprintf("%.2f", $meddepth + ($v->{$s} - $rawmed{ $k }) * sqrt($factor2{ $k })) : sprintf("%.2f", $v->{$s} * $factor2{ $k } + 0.1);
	if ( $opt_M ) {
	    if ( $loc{ $k }->{ chr } =~ /X/ ) {
		$normdp = sprintf("%.2f", ($meddepth + (2*$v->{$s} - $rawmed{ $k }) * sqrt($factor2{ $k }))/2) unless ( $gender{ $s } eq "F" );
	    } elsif (  $loc{ $k }->{ chr } =~ /Y/ ) {
		# adjust for males only.  Female will leave as is
		$normdp = $gender{ $s } eq "M" ? sprintf("%.2f", ($meddepth + (2*$v->{$s} - $rawmed{ $k }) * sqrt($factor2{ $k }))/2) : $v->{$s};
	    }
	}
	if ( $normdp < 0.1 ) {
	    #print STDERR "Under: $s $k $meddepth + ($v->{$s} - $rawmed{ $k }) $factor2{ $k } $normdp\n";
	    $normdp = 0.1; 
	}
	$norm1b{ $k }->{ $s } = $normdp;
        $norm2{ $k }->{ $s } = sprintf("%.2f", log($normdp/$meddepth)/log(2));
        #$norm3{ $k }->{ $s } = sprintf("%.2f", log(($v->{$s} * $factor2{ $k }+0.1)/$samplemedian{ $s })/log(2));
    }
}

# Calculate the sample median after normalization
my %samplemode;
foreach my $s (@samples) {
    my %mode = ();
    while( my ($k, $v) = each %norm1b ) {
	next if ( $bad{ $k } ); # ignore failed genes/amplicons
	next if ( $loc{ $k }->{ chr } =~ /X/ || $loc{ $k }->{ chr } =~ /Y/ ); # exclude chrX and chrY
	my $lr = log($v->{ $s }/$meddepth)/log(2); # Would be centered around 0
	next if ( abs($lr) > 1.2 );
	my $seg = $probes >=1000 ? sprintf("%.2f", $lr) : sprintf("%.1f", $lr); # decrease the resolution if probes are small
	$mode{ $seg }->{ cnt }++;
	$mode{ $seg }->{ sum } += $lr;
        #push( @tmp, log($v->{ $s }/$meddeth)/log(2) ) unless( $loc{ $k }->{ chr } =~ /X/ || $loc{ $k }->{ chr } =~ /Y/ ); # exclude chrX and chrY
    }
    my @tmp = ();
    while( my ($lr, $v) = each %mode ) {
        push( @tmp, [$v->{ cnt }, $lr, $v->{ sum }] );
    }
    @tmp = sort { $b->[0] <=> $a->[0] } @tmp;
    print STDERR "$s\t@{ $tmp[0] }\t@{ $tmp[1] }\t@{ $tmp[2] }\n" if ( $opt_y );
    $samplemode{ $s } = $tmp[0]->[2]/$tmp[0]->[0] + log($meddepth)/log(2);
    #$samplemedian{ $s } = $stat->median( \@tmp );
}

while( my ($k, $v) = each %norm1b) {
    next if ( $bad{ $k } );
    foreach my $s (@samples) {
        $norm3{ $k }->{ $s } = sprintf("%.2f", log($v->{$s})/log(2) - $samplemode{ $s });
    }
}

my %factor_c;  # Gene/amplicon factor
if ( $opt_c ) {
    my @controls = split(/:/, $opt_c);
    my %controls = map { ($_, 1); } @controls;
    while( my ($k, $v) = each %norm1b) {
        next if ($bad{ $k });
	my @tcntl = map { $norm1b{ $k }->{ $_ } } @controls;
	my $cntl_ave = $stat->median( \@tcntl );
        while( my ($s, $d) = each %$v ) {
            $norm_c{ $k }->{ $s } = sprintf("%.3f", log($d/$cntl_ave)/log(2));
        }
    }

    # Find the new center for each sample
    foreach my $s (@samples) {
	if ( $controls{ $s } ) {
	    $factor_c{ $s } = 0;
	    next;
	}
        my %mode = ();
        while( my ($k, $v) = each %norm_c ) {
            next if ( $bad{ $k } ); # ignore failed genes/amplicons
	    next if ( $loc{ $k }->{ chr } =~ /X/ || $loc{ $k }->{ chr } =~ /Y/ ); # exclude chrX and chrY
	    next if ( abs($v->{$s}) > 1.2 );
	    my $lr = $probes >= 1000 ? sprintf("%.2f", $v->{$s}) : sprintf("%.1f", $v->{$s}); # decrease the resolution if probes are small
	    $mode{ $lr }->{ cnt }++;
	    $mode{ $lr }->{ sum } += $v->{$s};
	}
	my @tmp = ();
	while( my ($lr, $v) = each %mode ) {
	    push( @tmp, [$v->{ cnt }, $lr, $v->{ sum }] );
	}
	@tmp = sort { $b->[0] <=> $a->[0] } @tmp;
        #    push( @tmp, $v->{ $s } ) unless( $loc{ $k }->{ chr } =~ /X/ || $loc{ $k }->{ chr } =~ /Y/ );
        #$factor_c{ $s } = $stat->median( \@tmp );
	print STDERR "Cntrl: $s\t@{ $tmp[0] }\t@{ $tmp[1] }\t@{ $tmp[2] }\n" if ( $opt_y );
        $factor_c{ $s } = $tmp[0]->[2]/$tmp[0]->[0];
    }
}

while( my ($k, $v) = each %norm2) {
    next if ($bad{ $k });
    while( my ($s, $d) = each %$v ) {
	my $t = $opt_a ? $k : "$k\t$loc{$k}->{chr}\t$loc{$k}->{start}\t$loc{$k}->{end}\t$data{$k}->{$s}->{len}";
        my $str = join("\t", $s, $t, $raw{ $k }->{ $s }, $norm1{ $k }->{ $s }, $norm1b{ $k }->{ $s }, $d, $norm3{ $k }->{ $s }); #, $factor2{ $k }, $rawmed{ $k }, $meddepth );
	if ( $opt_c ) {
	    $str .= "\t" .  sprintf("%.3f", $norm_c{ $k }->{ $s } - $factor_c{ $s });
	}
	print "$str\n";
    }
}

close( FZ ) if ( $opt_Z );
exit(0);

sub USAGE {
print <<USAGE;
    Usage: $0 [-aH] [-c control] mapping_reads coverage.txt

    The $0 program will convert a coverage file to copy number profile.

    Arguments are:
    mapping_reads: Required.  A file containing # of mapped or sequenced reads for samples.  At least two columns.
                   First is the sample name, 2nd is the number of mapped or sequenced reads.
    coverage.txt:  The coverage output file from checkCov.pl script.  Can also take from standard in or more than
                   one file.

    Options are:

    -a Indicate this is amplicon or exon based calling.  By default, it'll aggregate at gene level.

    -M Indicate to adjust the MAD when transforming the distribution.  Default: no, or just simple linear function.
       If not sure, don't use this option.  It might have better performance when cohort size is over 30.

    -c sample(s)
       Specify the control sample(s), if aplicable.  Multiple controls are allowed, which are separated by ":"

    -F double
       The failed factor for individual amplicons.  If (the 80th percentile of an amplicon depth)/(the global median depth)
       is less than the argument, the amplicon is considered failed and won't be used in calculation.  Default: 0.2.
    
    -G Gender
       Take a file of gender information.  Two columns, first is sample name, second is either M or F.  If not provided,
       the program will try to guess.

    -Y chrYratio
       For gender testing, if chrY is designed.  Default: 0.15.  If chrY is carefully designed, such as Foundation's assay,
       default is good.  For exome, the number should be higher, such as 0.3.

    -Z Indicate to output the frozen_file and all parameters into file Seq2C.frozen.txt

    -z frozen_file

AUTHOR
       Written by Zhongwu Lai, AstraZeneca, Boston, USA

REPORTING BUGS
       Report bugs to zhongwu\@yahoo.com

COPYRIGHT
       This is free software: you are free to change and redistribute it.  There is NO WARRANTY, to the extent permitted by law.

USAGE
exit(0);
}
