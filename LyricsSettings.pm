package Plugins::MusicArtistInfo::LyricsSettings;

use strict;
use base qw(Slim::Web::Settings);

use JSON::PP ();

use Slim::Utils::Prefs;

use Plugins::MusicArtistInfo::Lyrics::Format;
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
		enableCustomLyricsSources customLyricsSourcesFolder customLyricsSourcesFirst
		saveLyricsWithSong overwriteLyricsWithSong lyricsFileNameFormat lyricsFolder
		integrateMaterialSkin
		useFb2kFormat lyricsSavePathFormat lyricsSaveFileNameFormat lyricsSaveBom lyricsSaveEncoding
		lyricsSaveMode lyricsSaveSyncOnly lyricsSaveApplyProcessing
		autoSearchLyrics lyricsMinMatch lyricsStopAfterFirst lyricsStopExternalOnLocal
		lyricsPreferSynced lyricsResultMode
		lyricsCustomSearchFields lyricsSearchTitleFormat lyricsSearchArtistFormat
		lyricsProcessReferenceOnly
		lyricsSourceOrder lyricsSearchFilters lyricsFieldProcessing lyricsProcessingRules
	));

	return @prefs;
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup) = @_;

	my $fb2kAvailable = Plugins::MusicArtistInfo::Lyrics::Format->available;

	if ( !$fb2kAvailable ) {
		$paramRef->{pref_useFb2kFormat} = 0;
	}

	# Fill in defaults for array settings and make sure malformed JSON
	# cannot be persisted.
	foreach my $key (qw(lyricsSourceOrder lyricsSearchFilters lyricsFieldProcessing lyricsProcessingRules)) {
		my $value = $paramRef->{"pref_$key"};
		$value = $prefs->get($key) if !defined $value;
		$value = '[]' if !defined $value || $value eq '';
		my $decoded = eval { JSON::PP->new->decode($value) };
		$value = '[]' unless ref $decoded eq 'ARRAY';
		$paramRef->{"pref_$key"} = $value;
	}

	$paramRef->{fb2kFormatAvailable} = $fb2kAvailable;
	$paramRef->{hanConvertAvailable} = eval { require Plugins::MusicArtistInfo::Lyrics::HanConvert; Plugins::MusicArtistInfo::Lyrics::HanConvert->available } ? 1 : 0;
	$paramRef->{lyricsSourceOptions} = Plugins::MusicArtistInfo::TrackInfo->lyrics_source_options;
	$paramRef->{lyricsSourceOrder} = $prefs->get('lyricsSourceOrder') || '[]';
	$paramRef->{lyricsSearchFilters} = $prefs->get('lyricsSearchFilters') || '[]';
	$paramRef->{lyricsFieldProcessing} = $prefs->get('lyricsFieldProcessing') || '[]';
	$paramRef->{lyricsProcessingRules} = $prefs->get('lyricsProcessingRules') || '[]';
	$paramRef->{playerId} = eval { $client ? $client->id : '' } || '';

	my $result = $class->SUPER::handler($client, $paramRef, $pageSetup);

	Plugins::MusicArtistInfo::Lyrics::MaterialSkin->sync if $paramRef->{saveSettings};

	return $result;
}

1;
