package Plugins::MusicArtistInfo::LyricsSettings;

use strict;
use base qw(Slim::Web::Settings);

use Encode qw(FB_CROAK);
use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);

use JSON::PP ();

use Slim::Utils::Prefs;

use Plugins::MusicArtistInfo::Lyrics::Format;
use Plugins::MusicArtistInfo::Lyrics::Scripts;
use Plugins::MusicArtistInfo::Lyrics::MaterialSkin;
use Plugins::MusicArtistInfo::TrackInfo;

my $prefs = preferences('plugin.musicartistinfo');

sub name {
	return 'PLUGIN_MUSICARTISTINFO_LYRICS_OPTIONS';
}

sub page {
	return 'plugins/MusicArtistInfo/lyrics-settings.html';
}

sub prefs {
	my @prefs = ($prefs, qw(
		customLyricsSourcesFolder
		saveLyricsWithSong overwriteLyricsWithSong lyricsFileNameFormat
		integrateMaterialSkin
		templateLanguage lyricsSavePathFormat lyricsSaveFileNameFormat lyricsSaveBom lyricsSaveEncoding
		lyricsSaveMode lyricsSaveSeconds lyricsSaveRatio lyricsSaveSyncOnly lyricsSaveApplyProcessing
		autoSearchLyrics lyricsMinMatch lyricsStopAfterFirst lyricsStopExternalOnLocal
		lyricsPreferSynced lyricsResultMode
		lyricsCustomSearchFields lyricsSearchTitleFormat lyricsSearchArtistFormat
		lyricsSourceOrder lyricsSourceDisabled
		lyricsSearchScript lyricsSearchScriptPath lyricsProcessingScript lyricsProcessingScriptPath
	));

	return @prefs;
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup) = @_;

	my $fb2kAvailable = Plugins::MusicArtistInfo::Lyrics::Format->available;
	my $xslateAvailable = Plugins::MusicArtistInfo::Lyrics::Format->textxslate_available;
	my $language = $prefs->get('templateLanguage') || 'lms';
	$language = 'lms' if $language eq 'fb2k' && !$fb2kAvailable;
	$language = 'lms' if $language eq 'textxslate' && !$xslateAvailable;
	$paramRef->{pref_templateLanguage} = $language;

	# Fill in defaults for array settings and make sure malformed JSON
	# cannot be persisted.
	foreach my $key (qw(lyricsSourceOrder lyricsSourceDisabled)) {
		my $value = $paramRef->{"pref_$key"};
		$value = $prefs->get($key) if !defined $value;
		$value = '[]' if !defined $value || $value eq '';
		my $decoded = eval { JSON::PP->new->decode($value) };
		$value = '[]' unless ref $decoded eq 'ARRAY';
		$paramRef->{"pref_$key"} = $value;
	}

	$paramRef->{fb2kFormatAvailable} = $fb2kAvailable;
	$paramRef->{textxslateFormatAvailable} = $xslateAvailable;
	$paramRef->{templateLanguage} = $language;
	$paramRef->{hanConvertAvailable} = eval { require Plugins::MusicArtistInfo::Lyrics::HanConvert; Plugins::MusicArtistInfo::Lyrics::HanConvert->available } ? 1 : 0;
	$paramRef->{lyricsSourceOptions} = Plugins::MusicArtistInfo::TrackInfo->lyrics_source_options;
	$paramRef->{lyricsFolder} = $prefs->get('lyricsFolder') || '';
	$paramRef->{lyricsSourceOrder} = $prefs->get('lyricsSourceOrder') || '[]';
	$paramRef->{lyricsSourceDisabled} = $prefs->get('lyricsSourceDisabled') || '[]';
	$paramRef->{lyricsSearchFilters} = $prefs->get('lyricsSearchFilters') || '[]';
	$paramRef->{lyricsSearchScript} = $prefs->get('lyricsSearchScript') || Plugins::MusicArtistInfo::Lyrics::Scripts->default_search_script;
	$paramRef->{lyricsProcessingScript} = $prefs->get('lyricsProcessingScript') || Plugins::MusicArtistInfo::Lyrics::Scripts->default_processing_script;
	my $searchFile = _read_script_file($prefs->get('lyricsSearchScriptPath'));
	$paramRef->{lyricsSearchScript} = $searchFile if defined $searchFile;
	my $processingFile = _read_script_file($prefs->get('lyricsProcessingScriptPath'));
	$paramRef->{lyricsProcessingScript} = $processingFile if defined $processingFile;
	$paramRef->{lyricsFieldProcessing} = $prefs->get('lyricsFieldProcessing') || '[]';
	$paramRef->{lyricsProcessingRules} = $prefs->get('lyricsProcessingRules') || '[]';
	$paramRef->{playerId} = eval { $client ? $client->id : '' } || '';

	my $result = $class->SUPER::handler($client, $paramRef, $pageSetup);

	if ( $paramRef->{saveSettings} ) {
		_write_script_file($paramRef->{pref_lyricsSearchScriptPath}, $paramRef->{pref_lyricsSearchScript});
		_write_script_file($paramRef->{pref_lyricsProcessingScriptPath}, $paramRef->{pref_lyricsProcessingScript});
	}

	Plugins::MusicArtistInfo::Lyrics::MaterialSkin->sync if $paramRef->{saveSettings};

	return $result;
}


sub _script_file_target {
	my $path = shift;
	return unless defined $path && $path ne '';
	if ( -d $path ) {
		my $dh;
		return unless opendir($dh, $path);
		my @files = sort grep { /\.pl$/i } readdir($dh);
		closedir($dh);
		return @files ? catfile($path, $files[0]) : undef;
	}
	return $path;
}

sub _read_script_file {
	my $path = shift;
	my $target = _script_file_target($path);
	return unless $target && -f $target;
	my $raw = '';
	if ( open(my $fh, '<:raw', $target) ) {
		local $/;
		$raw = <$fh>;
		close $fh;
	}
	else {
		return;
	}
	my $text = eval { Encode::decode('UTF-8', $raw, FB_CROAK) };
	return defined $text && !$@ ? $text : undef;
}

sub _write_script_file {
	my ($path, $content) = @_;
	return unless defined $path && $path ne '' && defined $content;
	my $target = _script_file_target($path);
	return unless $target;
	return unless -f $target || $target =~ /\.pl$/i;
	if ( !-e $target ) {
		my $dir = dirname($target);
		return unless -d $dir;
	}
	my $tmp = $target . '.tmp.' . $$;
	if ( open(my $fh, '>:raw', $tmp) ) {
		print $fh Encode::encode('UTF-8', $content);
		close $fh;
	}
	else {
		return;
	}
	if ( !rename($tmp, $target) ) {
		unlink $tmp;
	}
}

1;
