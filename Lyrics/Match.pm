package Plugins::MusicArtistInfo::Lyrics::Match;

use strict;

# Small fuzzy score used by automatic lyric selection.  It deliberately
# favours exact/contained title and artist matches over unrelated results.

sub score {
	my ($class, $candidate, $args) = @_;

	return 0 unless ref $candidate eq 'HASH' && ref $args eq 'HASH';

	my $ct = _norm($candidate->{title} || $candidate->{song});
	my $ca = _norm($candidate->{artist});
	my $at = _norm($args->{title});
	my $aa = _norm($args->{artist});

	my $score = 0;
	$score += _compare($ct, $at) ? 60 : 0;
	$score += _compare($ca, $aa) ? 35 : 0;

	if ( $ct ne '' && $at ne '' ) {
		$score += 5 if $ct eq $at;
	}
	if ( $ca ne '' && $aa ne '' ) {
		$score += 5 if $ca eq $aa;
	}

	return $score > 100 ? 100 : $score;
}

sub best {
	my ($class, $candidates, $args, $opts) = @_;

	$opts ||= {};
	my $min = defined $opts->{min} ? $opts->{min} : 0;
	my $preferSynced = $opts->{prefer_synced};

	my @valid;
	foreach my $candidate (@{ $candidates || [] }) {
		next unless ref $candidate eq 'HASH' && defined $candidate->{lyrics} && $candidate->{lyrics} =~ /\S/;
		my $score = $class->score($candidate, $args);
		next if $score < $min;
		$candidate->{_score} = $score;
		push @valid, $candidate;
	}

	return unless @valid;

	if ($preferSynced) {
		my @synced = grep { $_->{synced} } @valid;
		@valid = @synced if @synced;
	}

	@valid = sort {
		($b->{_score} || 0) <=> ($a->{_score} || 0)
			|| ($b->{synced} ? 1 : 0) <=> ($a->{synced} ? 1 : 0)
			|| ($a->{priority} || 0) <=> ($b->{priority} || 0)
	} @valid;

	delete $_->{_score} for @valid;

	return $valid[0];
}

sub _norm {
	my $text = defined $_[0] ? lc $_[0] : '';
	$text =~ s/\s+//g;
	$text =~ s/[^\p{L}\p{N}]//g;
	return $text;
}

sub _compare {
	my ($a, $b) = @_;
	return 0 if $a eq '' || $b eq '';
	return 1 if index($a, $b) >= 0 || index($b, $a) >= 0;

	my %tokensA = map { $_ => 1 } grep { length > 1 } split //, $a;
	my %tokensB = map { $_ => 1 } grep { length > 1 } split //, $b;
	my $common = grep { $tokensB{$_} } keys %tokensA;
	return $common > 0 ? 1 : 0;
}

1;
