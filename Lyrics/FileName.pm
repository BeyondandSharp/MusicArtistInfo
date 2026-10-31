package Plugins::MusicArtistInfo::Lyrics::FileName;

use strict;

# Builds the basename of a lyrics file from track metadata using LMS' own
# title formatter (Slim::Music::TitleFormatter).  The formatter can be
# injected for testing, which keeps this module free of LMS dependencies at
# load time.

my $MAX_LENGTH = 150;
my $FALLBACK   = 'lyrics';

my $default_formatter = sub {
	require Slim::Music::TitleFormatter;

	my ($trackOrMeta, $format) = @_;

	if ( ref $trackOrMeta eq 'HASH' ) {
		return Slim::Music::TitleFormatter::infoFormat(undef, $format, undef, $trackOrMeta);
	}

	return Slim::Music::TitleFormatter::infoFormat($trackOrMeta, $format);
};

sub basename {
	my ($class, $trackOrMeta, $format, $formatter) = @_;

	$format = 'FILE' if !defined $format || $format eq '';
	$formatter ||= $default_formatter;

	my $name = eval { $formatter->($trackOrMeta, $format) };
	$name = '' if !defined $name || $@;

	$name = _sanitize($name);

	return $name;
}

# Public for tests: returns the sanitized basename, without the .lrc suffix.
sub _sanitize {
	my ($name) = @_;

	$name = '' unless defined $name;

	# Reuse LMS' filename helper when available.  It takes care of path
	# separators and leading dots, but is not sufficient for Windows.
	my $cleanup = eval {
		require Slim::Utils::Misc;
		\&Slim::Utils::Misc::cleanupFilename;
	};
	$name = $cleanup->($name) if $cleanup;

	$name =~ s/\\n/ /g;
	$name =~ s/[\x00-\x1f]/ /g;
	$name =~ s/[<>:"\/\\|?*]//g;
	$name =~ s/\s+/ /g;
	$name =~ s/^[\s.]+//;
	$name =~ s/[\s.]+$//;

	# Windows does not like these names at all
	$name = "_$name" if $name =~ /^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)/i;

	if ( length($name) > $MAX_LENGTH ) {
		$name = substr($name, 0, $MAX_LENGTH);
		$name =~ s/[\s.]+$//;
	}

	$name = $FALLBACK if $name eq '' || $name =~ /^\.+$/;

	$name =~ s/\.lrc$//i;
	$name = $FALLBACK if $name eq '';

	return $name;
}

sub lyrics_filename {
	my ($class, $trackOrMeta, $format, $formatter) = @_;

	return $class->basename($trackOrMeta, $format, $formatter) . '.lrc';
}

1;
