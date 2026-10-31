package Plugins::MusicArtistInfo::Lyrics::Candidates;

use strict;

use Digest::MD5 qw(md5_hex);

# Pure helpers for the lyrics chooser.  No LMS dependencies.

my $MAX_CANDIDATES = 50;
my $MAX_LYRICS_LENGTH = 250_000;

sub normalize {
	my ($class, $candidate, $source) = @_;

	return unless ref $candidate eq 'HASH';

	return if $candidate->{instrumental};

	my $lyrics = $candidate->{lyrics};
	$lyrics = $candidate->{lyricText} if !defined $lyrics;

	return unless defined $lyrics && $lyrics =~ /\S/;

	$lyrics =~ s/^\x{feff}//;

	# A source returned a raw format (e.g. QRC/YRC JSON) but no matching
	# parser was available.  Do not present that as lyrics.
	return if $candidate->{fileType} && !$candidate->{parsed} && $lyrics =~ /^\s*\{/;

	$lyrics = substr($lyrics, 0, $MAX_LYRICS_LENGTH);

	my $synced = $lyrics =~ /\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]/ ? 1 : 0;

	my @lines = grep { /\S/ } split /\r?\n/, $lyrics;
	my $preview = join "\n", @lines[0 .. ($#lines > 2 ? 2 : $#lines)];

	return {
		source  => $source || $candidate->{source} || '',
		title   => $candidate->{title}   || '',
		artist  => $candidate->{artist}  || '',
		album   => $candidate->{album}   || '',
		lyrics  => $lyrics,
		preview => $preview,
		synced  => $synced,
		location => $candidate->{location} || '',
	};
}

sub dedupe {
	my ($class, $candidates) = @_;

	my %seen;
	my @result;

	foreach my $candidate (@$candidates) {
		next unless ref $candidate eq 'HASH';

		my $keyText = join "\x1f",
			lc($candidate->{artist} || ''),
			lc($candidate->{title}  || ''),
			$candidate->{lyrics} || '';
		utf8::encode($keyText);
		my $key = md5_hex($keyText);

		next if $seen{$key}++;

		push @result, $candidate;
	}

	return \@result;
}

sub finalize {
	my ($class, $candidates) = @_;

	my $result = $class->dedupe($candidates || []);

	my $order = 0;
	foreach my $candidate (@$result) {
		$candidate->{_order} = $order++;
	}

	@$result = sort {
		($a->{priority} || 0) <=> ($b->{priority} || 0)
			|| ($a->{_order} || 0) <=> ($b->{_order} || 0)
	} @$result;

	$result = [ @$result[0 .. $MAX_CANDIDATES - 1] ]
		if @$result > $MAX_CANDIDATES;

	my $index = 0;
	foreach my $candidate (@$result) {
		$candidate->{index} = $index++;
		delete $candidate->{_order};
	}

	return $result;
}

sub best {
	my ($class, $candidates) = @_;

	return unless ref $candidates eq 'ARRAY' && @$candidates;

	my @valid = grep { defined $_->{lyrics} && $_->{lyrics} =~ /\S/ } @$candidates;
	return unless @valid;

	my @synced = grep { $_->{synced} } @valid;

	return $synced[0] if @synced;

	return $valid[0];
}

sub max_candidates { $MAX_CANDIDATES }

1;
