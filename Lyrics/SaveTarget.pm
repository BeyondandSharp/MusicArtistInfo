package Plugins::MusicArtistInfo::Lyrics::SaveTarget;

use strict;

use Encode qw(FB_CROAK);
use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);

use Plugins::MusicArtistInfo::Lyrics::FileName;
use Plugins::MusicArtistInfo::Lyrics::Format;

sub build {
	my ($class, $track, $opts) = @_;

	$opts ||= {};

	return { error => 'Missing track' } unless $track;

	my $useFb2k = $opts->{use_fb2k} ? 1 : 0;
	$useFb2k = 0 unless Plugins::MusicArtistInfo::Lyrics::Format->available;

	my $pathFormat = defined $opts->{path_format} ? $opts->{path_format} : '';
	my $fileFormat = defined $opts->{file_format} ? $opts->{file_format} : '';

	my $audioPath = _audio_path($track);
	my $path = $audioPath ? dirname($audioPath) : '';
	my $filename;
	my $formatter = 'lms';

	if ( $useFb2k && $pathFormat ne '' ) {
		my $result = Plugins::MusicArtistInfo::Lyrics::Format->format_track($track, $pathFormat);
		if ( !$result->{error} && defined $result->{text} && $result->{text} ne '' ) {
			$path = $result->{text};
			$formatter = 'fb2k';
		}
	}

	if ( $useFb2k && $fileFormat ne '' ) {
		my $result = Plugins::MusicArtistInfo::Lyrics::Format->format_track($track, $fileFormat);
		if ( !$result->{error} && defined $result->{text} && $result->{text} ne '' ) {
			$filename = $result->{text};
		}
	}

	if ( !defined $filename || $filename eq '' ) {
		$filename = Plugins::MusicArtistInfo::Lyrics::FileName->lyrics_filename(
			$track,
			$opts->{lms_file_format} || 'FILE',
		);
		$filename =~ s/\.lrc$//i;
	}

	$filename = _utf8_text($filename);
	$filename = Plugins::MusicArtistInfo::Lyrics::FileName::_sanitize($filename);
	$filename .= '.lrc' unless $filename =~ /\.lrc$/i;

	$path = _clean_path($path);
	if ( !defined $path || $path eq '' ) {
		return { error => 'Could not determine save folder' };
	}

	return {
		path      => $path,
		filename  => $filename,
		full_path => catfile($path, $filename),
		formatter => $formatter,
	};
}

sub _audio_path {
	my $track = shift;

	my $url = eval { $track->url } || '';
	$url =~ s/^tmp:/file:/;
	return unless $url =~ m{^file://};

	require Slim::Utils::Misc;
	my $path = eval { Slim::Utils::Misc::pathFromFileURL($url) };
	return _utf8_text($path);
}

sub _clean_path {
	my $path = shift;
	return unless defined $path;

	$path =~ s/[\x00-\x1f]//g;
	$path =~ s{[\\/]+$}{};
	$path =~ s{^[\s]+}{};
	$path =~ s{[\s]+$}{};

	return if $path =~ m{(?:^|[\\/])\.\.(?:[\\/]|$)};
	return if $path =~ /^\.+$/;

	# A relative path would depend on the LMS process cwd; use the audio
	# folder fallback instead.
	return if $path !~ m{^(?:/|[\\/]{2}|[A-Za-z]:[\\/])};

	return $path;
}

sub _utf8_text {
	my $value = shift;
	return unless defined $value;
	return $value if utf8::is_utf8($value);
	my $decoded = eval { Encode::decode('UTF-8', $value, FB_CROAK) };
	return defined $decoded && !$@ ? $decoded : $value;
}

1;
