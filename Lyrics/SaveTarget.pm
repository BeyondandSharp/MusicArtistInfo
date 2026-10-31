package Plugins::MusicArtistInfo::Lyrics::SaveTarget;

use strict;

use Encode qw(FB_CROAK);
use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);

use Plugins::MusicArtistInfo::Lyrics::FileName;
use Plugins::MusicArtistInfo::Lyrics::Format;
use Plugins::MusicArtistInfo::Lyrics::TemplateDefaults;

sub build {
	my ($class, $track, $opts) = @_;

	$opts ||= {};

	return { error => 'Missing track' } unless $track;

	my $language = $opts->{template_language}
		|| $opts->{use_fb2k} && 'fb2k'
		|| Plugins::MusicArtistInfo::Lyrics::Format->language;
	$language = 'lms' unless $language =~ /^(?:lms|fb2k|textxslate)$/;
	$language = 'lms' unless Plugins::MusicArtistInfo::Lyrics::Format->available_for($language);

	my $defaults = Plugins::MusicArtistInfo::Lyrics::TemplateDefaults->defaults_for($language);
	my $pathFormat = defined $opts->{path_format} ? $opts->{path_format} : '';
	my $fileFormat = defined $opts->{file_format} ? $opts->{file_format} : '';
	$pathFormat = $defaults->{path_format} if $language ne 'lms' && $pathFormat eq '';
	$fileFormat = $defaults->{file_format} if $language ne 'lms' && $fileFormat eq '';
	if ( $language eq 'textxslate' ) {
		$pathFormat = '<: $directory :>' if $pathFormat eq '$directory_path(%path%)'
			|| ( $pathFormat =~ /%[^%]+%/ && $pathFormat !~ /<:/ );
		$fileFormat = $defaults->{file_format}
			if $fileFormat eq '%artist% - %title%'
			|| ( $fileFormat =~ /%[^%]+%|\$[A-Za-z_]/ && $fileFormat !~ /<:/ );
	}
	elsif ( $language eq 'fb2k' ) {
		$pathFormat = $defaults->{path_format} if $pathFormat =~ /<:/;
		$fileFormat = $defaults->{file_format} if $fileFormat =~ /<:/;
	}

	my $audioPath = _audio_path($track);
	my $path = $audioPath ? dirname($audioPath) : '';
	my $filename;
	my $formatter = 'lms';

	if ( $language ne 'lms' && $pathFormat ne '' ) {
		my $result = Plugins::MusicArtistInfo::Lyrics::Format->format_track($track, $pathFormat, $language);
		if ( !$result->{error} && defined $result->{text} && $result->{text} ne '' ) {
			$path = $result->{text};
			$formatter = $language;
		}
	}

	if ( $language ne 'lms' && $fileFormat ne '' ) {
		my $result = Plugins::MusicArtistInfo::Lyrics::Format->format_track($track, $fileFormat, $language);
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
