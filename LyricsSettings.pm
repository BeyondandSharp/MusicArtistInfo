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

# Text preferences which may contain non-ASCII values.  LMS stores form
# values as byte strings; decode them before rendering and before they are
# used by the translation modules.
my @TRANSLATE_TEXT_PREFS = qw(
	lyricsTranslateTarget lyricsTranslateTargetCustom
	lyricsTranslateApiBase lyricsTranslateApiPath lyricsTranslateModel
	lyricsTranslateAuthHeader lyricsTranslateAuthPrefix lyricsTranslateExtraHeaders
	lyricsTranslateMode lyricsTranslateDetect lyricsTranslateMultiline lyricsTranslateFailedLine
	lyricsTranslateBackup lyricsTranslateCacheTtl lyricsTranslateReasoningEffort
	lyricsTranslateBatchSystem
	lyricsTranslateLineSystem lyricsTranslateDetectSystem
);

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
		lyricsTranslate lyricsTranslateTarget lyricsTranslateTargetCustom
		lyricsTranslateApiBase lyricsTranslateApiPath lyricsTranslateModel
		lyricsTranslateAuthHeader lyricsTranslateAuthPrefix lyricsTranslateExtraHeaders
		lyricsTranslateResponseFormat lyricsTranslateOnFileLoad lyricsTranslateOnSave
		lyricsTranslateMode
		lyricsTranslateBatchSize lyricsTranslateBatchTemperature lyricsTranslateBatchTimeout lyricsTranslateBatchMaxTokens
		lyricsTranslateLineConcurrency lyricsTranslateLineTemperature lyricsTranslateLineTimeout lyricsTranslateLineMaxTokens
		lyricsTranslateThinking lyricsTranslateReasoningEffort
		lyricsTranslateDetect lyricsTranslateDetectThreshold lyricsTranslateDetectModelWeight lyricsTranslateDetectTimeout
		lyricsTranslateMinTimestamps lyricsTranslateMaxRepeatedTimestamps
		lyricsTranslateMultiline lyricsTranslateFailedLine
		lyricsTranslateCache lyricsTranslateCacheTtl lyricsTranslateBackup
		lyricsTranslateQueueLimit lyricsTranslateMaxAttempts lyricsTranslateRetryDelay lyricsTranslateFailCooldown
		lyricsTranslateBatchSystem lyricsTranslateLineSystem lyricsTranslateDetectSystem
	));

	return @prefs;
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup) = @_;

	my $fb2kAvailable = Plugins::MusicArtistInfo::Lyrics::Format->available;
	my $xslateAvailable = Plugins::MusicArtistInfo::Lyrics::Format->textxslate_available;
	# Preserve a submitted selection.  The preference is still the old value
	# while handling the POST, so it must not overwrite pref_templateLanguage
	# before Slim::Web::Settings saves it.
	my $submittedLanguage = $paramRef->{pref_templateLanguage};
	my $language = defined $submittedLanguage && $submittedLanguage ne ''
		? $submittedLanguage
		: ($prefs->get('templateLanguage') || 'lms');
	$language = 'lms' unless $language =~ /^(?:lms|fb2k|textxslate)$/;
	if (!defined $submittedLanguage || $submittedLanguage eq '') {
		$language = 'lms' if $language eq 'fb2k' && !$fb2kAvailable;
		$language = 'lms' if $language eq 'textxslate' && !$xslateAvailable;
	}
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

	# LMS stores form values as byte strings.  Decode the translation text
	# preferences before SUPER::handler persists them.
	if ( $paramRef->{saveSettings} ) {
		foreach my $name (@TRANSLATE_TEXT_PREFS) {
			my $key = "pref_$name";
			next unless exists $paramRef->{$key};
			$paramRef->{$key} = _pref_chars($paramRef->{$key});
		}
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
	# Write the submitted files before the settings page is rendered.  The
	# previous ordering wrote them after SUPER::handler, so the page was
	# rendered with the old file content and appeared to revert until restart.
	my $searchPath = $paramRef->{pref_lyricsSearchScriptPath};
	$searchPath = $prefs->get('lyricsSearchScriptPath')
		if !defined $searchPath || $searchPath eq '';
	my $processingPath = $paramRef->{pref_lyricsProcessingScriptPath};
	$processingPath = $prefs->get('lyricsProcessingScriptPath')
		if !defined $processingPath || $processingPath eq '';
	if ( $paramRef->{saveSettings} ) {
		_write_script_file($searchPath, $paramRef->{pref_lyricsSearchScript});
		_write_script_file($processingPath, $paramRef->{pref_lyricsProcessingScript});
	}
	my $searchFile = _read_script_file($searchPath);
	$paramRef->{lyricsSearchScript} = $searchFile if defined $searchFile;
	my $processingFile = _read_script_file($processingPath);
	$paramRef->{lyricsProcessingScript} = $processingFile if defined $processingFile;
	$paramRef->{lyricsFieldProcessing} = $prefs->get('lyricsFieldProcessing') || '[]';
	$paramRef->{lyricsProcessingRules} = $prefs->get('lyricsProcessingRules') || '[]';
	$paramRef->{perlEditorAvailable} = eval {
		require Plugins::PerlEditor::API;
		Plugins::PerlEditor::API->available;
	} ? 1 : 0;
	$paramRef->{perlEditorScript} = eval {
		require Plugins::PerlEditor::API;
		Plugins::PerlEditor::API->editor_js;
	} || 'plugins/PerlEditor/editor.js';
	$paramRef->{playerId} = eval { $client ? $client->id : '' } || '';

	# Lyrics translation settings.  The API key is deliberately not a pref:
	# it lives in a separate 0600 file and is never sent back to the browser.
	$paramRef->{translateApiKeySource} = 'none';
	$paramRef->{translationConfigError} = '';
	if ( eval { require Plugins::MusicArtistInfo::Lyrics::TranslateSettings; 1 } ) {
		my $ts = 'Plugins::MusicArtistInfo::Lyrics::TranslateSettings';

		if ( $paramRef->{saveSettings} ) {
			my $submittedKey = $paramRef->{pref_lyricsTranslateApiKey};
			my $clearKey     = $paramRef->{pref_lyricsTranslateApiKeyClear};

			if ($clearKey) {
				$ts->clear_key;
			}
			elsif ( defined $submittedKey && $submittedKey ne '' ) {
				my $stored = $ts->store_key($submittedKey);
				$paramRef->{warning} .= 'Could not store the API key in ' . $ts->key_file . '.<br/>'
					unless $stored;
			}

			my $errors = eval { $ts->validate($paramRef) } || [];
			if ( @$errors ) {
				$paramRef->{translationConfigError} = join('; ', @$errors);
				$paramRef->{warning} .= $paramRef->{translationConfigError} . '<br/>';
			}
		}

		# Never echo a submitted key back into the page.
		delete $paramRef->{pref_lyricsTranslateApiKey};
		delete $paramRef->{pref_lyricsTranslateApiKeyClear} unless $paramRef->{saveSettings};

		my $status = eval { $ts->key_status } || {};
		$paramRef->{translateApiKeySource} = $status->{source} || 'none';
	}

	$paramRef->{langidAvailable} = 0;
	if ( eval { require Plugins::LangID::API; Plugins::LangID::API->available } ) {
		$paramRef->{langidAvailable} = 1;
		$paramRef->{langidVersion} = eval { Plugins::LangID::API->version } || '';
	}

	my $result = $class->SUPER::handler($client, $paramRef, $pageSetup);

	Plugins::MusicArtistInfo::Lyrics::MaterialSkin->sync if $paramRef->{saveSettings};

	return $result;
}

# Called by Slim::Web::Settings after the prefs have been processed and
# before the page is rendered.  Show the built-in prompt defaults in empty
# textareas and decode any byte-string pref values.
sub beforeRender {
	my ($class, $paramRef, $client) = @_;

	return unless ref $paramRef->{prefs} eq 'HASH';

	foreach my $name (@TRANSLATE_TEXT_PREFS) {
		my $key = "pref_$name";
		next unless exists $paramRef->{prefs}{$key};
		$paramRef->{prefs}{$key} = _pref_chars($paramRef->{prefs}{$key});
	}

	if ( eval { require Plugins::MusicArtistInfo::Lyrics::TranslateSettings; 1 } ) {
		my $defaults = Plugins::MusicArtistInfo::Lyrics::TranslateSettings->defaults;
		foreach my $stage (qw(Batch Line Detect)) {
			my $key = "pref_lyricsTranslate${stage}System";
			next if defined $paramRef->{prefs}{$key} && $paramRef->{prefs}{$key} ne '';
			$paramRef->{prefs}{$key} = $defaults->{"lyricsTranslate${stage}System"};
		}
	}

	return;
}


sub _pref_chars {
	my ($value) = @_;

	return $value unless defined $value && !ref $value && !utf8::is_utf8($value);

	my $decoded = eval { Encode::decode('UTF-8', $value, FB_CROAK) };
	return defined $decoded && !$@ ? $decoded : $value;
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
