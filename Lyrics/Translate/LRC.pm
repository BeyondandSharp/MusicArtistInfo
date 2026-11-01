package Plugins::MusicArtistInfo::Lyrics::Translate::LRC;

use strict;

# Pure LRC text helpers used by the lyrics translation pipeline.  Everything
# in here is side-effect free: strings in, strings (or simple data
# structures) out.  No files, no preferences, no network, no LMS modules, so
# it can be exercised without a running server.
#
# The behaviour is a faithful port of the reference implementation
# (lyrics_processor.py): same regexes, same gating counts, same rebuild
# layout (marker line + verbatim original block + translated block).

use Exporter 'import';
use JSON::PP ();
use Unicode::Normalize qw(NFKC);

our @EXPORT_OK = qw(
	normalize_newlines
	first_nonempty_line
	count_timestamps
	strip_inline_angle_time
	build_detect_text
	split_prefix
	parse_lrc
	is_pure_punctuation
	unique_lines
	clean_translation
	parse_llm_json
	norm_key
	match_translations
	rebuild_lrc
);

# [00:00.00] is the usual "title" timestamp and is deliberately not counted.
# Minutes accept 1-3 digits, the fraction is optional and may use . or :.
my $TIMESTAMP_RE = qr/\[(?!00:00\.00)\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]/;
# All consecutive [...] groups at the very beginning of a line.
my $LEADING_GROUPS_RE = qr/^((?:\[[^\]]*\])+)/;
# [...] fragments anywhere inside a line (non-greedy, single line).
my $INLINE_BRACKET_RE = qr/\[.*?\]/;
# Karaoke per-character timestamps such as <00:08.41>.
my $INLINE_ANGLE_TIME_RE = qr/<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>/;

# The three Chinese reply prefixes (fullwidth colon, colon+space, bare colon)
# are written as \x{...} escapes so this source file stays ASCII.
# Order matters: the longer forms are tried before the bare colon form.
my @ZH_PREFIXES = (
	"\x{8BD1}\x{6587}\x{FF1A}",
	"\x{8BD1}\x{6587}: ",
	"\x{8BD1}\x{6587}:",
);

sub _trim {
	my $text = defined $_[0] ? $_[0] : '';
	$text =~ s/^\s+//;
	$text =~ s/\s+$//;
	return $text;
}

# Returns (normalized text using "\n", the dominant EOL, trailing-newline flag).
sub normalize_newlines {
	my $text = defined $_[0] ? $_[0] : '';

	my $eol = "\n";
	$eol = "\r\n" if $text =~ /\r\n/;
	$eol = "\r" if $eol eq "\n" && $text =~ /\r/;

	my $norm = $text;
	$norm =~ s/\r\n/\n/g;
	$norm =~ s/\r/\n/g;

	return ($norm, $eol, $norm =~ /\n\z/ ? 1 : 0);
}

sub first_nonempty_line {
	my $text = defined $_[0] ? $_[0] : '';

	foreach my $line (split /\n/, $text, -1) {
		my $trimmed = _trim($line);
		return $trimmed if $trimmed ne '';
	}

	return '';
}

# Returns (number of timestamps, number of repeated timestamps).
sub count_timestamps {
	my $text = defined $_[0] ? $_[0] : '';

	my @matches = ($text =~ /$TIMESTAMP_RE/g);
	my %seen;
	$seen{$_} = 1 for @matches;

	return (scalar @matches, scalar(@matches) - scalar(keys %seen));
}

sub strip_inline_angle_time {
	my $text = defined $_[0] ? $_[0] : '';
	$text =~ s/$INLINE_ANGLE_TIME_RE//g;
	return $text;
}

# Text handed to language detection: per line drop [...] fragments and
# per-character timestamps, drop empty lines, join with ",".
sub build_detect_text {
	my ($norm) = normalize_newlines($_[0]);

	my @parts;
	foreach my $line (split /\n/, $norm, -1) {
		$line =~ s/$INLINE_BRACKET_RE//g;
		$line = strip_inline_angle_time($line);
		$line = _trim($line);
		push @parts, $line if $line ne '';
	}

	return join(',', @parts);
}

# Returns (leading [...] groups, whitespace-collapsed body without karaoke tags).
sub split_prefix {
	my $line = defined $_[0] ? $_[0] : '';

	my $prefix = ($line =~ /$LEADING_GROUPS_RE/) ? $1 : '';
	my $rest = substr($line, length $prefix);

	$rest = strip_inline_angle_time($rest);
	$rest =~ s/\s+/ /g;
	$rest = _trim($rest);

	return ($prefix, $rest);
}

sub parse_lrc {
	my ($norm, $eol, $trailing) = normalize_newlines($_[0]);

	my (@raw_lines, @prefixes, @texts);
	foreach my $line (split /\n/, $norm, -1) {
		# Blank lines are dropped entirely; they are not re-emitted on rebuild.
		next unless $line =~ /\S/;

		# The original block is re-emitted byte for byte, so keep the raw line
		# (including trailing whitespace) next to its parsed prefix/text.
		my ($prefix, $text) = split_prefix($line);
		push @raw_lines, $line;
		push @prefixes, $prefix;
		push @texts, $text;
	}

	return {
		raw_lines        => \@raw_lines,
		prefixes         => \@prefixes,
		texts            => \@texts,
		eol              => $eol,
		trailing_newline => $trailing,
	};
}

# Equivalent of JS /\p{P}/gu -- punctuation only; symbols such as the music
# note (category So) are kept.
sub is_pure_punctuation {
	my $text = defined $_[0] ? $_[0] : '';
	return $text =~ /\A\p{P}*\z/ ? 1 : 0;
}

# Drop blank lines, duplicates (first occurrence wins) and pure punctuation.
sub unique_lines {
	my ($texts) = @_;

	my (@unique, %seen);
	foreach my $text (@{ $texts || [] }) {
		$text = '' unless defined $text;
		next unless $text =~ /\S/;
		next if $seen{$text}++;
		next if is_pure_punctuation($text);
		push @unique, $text;
	}

	return \@unique;
}

# Strip Chinese "translated:" reply prefixes greedily (keep the text after the last one).
sub clean_translation {
	my $text = defined $_[0] ? $_[0] : '';
	return '' if ref $text;

	my $out = $text;
	foreach my $prefix (@ZH_PREFIXES) {
		$out =~ s/.*\Q$prefix\E//s;
	}

	return _trim($out);
}

sub _decode_json {
	my ($text) = @_;

	my $value = eval { JSON::PP->new->decode($text) };
	return $@ ? undef : $value;
}

# Extract the outermost balanced {...} and decode it; string/escape aware, so
# braces inside JSON strings do not confuse the scan.
sub _balanced_json_object {
	my $text = defined $_[0] ? $_[0] : '';

	my $start = index($text, '{');
	return undef if $start < 0;

	my $depth = 0;
	my $in_string = 0;
	my $escape = 0;
	my $length = length $text;

	for (my $i = $start; $i < $length; $i++) {
		my $char = substr($text, $i, 1);

		if ($in_string) {
			if ($escape) {
				$escape = 0;
			}
			elsif ($char eq '\\') {
				$escape = 1;
			}
			elsif ($char eq '"') {
				$in_string = 0;
			}
			next;
		}

		if ($char eq '"') {
			$in_string = 1;
		}
		elsif ($char eq '{') {
			$depth++;
		}
		elsif ($char eq '}') {
			$depth--;
			next if $depth > 0;
			return undef unless $depth == 0;
			return _decode_json(substr($text, $start, $i - $start + 1));
		}
	}

	return undef;
}

# Parse an LLM reply: strip ``` fences, try a plain JSON decode, then fall
# back to extracting the outermost balanced {...} from surrounding prose.
sub parse_llm_json {
	my $content = defined $_[0] ? $_[0] : '';
	return undef unless $content =~ /\S/;

	my $text = _trim($content);
	if ($text =~ /^```/) {
		$text =~ s/^```[A-Za-z0-9_-]*\s*//;
		$text =~ s/\s*```$//;
		$text = _trim($text);
	}

	my $decoded = _decode_json($text);
	return $decoded if defined $decoded;

	return _balanced_json_object($text);
}

# NFKC + collapse whitespace + trim, used for fuzzy key matching.
sub norm_key {
	my $text = defined $_[0] ? $_[0] : '';
	my $norm = NFKC($text);
	$norm =~ s/\s+/ /g;
	return _trim($norm);
}

# Align an LLM payload to the requested lines: exact key, then
# NFKC/whitespace-normalized key, then its lowercase form; an equal-length
# array is matched positionally.  Unmatched lines map to undef.
sub match_translations {
	my ($lines, $payload) = @_;
	$lines ||= [];

	my %result = map { $_ => undef } @$lines;
	return \%result unless defined $payload;

	if (ref $payload eq 'ARRAY') {
		if (scalar(@$payload) == scalar(@$lines)) {
			for (my $i = 0; $i < scalar @$lines; $i++) {
				my $value = $payload->[$i];
				next unless defined $value && !ref $value;
				$result{ $lines->[$i] } = $value;
			}
		}
		return \%result;
	}

	return \%result unless ref $payload eq 'HASH';

	my %exact;
	foreach my $key (keys %$payload) {
		my $value = $payload->{$key};
		next unless defined $value && !ref $value;
		$exact{$key} = $value;
	}

	my %fuzzy;
	foreach my $key (sort keys %exact) {
		my $norm = norm_key($key);
		$fuzzy{$norm} = $exact{$key} unless exists $fuzzy{$norm};
		my $lower = lc $norm;
		$fuzzy{$lower} = $exact{$key} unless exists $fuzzy{$lower};
	}

	foreach my $line (@$lines) {
		if (exists $exact{$line}) {
			$result{$line} = $exact{$line};
			next;
		}

		my $norm = norm_key($line);
		my $hit;
		if (exists $fuzzy{$norm}) {
			$hit = $fuzzy{$norm};
		}
		elsif (exists $fuzzy{ lc $norm }) {
			$hit = $fuzzy{ lc $norm };
		}
		$result{$line} = $hit if defined $hit;
	}

	return \%result;
}

# Build the bilingual file: optional marker line, verbatim original block,
# translated block.  Returns ($body, {translated, missing, dropped}).
sub rebuild_lrc {
	my ($parsed, $translations, %opts) = @_;
	$parsed ||= {};
	$translations ||= {};

	my $marker      = defined $opts{marker}      ? $opts{marker}      : '';
	my $multiline   = lc(defined $opts{multiline}   ? $opts{multiline}   : 'drop');
	my $failed_line = lc(defined $opts{failed_line} ? $opts{failed_line} : 'original');

	my $stats = { translated => 0, missing => 0, dropped => 0 };
	my @translated_block;

	my $prefixes = $parsed->{prefixes} || [];
	my $texts    = $parsed->{texts}    || [];

	for (my $i = 0; $i < scalar @$texts; $i++) {
		my $text = defined $texts->[$i] ? $texts->[$i] : '';
		next if $text eq '';

		my $hit = $translations->{$text};
		if (!defined $hit) {
			$stats->{missing}++;
			next if $failed_line eq 'omit';
			$hit = $text;
		}

		if ($hit =~ /[\r\n]/) {
			if ($multiline eq 'drop') {
				$stats->{dropped}++;
				next;
			}
			$hit =~ s/\s*\n\s*/ /g;
			$hit = _trim($hit);
		}

		if ($hit eq '') {
			$stats->{dropped}++;
			next;
		}

		my $prefix = defined $prefixes->[$i] ? $prefixes->[$i] : '';
		push @translated_block, $prefix . $hit;
	}

	$stats->{translated} =
		scalar(grep { defined $_ && !ref $_ && $_ ne '' } values %$translations);

	my $original_block = join("\n", @{ $parsed->{raw_lines} || [] });

	my $body = ( $marker ne '' ? $marker . "\n" : '' )
		. $original_block . "\n" . join("\n", @translated_block);
	$body .= "\n" if $parsed->{trailing_newline};

	my $eol = defined $parsed->{eol} ? $parsed->{eol} : "\n";
	$body =~ s/\n/$eol/g if $eol ne "\n";

	return ($body, $stats);
}

1;
