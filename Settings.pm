package Plugins::MusicArtistInfo::Settings;

use strict;
use base qw(Slim::Web::Settings);

use File::Path qw(make_path);

use Slim::Utils::Prefs;

use Plugins::MusicArtistInfo::Common qw(CAN_IMAGEPROXY CAN_ONLINE_LIBRARY CAN_LMS_ARTIST_ARTWORK isDirWritable);
use Plugins::MusicArtistInfo::Lyrics::PerlScripts;
use Plugins::MusicArtistInfo::Lyrics::MaterialSkin;

my $prefs = preferences('plugin.musicartistinfo');
my $serverprefs = preferences('server');

sub name {
	return 'PLUGIN_MUSICARTISTINFO';
}

sub prefs {
	my @prefs = ($prefs, qw(runImporter lookupArtistPictures lookupCoverArt reviewFolder artistImageFolder lyricsFolder bioFolder
		lookupAlbumArtistPicturesOnly saveMissingArtistPicturePlaceholder replaceOnlineGenres useAIGeneratedContent preferredLanguage
		hidextramenusitems saveLyricsWithSong overwriteLyricsWithSong lyricsFileNameFormat
		enableCustomLyricsSources customLyricsSourcesFolder customLyricsSourcesFirst
		integrateMaterialSkin));

	# we'll leave the artist picture handling to LMS, if possible
	push @prefs, 'browseArtistPictures' if !CAN_LMS_ARTIST_ARTWORK;

	return @prefs;
}

sub page {
	return 'plugins/MusicArtistInfo/settings.html';
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup) = @_;

	# update the lyrics providers to let users force-refresh the list without restarting LMS...
	Plugins::MusicArtistInfo::TrackInfo->updateLyricsProviders();

	# artfolder is a server setting - need to handle it manually
	if ($paramRef->{'saveSettings'}) {
		$serverprefs->set('artfolder', $paramRef->{artfolder});

		# XXX - what's wrong here? We should not need to do this!
		my (undef, @prefs) = $class->prefs();
		foreach (@prefs) {
			$paramRef->{"pref_$_"} ||= '';
		}

		$paramRef->{pref_lyricsFileNameFormat} = 'FILE'
			if !defined $paramRef->{pref_lyricsFileNameFormat}
			|| $paramRef->{pref_lyricsFileNameFormat} eq '';

		if ( $paramRef->{pref_enableCustomLyricsSources}
			&& (!defined $paramRef->{pref_customLyricsSourcesFolder}
				|| $paramRef->{pref_customLyricsSourcesFolder} eq '') ) {
			$paramRef->{pref_customLyricsSourcesFolder} =
				Plugins::MusicArtistInfo::Lyrics::PerlScripts->default_folder;
		}

		my $customFolder = $paramRef->{pref_customLyricsSourcesFolder};
		if ( $paramRef->{pref_enableCustomLyricsSources}
			&& $customFolder && !-d $customFolder ) {
			eval { make_path($customFolder) };
		}
	}

	$paramRef->{hitRateLimit} = Plugins::MusicArtistInfo::API::hasHitRateLimit();
	$paramRef->{noImageProxy} = !CAN_IMAGEPROXY;
	$paramRef->{canLMSArtistArtwork} = CAN_LMS_ARTIST_ARTWORK;
	$paramRef->{canOnlineLibrary} = CAN_ONLINE_LIBRARY;
	$paramRef->{artfolder} = $serverprefs->get('artfolder');
	$paramRef->{languageOptions} = Slim::Utils::Strings::languageOptions();
	$paramRef->{contentLanguages} = Plugins::MusicArtistInfo::Common::getContentLanguages();
	$paramRef->{lmsLanguage} = preferences('server')->get('language');
	$paramRef->{customSourcesDefaultFolder} = Plugins::MusicArtistInfo::Lyrics::PerlScripts->default_folder;

	my $customEnabled = $paramRef->{saveSettings}
		? $paramRef->{pref_enableCustomLyricsSources}
		: $prefs->get('enableCustomLyricsSources');

	my $customFolder = $paramRef->{saveSettings}
		? $paramRef->{pref_customLyricsSourcesFolder}
		: ($prefs->get('customLyricsSourcesFolder') || $paramRef->{customSourcesDefaultFolder});

	$paramRef->{customSourcesFolderMissing} =
		($customEnabled && (!$customFolder || !-d $customFolder)) ? 1 : 0;

	if ( $paramRef->{artfolder} && !isDirWritable($paramRef->{artfolder}) ) {
		$paramRef->{saveAlbumCoversDisabled} = 1;
	}

	my $result = $class->SUPER::handler($client, $paramRef, $pageSetup);

	Plugins::MusicArtistInfo::Lyrics::MaterialSkin->sync if $paramRef->{saveSettings};

	return $result;
}

1;
