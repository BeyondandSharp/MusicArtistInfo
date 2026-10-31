package Plugins::MusicArtistInfo::Text;

use strict;

use Encode qw(FB_CROAK FB_DEFAULT LEAVE_SRC);
use Encode ();

# Best-effort text decoding for local files.  Binary data and JSON caches must
# not be passed through this module.

my @BOMS = (
	[ "\xFF\xFE\x00\x00", 'UTF-32LE' ],
	[ "\x00\x00\xFE\xFF", 'UTF-32BE' ],
	[ "\xEF\xBB\xBF",     'UTF-8'    ],
	[ "\xFF\xFE",         'UTF-16LE' ],
	[ "\xFE\xFF",         'UTF-16BE' ],
);

my @LEGACY_ENCODINGS = qw(
	GB18030
	CP936
	Big5-HKSCS
	CP932
	EUC-JP
	CP949
	EUC-KR
	CP1251
	CP1252
	ISO-8859-1
);

sub read_file {
	my ($class, $path, $opts) = @_;

	return unless defined $path && -r $path;

	my $fh;
	unless ( open($fh, '<:raw', $path) ) {
		return;
	}

	local $/;
	my $bytes = <$fh>;
	close $fh;

	return $class->decode($bytes, $opts);
}

sub ensure_text {
	my ($class, $content, $opts) = @_;

	return '' unless defined $content;

	if ( utf8::is_utf8($content) ) {
		return $class->strip_bom($content);
	}

	return $class->decode($content, $opts);
}

sub strip_bom {
	my ($class, $text) = @_;

	return '' unless defined $text;

	if ( utf8::is_utf8($text) ) {
		$text =~ s/^\x{FEFF}+//;
		return $text;
	}

	$text =~ s/^\xEF\xBB\xBF//;

	return $text;
}

sub decode {
	my ($class, $bytes, $opts) = @_;

	$opts ||= {};

	return '' unless defined $bytes;
	return '' if $bytes eq '';

	if ( utf8::is_utf8($bytes) ) {
		return $class->strip_bom($bytes);
	}

	my $forced = $opts->{encoding};
	if ( defined $forced && $forced ne '' ) {
		my $decoded = eval { Encode::decode($forced, $bytes, (FB_CROAK | LEAVE_SRC)) };
		return $class->strip_bom($decoded) if defined $decoded && !$@;
	}

	foreach my $bom (@BOMS) {
		my ($marker, $encoding) = @$bom;
		next unless length($bytes) >= length($marker);
		next unless substr($bytes, 0, length($marker)) eq $marker;

		my $payload = substr($bytes, length($marker));
		my $decoded = eval { Encode::decode($encoding, $payload, (FB_CROAK | LEAVE_SRC)) };

		if ( defined $decoded && !$@ ) {
			return $class->strip_bom($decoded);
		}

		# A BOM followed by invalid data: fall through and let the detectors
		# try the remaining content without the misleading prefix.
		$bytes = $payload;
		last;
	}

	# UTF-16/32 text consisting mostly of ASCII bytes can look like valid
	# UTF-8 (the NUL bytes are valid too), so check the NUL pattern first.
	my $utf16 = $class->_decode_without_bom_utf16($bytes, $opts);
	return $class->strip_bom($utf16) if defined $utf16;

	my $utf8 = eval { Encode::decode('UTF-8', $bytes, (FB_CROAK | LEAVE_SRC)) };
	return $class->strip_bom($utf8) if defined $utf8 && !$@;

	my $detected = $class->_decode_detected($bytes, $opts);
	return $class->strip_bom($detected) if defined $detected;

	my $legacy = $class->_decode_legacy($bytes, $opts);
	return $class->strip_bom($legacy) if defined $legacy;

	my $fallback = eval { Encode::decode('CP1252', $bytes, (FB_DEFAULT | LEAVE_SRC)) };
	$fallback = eval { Encode::decode('ISO-8859-1', $bytes, (FB_DEFAULT | LEAVE_SRC)) }
		unless defined $fallback;
	$fallback = $bytes unless defined $fallback;

	return $class->strip_bom($fallback);
}

sub _decode_detected {
	my ($class, $bytes, $opts) = @_;

	return unless eval { require Encode::Detect::Detector; 1 };

	my $charset = eval { Encode::Detect::Detector::detect($bytes) };
	return unless defined $charset && $charset ne '' && $charset !~ /^binary$/i;

	my $encoding = eval { Encode::find_encoding($charset) };
	return unless $encoding;

	my $decoded = eval { $encoding->decode($bytes, (FB_CROAK | LEAVE_SRC)) };
	return unless defined $decoded && !$@;
	return if $class->_score_text($decoded, $opts) < 0;

	return $decoded;
}

sub _decode_without_bom_utf16 {
	my ($class, $bytes, $opts) = @_;

	my $length = length($bytes);
	return unless $length >= 4;

	my $nuls = ($bytes =~ tr/\x00//);
	return unless $nuls >= $length * 0.2;

	my ($evenNuls, $oddNuls) = (0, 0);
	my @mod4 = (0, 0, 0, 0);

	for (my $i = 0; $i < $length; $i++) {
		next unless substr($bytes, $i, 1) eq "\x00";
		$i % 2 ? $oddNuls++ : $evenNuls++;
		$mod4[$i % 4]++;
	}

	my @candidates;

	# UTF-32 without BOM is much rarer, but has a distinctive three-of-four
	# NUL pattern.  Check it before falling back to UTF-16.
	if ( $nuls >= $length * 0.6 && $length % 4 == 0 ) {
		if ( $mod4[1] && $mod4[2] && $mod4[3] && !$mod4[0] ) {
			push @candidates, 'UTF-32LE';
		}
		elsif ( $mod4[0] && $mod4[1] && $mod4[2] && !$mod4[3] ) {
			push @candidates, 'UTF-32BE';
		}
	}

	# For UTF-16, the NUL bytes indicate byte order: LE text has NULs at odd
	# offsets, BE text at even offsets.
	push @candidates, $oddNuls >= $evenNuls ? 'UTF-16LE' : 'UTF-16BE';

	foreach my $encoding (@candidates) {
		my $decoded = eval { Encode::decode($encoding, $bytes, (FB_CROAK | LEAVE_SRC)) };
		next unless defined $decoded && !$@;

		my $score = $class->_score_text($decoded, $opts);
		return $decoded if $score >= 0;
	}

	return;
}

sub _decode_legacy {
	my ($class, $bytes, $opts) = @_;

	my ($best, $bestScore);

	foreach my $encoding (@LEGACY_ENCODINGS) {
		my $decoded = eval { Encode::decode($encoding, $bytes, (FB_CROAK | LEAVE_SRC)) };
		next unless defined $decoded && !$@;

		my $score = $class->_score_text($decoded, $opts);
		next if $score < 0;

		if ( !defined $bestScore || $score > $bestScore ) {
			$best = $decoded;
			$bestScore = $score;
		}
	}

	return $best;
}

sub _score_text {
	my ($class, $text, $opts) = @_;

	return -1 unless defined $text;
	return -1 if $text =~ /\x{FFFD}/;
	return -1 if $text =~ /[\x00-\x08\x0B\x0C\x0E-\x1F]/;

	my $han     = () = $text =~ /\p{Han}/g;
	my $kana    = () = $text =~ /[\p{Hiragana}\p{Katakana}]/g;
	my $hangul  = () = $text =~ /\p{Hangul}/g;
	my $cyrillic = () = $text =~ /\p{Cyrillic}/g;
	my $latin   = () = $text =~ /\p{Latin}/g;

	my $hint = $class->_hint_scripts($opts);
	my $score = $han * 3 + $kana * 3 + $hangul * 3 + $cyrillic * 3 + $latin;

	if ( $hint->{han} ) {
		$score += $han * 8;
	}
	if ( $hint->{kana} ) {
		$score += $kana * 8;
	}
	if ( $hint->{hangul} ) {
		$score += $hangul * 8;
	}
	if ( $hint->{cyrillic} ) {
		$score += $cyrillic * 8;
	}
	if ( $hint->{latin} || $hint->{cyrillic} ) {
		$score += $latin * 2;
	}

	# Penalize scripts which contradict the metadata hints.  This is what
	# disambiguates CP1251/CP1252 and CJK legacy encodings when the optional
	# Encode::Detect module is not available.  Without hints, prefer the
	# candidate with the most script characters instead.
	if ( $hint->{any} ) {
		$score -= $han * 4      if !$hint->{han} && $han;
		$score -= $kana * 4     if !$hint->{kana} && $kana;
		$score -= $hangul * 4   if !$hint->{hangul} && $hangul;
		$score -= $cyrillic * 4 if !$hint->{cyrillic} && $cyrillic;
	}

	return $score;
}

sub _hint_scripts {
	my ($class, $opts) = @_;

	my $text = join ' ', map { defined $_ ? $_ : '' } @{ $opts->{hints} || [] };
	$text = $class->ensure_text($text, {}) unless utf8::is_utf8($text);

	return {
		han      => $text =~ /\p{Han}/ ? 1 : 0,
		kana     => $text =~ /[\p{Hiragana}\p{Katakana}]/ ? 1 : 0,
		hangul   => $text =~ /\p{Hangul}/ ? 1 : 0,
		cyrillic => $text =~ /\p{Cyrillic}/ ? 1 : 0,
		latin    => $text =~ /\p{Latin}/ ? 1 : 0,
		any      => $text =~ /[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\p{Cyrillic}\p{Latin}]/ ? 1 : 0,
	};
}

1;
