package Plugins::MusicArtistInfo::TrackInfo;

use strict;

use Async::Util;
use Digest::MD5 qw(md5_hex);
use File::Basename qw(dirname);
use File::Slurp qw(write_file);
use File::Spec::Functions qw(catfile catdir);
use JSON::PP ();
use Time::HiRes qw(time);

use Slim::Menu::TrackInfo;
use Scalar::Util qw(blessed);
use Slim::Music::Info;
use Slim::Utils::Cache;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Utils::Unicode;

use Plugins::MusicArtistInfo::API;
use Plugins::MusicArtistInfo::Common qw(CLICOMMAND isDirWritable);
use Plugins::MusicArtistInfo::Parser::LRC;
use Plugins::MusicArtistInfo::Lyrics::Processor;
use Plugins::MusicArtistInfo::Lyrics::Match;
use Plugins::MusicArtistInfo::Lyrics::SearchSettings;
use Plugins::MusicArtistInfo::Text;
use Plugins::MusicArtistInfo::Lyrics::Candidates;
use Plugins::MusicArtistInfo::Lyrics::ChosenCache;
use Plugins::MusicArtistInfo::Lyrics::PerlScripts;
use Plugins::MusicArtistInfo::Lyrics::FileName;
use Plugins::MusicArtistInfo::Lyrics::Sidecar;
use Plugins::MusicArtistInfo::Lyrics::SaveTarget;
use Plugins::MusicArtistInfo::Lyrics::WebUI;

my $log = logger('plugin.musicartistinfo');
my $onlineLog = logger('plugin.musicartistinfo.online');
my $prefs = preferences('plugin.musicartistinfo');
my $cache = Slim::Utils::Cache->new;
my $chosenCache = Plugins::MusicArtistInfo::Lyrics::ChosenCache->new;
my $AUTO_SAVE_TOKEN = {};
my %AUTO_SOURCE_SEEN;
my $AUTO_SUBSCRIBED = 0;

my $CANDIDATE_SESSION_EXPIRES = 30 * 60;
my $CANDIDATE_TIMEOUT         = 30;
my $MAX_OVERRIDE_LENGTH       = 200;

my $lyricsProviderPipeline = [
	'MAILyricsAPI',
	# 'AZLyrics',
	# 'LRCLibGet',
	# 'LRCLibSearch',
	# 'ChartLyrics',
];

my $lyricsProvider;
my %lyricsProviderLabels;

sub init {
#                                                                |requires Client
#                                                                |  |is a Query
#                                                                |  |  |has Tags
#                                                                |  |  |  |Function to call
#                                                                C  Q  T  F
	Slim::Control::Request::addDispatch([CLICOMMAND, 'lyrics'], [0, 1, 1, \&getSongLyricsCLI]);

	if ( !$AUTO_SUBSCRIBED++ ) {
		Slim::Control::Request::subscribe(\&_autoSearchNewsong, [['playlist'], ['newsong']]);
	}

	Slim::Menu::TrackInfo->registerInfoProvider( moretrackinfo => (
		func => \&_objInfoHandler,
		after => 'moreartistinfo',
	) );

	if ( main::WEBUI ) {
		eval {
			require Slim::Web::Pages;
			Slim::Web::Pages->addRawFunction(
				qr{plugins/MusicArtistInfo/lyrics/(?:candidates|select|search|cancel|save-preview|script)},
				\&_lyricsApi,
			);
		};
		$log->error("Could not register lyrics chooser endpoints: $@") if $@;
	}

	Slim::Utils::Timers::setTimer(__PACKAGE__, time() + rand(5), \&updateLyricsProviders);
}

sub _autoSearchNewsong {
	my $request = shift;

	my $client = $request->client();
	return unless $client;

	my $song = eval { $client->playingSong };
	return unless $song;

	my $track = eval { $song->track };
	return unless $track;

	# Candidate results for the previous track are only valid while that
	# track is playing.  Bump the epoch on every new song.
	$cache->set('mai_lyrics_track_epoch', time() . ':' . rand(), 24 * 3600);

	return unless $prefs->get('autoSearchLyrics');

	Slim::Utils::Timers::killTimers($AUTO_SAVE_TOKEN);

	my $key = ($client->id || '') . ':' . ($track->id || '');
	return if $AUTO_SOURCE_SEEN{$key}++;

	my $args = {
		track    => $track,
		title    => $track->title,
		artist   => $track->artistName,
		album    => $track->albumname,
		duration => $track->secs,
		url      => $track->url,
		track_id => $track->id,
	};

	return if Plugins::MusicArtistInfo::Lyrics::SearchSettings->skip_auto_search($args);

	my $local;
	foreach my $source (_local_source_ids()) {
		$local = $source eq 'TagLyrics'
			? eval { $track->lyrics }
			: eval { _getLocalLyrics($args) };
		last if $local;
	}
	$local ||= eval { _getCachedLyrics($args) };

	return if $local && $prefs->get('lyricsStopExternalOnLocal');

	my $resultMode = $prefs->get('lyricsResultMode') || 'best';

	collectCandidates($args, sub {
		my $candidates = shift || [];

		_candidate_cache_store($args, $candidates, $args);

		if ( $resultMode eq 'all_manual' ) {
			$cache->set(
				'mai_auto_pending_' . md5_hex($key),
				[ map { { %$_ } } @$candidates ],
				3600,
			);
			return;
		}

		my $best = Plugins::MusicArtistInfo::Lyrics::Match->best(
			$candidates,
			$args,
			{
				min           => $prefs->get('lyricsMinMatch') || 0,
				prefer_synced => $prefs->get('lyricsPreferSynced'),
			},
		);

		return unless $best;
		return if $resultMode eq 'manual_if_none' && $local;

		$chosenCache->save($args, $best->{lyrics});
		_cacheLyrics($args, $best->{lyrics});
		_schedule_auto_sidecar($client, $track, $args, $best);
	}, {
		stop_after_first => $prefs->get('lyricsStopAfterFirst'),
	});
}

sub _schedule_auto_sidecar {
	my ($client, $track, $args, $candidate) = @_;

	return unless $prefs->get('saveLyricsWithSong');
	return unless $candidate && defined $candidate->{lyrics} && $candidate->{lyrics} =~ /\S/;
	return if $prefs->get('lyricsSaveSyncOnly') && !$candidate->{synced};

	my $mode = $prefs->get('lyricsSaveMode') || 'fixed_time';
	return if $mode eq 'manual';

	my $duration = $args->{duration} || eval { $track->secs } || 0;
	my $delay;

	if ( $mode eq 'immediate' ) {
		_save_lyrics_next_to_song($args, $candidate->{lyrics}, $candidate, 0);
		return;
	}
	elsif ( $mode eq 'fixed_time' ) {
		$delay = $prefs->get('lyricsSaveSeconds') || 60;
		$delay = 60 if $delay <= 0;
	}
	elsif ( $mode eq 'fixed_ratio' ) {
		my $ratio = $prefs->get('lyricsSaveRatio') || 33;
		$delay = $duration > 0 ? $duration * $ratio / 100 : 60;
	}
	elsif ( $mode eq 'auto_60' ) {
		$delay = 60;
	}
	else { # auto_60_or_third / legacy
		$delay = 60;
		$delay = $duration / 3 if $duration > 0 && $duration / 3 < $delay;
	}

	my $trackId = $track->id;
	Slim::Utils::Timers::setTimer(
		$AUTO_SAVE_TOKEN,
		time() + $delay,
		sub {
			my $current = eval { $client->playingSong };
			my $currentTrack = $current ? eval { $current->track } : undef;
			return unless $currentTrack && $currentTrack->id eq $trackId;
			_save_lyrics_next_to_song($args, $candidate->{lyrics}, $candidate, 0);
		},
	);
}

sub _objInfoHandler {
	my ( $client, $url, $obj, $remoteMeta ) = @_;

	my ($title, $artist, $id);

	if ( $obj && blessed $obj ) {
		if ($obj->isa('Slim::Schema::Track')) {
			$id     = $obj->id;
			$title  = $obj->title;
			$artist = $obj->artistName;
		}

		# no need to render our "Lyrics" item if track has lyrics - it'll be added by default handler anyway.
		return if $obj->lyrics;
	}

	$remoteMeta ||= {};
	$title ||= $remoteMeta->{title};
	$artist ||= $remoteMeta->{artist};

	if ( !($title && $artist) && $obj->remote ) {
		my $request = Slim::Control::Request::executeRequest($client, ['status', 0, 10]);
		my $remoteMeta = $request->getResult('remoteMeta');

		$title ||= $remoteMeta->{title};
		$artist ||= $remoteMeta->{artist};
	}

	return unless $id || ($title && $artist);

	return {
		name => cstring($client, 'LYRICS'),
		type => 'link',
		url => \&getLyrics,
		passthrough => [ {
			id       => $id,
			title    => $title,
			artist   => $artist,
			url      => $url,
			album    => ($obj && blessed $obj && $obj->can('albumname') ? $obj->albumname : undef),
			duration => ($obj && blessed $obj && $obj->can('secs') ? $obj->secs : undef),
		} ],
	};
}

sub getSongLyricsCLI {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([[CLICOMMAND], ['lyrics']])) {
		$request->setStatusBadDispatch();
		return;
	}

	$request->setStatusProcessing();

	my $client = $request->client();

	my $args;
	my $artist = $request->getParam('artist');
	my $album  = $request->getParam('album');
	my $title  = $request->getParam('title');
	my $id     = $request->getParam('track_id');
	my $url    = $request->getParam('url');
	my $duration = $request->getParam('duration');

	my $args   = {
		artist => $artist,
		album  => $album,
		title  => $title,
		url    => $url,
		track_id => $id,
		duration => $duration
	};

	if (defined $id){
		$args->{track} = Slim::Schema->find('Track', $id);
	}
	elsif ($url) {
		$args->{track} = Slim::Schema->objectForUrl($url);
	}
	elsif ($client) {
		$args->{track} = Plugins::MusicArtistInfo::Common::getTrackAndRadioUrl($client, $args);
	}

	if ($args->{track}) {
		$args->{artist} //= $args->{track}->artistName;
		$args->{album}  //= $args->{track}->albumname;
		$args->{title}  //= $args->{track}->title;
		$args->{duration} = $args->{track}->secs;
		$args->{radioUrl} //= $args->{track}->url if Slim::Music::Info::isHTTPURL($args->{track}->url);

		if ( $client && !($args->{track} && $args->{artist} && $args->{title} && $args->{duration} && $args->{album}) && $args->{track}->isRemoteURL ) {
			my $handler = Slim::Player::ProtocolHandlers->handlerForURL($args->{track}->url);

			if ( $handler && $handler->can('getMetadataFor') ) {
				my $meta = $handler->getMetadataFor( $client, $args->{track}->url );
				$args->{artist} //= $meta->{artist};
				$args->{album}  //= $meta->{album};
				$args->{title}  //= $meta->{title};
				$args->{duration} ||= $meta->{duration};
			}
		}
	}

	$args->{radioUrl} ||= $url if Slim::Music::Info::isHTTPURL($url);

	# remove album/duration from radio streams - they're most likely invalid data
	if ($args->{radioUrl}) {
		delete $args->{album};
		delete $args->{duration};
	}

	# some cleanup... music services add too many appendices
	$args->{title} =~ s/[([][^)\]]*?(deluxe|edition|remaster|live|anniversary)[^)\]]*?[)\]]//ig;
	$args->{title} =~ s/ -[^-]*(deluxe|edition|remaster|live|anniversary).*//ig;

	# specific rule for the "[E]"xplicit flag - it's too specific/short to fit in with the above
	$args->{title} =~ s/\[E\]//g;

	# remove trailing non-word characters
	$args->{title} =~ s/[\s\W]{2,}$//;
	$args->{title} =~ s/\s*$//;

	my $killWords = Plugins::MusicArtistInfo::Common::getKillWords() || {};
	foreach (qw(title artist album)) {
		delete $args->{$_} if $killWords->{lc($args->{$_} || '')};
	}

	# Radio Now Playing adds the station after the pipe sign
	$args->{album} =~ s/\|.*// if $args->{album};

	if (!defined $args->{title} || !defined $args->{artist}
		|| $args->{title} eq '' || $args->{artist} eq ''
		|| (length($args->{title}) > 50 && length($args->{artist}) > 50)
	) {
		main::INFOLOG && $log->is_info && $log->info("Don't look up lyrics, as we lack track title ('$args->{title}') or artist name ('$args->{artist}').");
		$request->addResult('error', cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'));
		$request->setStatusDone();
		return;
	}

	main::INFOLOG && $log->is_info && $log->info("Getting lyrics for " . $args->{title} . ' by ' . $args->{artist});

	my $forceOnlineLookup = main::DEBUGLOG && $onlineLog->is_debug;
	if ( !$forceOnlineLookup ) {
		foreach my $source (_local_source_ids()) {
			my $lyrics = $source eq 'TagLyrics'
				? ($args->{track} ? $args->{track}->lyrics : undef)
				: _getLocalLyrics($args);
			next unless defined $lyrics && $lyrics =~ /\S/;
			main::INFOLOG && $log->is_info && $log->info("Found $source lyrics for " . $args->{title} . ' by ' . $args->{artist});
			_renderLyricsResponse($lyrics, $request, $args);
			$request->setStatusDone();
			return;
		}
	}

	if ( !$forceOnlineLookup && (my $lyrics = $chosenCache->get($args)) ) {
		main::INFOLOG && $log->is_info && $log->info("Found lyrics chosen for " . $args->{title} . ' by ' . $args->{artist});
		_renderLyricsResponse($lyrics, $request, $args);
		$request->setStatusDone();
		return;
	}

	if ( !$forceOnlineLookup && (my $lyrics = _getCachedLyrics($args)) ) {
		main::INFOLOG && $log->is_info && $log->info("Found cached lyrics for " . $args->{title} . ' by ' . $args->{artist});
		_save_lyrics_next_to_song($args, $lyrics, undef, 0);
		_renderLyricsResponse($lyrics, $request, $args);
		$request->setStatusDone();
		return;
	}

	_fetchLyrics($args, sub {
		my $item = shift;

		my $lyrics = $item->{lyrics};

		# CLI clients expect real line breaks, not literal \n
		_renderLyricsResponse($lyrics, $request, $args);

		_cacheLyrics($args, $lyrics);
		_save_lyrics_next_to_song($args, $lyrics, $item, 0);

		$request->setStatusDone();
	}, sub {
		my $item = shift;
		if ( !$item || !ref $item ) {
			$request->addResult('error', cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'));
		}
		elsif ( $item->{error} ) {
			$request->addResult('error', $item->{error});
		}

		$request->setStatusDone();
	})
}

sub getLyrics {
	my ($client, $cb, $params, $args) = @_;

	$params ||= {};
	$args   ||= {};
	$cb     ||= sub {};

	my $gotLyrics = sub {
		my $lyricsRequest = shift;

		my $responseText = $lyricsRequest->getResult('lyrics') || $lyricsRequest->getResult('error');
		my $isWeb = !$params->{isButton}
			&& Plugins::MusicArtistInfo::Plugin->isWebBrowser($client, $params);

		if ($isWeb) {
			$responseText = _web_lyrics_content(
				$client,
				$args,
				$lyricsRequest->getResult('lyrics'),
				$lyricsRequest->getResult('error'),
			);
		}

		$cb->({
			items => Plugins::MusicArtistInfo::Plugin->textAreaItem($client, $params->{isButton}, $responseText),
		});
	};

	$args->{track_id} ||= $args->{id} if defined $args->{id};

	my $command = [CLICOMMAND, 'lyrics'];
	foreach (qw(title artist url track_id)) {
		my $v = $args->{$_};
		if (defined $v && $v ne '') {
			push @$command, "$_:$v";
		}
	}

	my $request = Slim::Control::Request::executeRequest($client, $command);
	if ( $request->isStatusProcessing ) {
		$request->callbackFunction($gotLyrics);
	} else {
		$gotLyrics->($request);
	}
}

%lyricsProviderLabels = (
	MAILyricsAPI => 'MusicArtistInfo',
	AZLyrics    => 'AZLyrics',
	LRCLibGet   => 'LRCLib',
	LRCLibSearch => 'LRCLib',
	ChartLyrics => 'ChartLyrics',
	Genius      => 'Genius',
	GeniusNoDot => 'Genius',
	PerlScripts => 'Perl scripts',
);

$lyricsProvider = {
	MAILyricsAPI => sub {
		my ($args, $cb) = @_;
		Plugins::MusicArtistInfo::API->getLyrics($cb, $args);
	},
	# AZLyrics => sub {
	# 	require Plugins::MusicArtistInfo::Lyrics::AZLyrics;
	# 	Plugins::MusicArtistInfo::Lyrics::AZLyrics->getLyrics(@_);
	# },
	# no lookup, only tell LRCLib to use the proxy
	# LRCLibProxyEnable => sub {
	# 	my ($args, $scb) = @_;
	# 	require Plugins::MusicArtistInfo::Lyrics::LRCLib;
	# 	Plugins::MusicArtistInfo::Lyrics::LRCLib->enableProxying();
	# 	$scb->();
	# },
	# LRCLibGet => sub {
	# 	require Plugins::MusicArtistInfo::Lyrics::LRCLib;
	# 	Plugins::MusicArtistInfo::Lyrics::LRCLib->getLyrics(@_)
	# },
	# LRCLibSearch => sub {
	# 	require Plugins::MusicArtistInfo::Lyrics::LRCLib;
	# 	Plugins::MusicArtistInfo::Lyrics::LRCLib->searchLyrics(@_)
	# },
	# ChartLyrics => sub {
	# 	require Plugins::MusicArtistInfo::Lyrics::ChartLyrics;
	# 	Plugins::MusicArtistInfo::Lyrics::ChartLyrics->searchLyricsInDirect(@_);
	# },
	Genius => sub {
		require Plugins::MusicArtistInfo::Lyrics::Genius;
		Plugins::MusicArtistInfo::Lyrics::Genius->getLyrics(@_);
	},
	GeniusNoDot => sub {
		my ($args, $scb) = @_;

		if ($args->{title} !~ /\./ && $args->{artist} !~ /\./) {
			return $scb->();
		}
		else {
			require Plugins::MusicArtistInfo::Lyrics::Genius;
			# try one more time with punctuation removed - https://github.com/michaelherger/MusicArtistInfo/issues/12
			$args->{artist} =~ s/\.//g;
			$args->{title}  =~ s/\.//g;

			Plugins::MusicArtistInfo::Lyrics::Genius->getLyrics($args, $scb);
		}
	},
	PerlScripts => sub {
		require Plugins::MusicArtistInfo::Lyrics::PerlScripts;
		Plugins::MusicArtistInfo::Lyrics::PerlScripts->getLyrics(@_);
	}
};

sub _source_disabled {
	my %disabled;
	my $raw = $prefs->get('lyricsSourceDisabled');
	return \%disabled unless defined $raw && $raw ne '';
	my $decoded = eval { JSON::PP->new->decode($raw) };
	if ( ref $decoded eq 'ARRAY' ) {
		$disabled{$_} = 1 for @$decoded;
	}
	elsif ( ref $decoded eq 'HASH' ) {
		$disabled{$_} = 1 for grep { !$decoded->{$_} } keys %$decoded;
	}
	return \%disabled;
}

sub _source_enabled {
	my $id = shift;
	my $disabled = _source_disabled();
	return !$disabled->{$id};
}

sub _source_order {
	my @available = @_;
	my @saved;
	my $raw = $prefs->get('lyricsSourceOrder');
	if ( defined $raw && $raw ne '' ) {
		my $decoded = eval { JSON::PP->new->decode($raw) };
		if ( ref $decoded eq 'ARRAY' ) {
			foreach my $item (@$decoded) {
				if ( ref $item eq 'HASH' ) {
					push @saved, $item->{id} if defined $item->{id};
				}
				else {
					push @saved, $item;
				}
			}
		}
	}

	my %available = map { $_ => 1 } @available;
	my %seen;
	my @order;
	foreach my $id (@saved, @available) {
		next if !defined $id || !$available{$id} || $seen{$id}++;
		next unless _source_enabled($id);
		push @order, $id;
	}
	return @order;
}

sub _perl_script_file {
	my $name = shift;
	foreach my $source (@{ Plugins::MusicArtistInfo::Lyrics::PerlScripts->script_sources }) {
		return $source->{file} if $source->{id} eq "PerlScripts:$name";
	}
	return;
}

sub _online_source_ids {
	my @available = grep { !/^Genius/ } @{$prefs->get('lyricsProviders') || $lyricsProviderPipeline};
	push @available, map { $_->{id} } @{ Plugins::MusicArtistInfo::Lyrics::PerlScripts->script_sources };
	return _source_order(@available);
}

sub _local_source_ids {
	return _source_order('TagLyrics', 'LocalLyrics');
}

sub _lyrics_source_ids {
	return _online_source_ids();
}


sub _fetchLyrics {
	my ($args, $cb, $ecb) = @_;

	my $lyricsResult;
	my $lookupArgs = Plugins::MusicArtistInfo::Lyrics::SearchSettings->prepare_args($args);

	my @handlers;
	foreach my $id (_online_source_ids()) {
		if ( $id =~ /^PerlScripts:(.+)$/ ) {
			my $file = _perl_script_file($1);
			next unless $file;
			push @handlers, sub {
				Plugins::MusicArtistInfo::Lyrics::PerlScripts->getLyrics(shift, shift, $file);
			};
		}
		elsif ( $lyricsProvider->{$id} ) {
			push @handlers, $lyricsProvider->{$id};
		}
	}
	my $handlerPipeline = \@handlers;

	Async::Util::amap(
		inputs => $handlerPipeline,
		action => sub {
			my ($handler, $acb) = @_;

			if ($lyricsResult) {
				$acb->($lyricsResult);
				return;
			}

			$handler->($lookupArgs, sub {
				my $result = shift;

				if ($result && ref $result && keys %$result && !$result->{error}) {
					$lyricsResult = $result;
					$acb->($result);
				}
				else {
					$acb->();
				}
			});
		},
		cb => sub {
			if ($lyricsResult && ref $lyricsResult && keys %$lyricsResult && !$lyricsResult->{error}) {
				$cb->($lyricsResult);
			}
			else {
				$ecb->($lyricsResult);
			}
		},
		at_a_time => scalar(@$handlerPipeline) || 1,
	);
}

sub _cacheLyrics {
	my ($args, $lyrics) = @_;

	return unless $lyrics;

	if (my $lyricsFile = _getLyricsCacheFile($args, 'create')) {
		my $encodedLyrics = $lyrics;
		utf8::encode($encodedLyrics);

		$lyricsFile =~ s/\.txt$/.lrc/ if $encodedLyrics =~ /^\[\d+:\d+\.\d+\]/gm;

		write_file($lyricsFile, { err_mode => 'carp' }, $encodedLyrics) || $log->error("Failed to write lyrics to $lyricsFile");
	}
}

sub _getCachedLyrics {
	my ($args) = @_;

	if (my $lyricsFile = _getLyricsCacheFile($args)) {
		$lyricsFile =~ s/\.txt$/.lrc/ if !-f $lyricsFile;

		main::INFOLOG && $log->is_info && $log->info("Trying to get lyrics from $lyricsFile");

		if (-f $lyricsFile) {
			main::INFOLOG && $log->is_info && $log->info("Found cached lyrics!");
			return Plugins::MusicArtistInfo::Text->read_file(
				$lyricsFile,
				{ hints => [ $args->{artist}, $args->{title} ] },
			);
		}
	}

	return;
}

sub _getLyricsCacheFile {
	my ($args, $create) = @_;

	if ( $args->{title} && $args->{artist} && (my $lyricsFolder = $prefs->get('lyricsFolder')) ) {
		mkdir $lyricsFolder if $create && ! -d $lyricsFolder;

		if (!$create || isDirWritable($lyricsFolder)) {
			my $artistDir = catdir($lyricsFolder, @{Plugins::MusicArtistInfo::Common::getLocalnameVariants($args->{artist})}[0]);
			$artistDir =~ s/\.$//;
			mkdir $artistDir if $create && ! -d $artistDir;

			my $candidates = Plugins::MusicArtistInfo::Common::getLocalnameVariants($args->{title});
			my $lyricsFile = catfile($artistDir, $candidates->[0] . '.txt');

			return $lyricsFile;
		}
	}

	return;
}

sub _getLocalLyrics {
	my ($args) = @_;

	my $track = $args->{track};
	my $url = $track->url if $track;
	$url ||= $args->{url};
	$url =~ s/^tmp:/file:/ if $url;

	my $lyrics;

	# try "Song.mp3.lrc" and "Song.lrc"
	if ($url && Slim::Music::Info::isFileURL($url)) {
		my $audioPath = Slim::Utils::Misc::pathFromFileURL($url);
		my $filePath  = $audioPath;
		my $filePath2 = $audioPath . '.lrc';
		$filePath =~ s/\.\w{2,4}$/.lrc/;

		# try .lrc files first
		my @files = ($filePath, $filePath2);

		# text files second
		my $textPath  = $filePath;
		my $textPath2 = $filePath2;
		$textPath  =~ s/\.lrc$/.txt/;
		$textPath2 =~ s/\.lrc$/.txt/;

		push @files, $textPath, $textPath2;

		# file named according to the user-configured filename format
		if ( $track && -f $audioPath ) {
			my $format = $prefs->get('lyricsFileNameFormat') || 'FILE';
			my $basename = eval {
				Plugins::MusicArtistInfo::Lyrics::FileName->lyrics_filename($track, $format)
			};

			if ( $basename ) {
				my $patternFile = catfile(dirname($audioPath), $basename);
				unshift @files, $patternFile;
			}
		}

		my %seen;
		@files = grep { defined $_ && !$seen{$_}++ } @files;

		foreach my $file (@files) {
			if (-r $file) {
				$lyrics = Plugins::MusicArtistInfo::Text->read_file(
					$file,
					{ hints => [ $args->{artist}, $args->{title} ] },
				);
				last if defined $lyrics && $lyrics ne '';
			}
		}

		return $lyrics if $lyrics;
	}

	if ($args->{artist} && $args->{title}) {
		my $lyricsCacheFolder = _getLyricsCacheFile({
			artist => $args->{artist},
			title => $args->{title}
		});
		$lyricsCacheFolder = dirname($lyricsCacheFolder) if $lyricsCacheFolder;

		if ($lyricsCacheFolder && -r $lyricsCacheFolder) {
			my $candidates = Plugins::MusicArtistInfo::Common::getLocalnameVariants($args->{title});

			opendir(LYRICSDIR, $lyricsCacheFolder) && do {
				my %files = map {
					s/\.txt$//;
					lc($_) => "$_.txt";
				} grep {
					$_ !~ /^(?:\.\.|\.)$/;
				} readdir(LYRICSDIR);
				closedir(LYRICSDIR);

				if (keys %files) {
					foreach (@$candidates) {
						if ( my $file = $files{lc($_)} ) {

							$lyrics = Plugins::MusicArtistInfo::Text->read_file(
								catfile($lyricsCacheFolder, $file),
								{ hints => [ $args->{artist}, $args->{title} ] },
							);
							last if defined $lyrics && $lyrics ne '';
						}
					}
				}
			};
		}
	}

	return $lyrics;
}

sub _save_lyrics_next_to_song {
	my ($args, $lyrics, $item, $force) = @_;

	return unless $prefs->get('saveLyricsWithSong');
	return unless defined $lyrics && $lyrics =~ /\S/;
	return if $item && $item->{instrumental};

	my $instrumental = string('PLUGIN_MUSICARTISTINFO_INSTRUMENTAL');
	return if $instrumental && $lyrics eq $instrumental;

	my $track = $args->{track};
	return unless $track && $track->url;

	my $url = $track->url;
	$url =~ s/^tmp:/file:/ if $url;

	return unless Slim::Music::Info::isFileURL($url);

	my $audioPath = Slim::Utils::Misc::pathFromFileURL($url);
	return unless $audioPath && -f $audioPath;

	my $target = Plugins::MusicArtistInfo::Lyrics::SaveTarget->build($track, {
		template_language => $prefs->get('templateLanguage') || 'lms',
		path_format    => $prefs->get('lyricsSavePathFormat'),
		file_format    => $prefs->get('lyricsSaveFileNameFormat'),
		lms_file_format => $prefs->get('lyricsFileNameFormat') || 'FILE',
	});

	unless ( $target && $target->{full_path} ) {
		$log->warn('Could not determine lyrics save target: ' . ($target->{error} || 'unknown error'));
		return;
	}

	if ( $prefs->get('lyricsSaveApplyProcessing') ) {
		$lyrics = Plugins::MusicArtistInfo::Lyrics::Processor->process($lyrics);
	}

	my $result = Plugins::MusicArtistInfo::Lyrics::Sidecar->save_path(
		$target->{full_path},
		$lyrics,
		{
			overwrite => $force || $prefs->get('overwriteLyricsWithSong'),
			encoding  => $prefs->get('lyricsSaveEncoding') || 'utf8',
		},
	);

	if ( $result->{file} ) {
		main::INFOLOG && $log->is_info && $log->info("Saved lyrics to $result->{file}");
	}
	elsif ( $result->{error} ) {
		$log->warn("Could not save lyrics next to $audioPath: $result->{error}");
	}

	return $result;
}

sub _web_lyrics_content {
	my ($client, $args, $lyrics, $error) = @_;

	my $version = eval { $Plugins::MusicArtistInfo::Plugin::VERSION } || '1.30.1';

	return Plugins::MusicArtistInfo::Lyrics::WebUI->build(
		client   => $client,
		lyrics   => $lyrics,
		error    => $error,
		track_id => $args->{track_id} || $args->{id},
		url      => $args->{url},
		title    => $args->{title},
		artist   => $args->{artist},
		album    => $args->{album},
		duration  => $args->{duration},
		endpoint => '/plugins/MusicArtistInfo/lyrics',
		player   => $client ? $client->id : '',
		script   => "/plugins/MusicArtistInfo/html/lyricsChooser.js?v=$version",
		strings  => _lyrics_chooser_strings($client),
	);
}

sub _lyrics_chooser_strings {
	my ($client) = @_;

	my %fallback = (
		choose  => 'Choose lyrics',
		title   => 'Title',
		artist  => 'Artist',
		search  => 'Search',
		use     => 'Use this lyrics',
		close   => 'Close',
		loading => 'Searching for lyrics...',
		none    => 'No lyrics found',
		error   => 'Could not load lyrics',
		saved   => 'Saved',
		cached  => 'Cached',
		source  => 'Source',
		synced  => 'Synced',
		plain   => 'Plain text',
	);

	my %strings;
	foreach my $key (keys %fallback) {
		my $string = eval {
			cstring($client, 'PLUGIN_MUSICARTISTINFO_LYRICS_CHOOSER_' . uc($key));
		};

		$strings{$key} = (defined $string && $string ne '') ? $string : $fallback{$key};
	}

	return \%strings;
}

sub _builtin_candidate_sources {
	my @sources;

	my @ids = @{$prefs->get('lyricsProviders') || $lyricsProviderPipeline};

	foreach my $id (@ids) {
		next if $id eq 'PerlScripts';
		next if $id =~ /^Genius/;
		next unless $lyricsProvider->{$id};

		push @sources, {
			id    => $id,
			label => $lyricsProviderLabels{$id} || $id,
		};
	}

	return @sources;
}

sub collectCandidates {
	my ($lookupArgs, $cb, $opts) = @_;

	$opts ||= {};
	$lookupArgs = Plugins::MusicArtistInfo::Lyrics::SearchSettings->prepare_args($lookupArgs);

	my $onCandidate = $opts->{on_candidate};
	my $onProgress  = $opts->{on_progress};
	my $stopAfterFirst = $opts->{stop_after_first};

	my @candidates;
	my $done = 0;
	my $token = {};
	my $timer;
	my $sourcesDone = 0;
	my $totalSources = 0;

	my $reportProgress = sub {
		return if $done || !$onProgress;
		$onProgress->({
			done  => $sourcesDone,
			total => $totalSources,
			found => scalar @candidates,
		});
	};

	my $sourceDone = sub {
		return if $done;
		$sourcesDone++;
		$reportProgress->();
	};

	my $finish = sub {
		return if $done++;
		Slim::Utils::Timers::killTimers($token, $timer) if $timer;

		my $final = Plugins::MusicArtistInfo::Lyrics::Candidates->finalize(\@candidates);
		$log->debug('Lyrics chooser collected ' . scalar(@$final) . ' candidates');
		$cb->($final) if $cb;
	};

	$timer = sub { $finish->() };
	Slim::Utils::Timers::setTimer($token, time() + $CANDIDATE_TIMEOUT, $timer);

	my @sources = _builtin_candidate_sources();

	my %sourcesById = map { $_->{id} => $_ } @sources;
	foreach my $script (@{ Plugins::MusicArtistInfo::Lyrics::PerlScripts->script_sources }) {
			$sourcesById{ $script->{id} } = {
				id     => $script->{id},
				label  => $script->{label},
				custom => 1,
				file   => $script->{file},
			};
	}

	my @ordered;
	foreach my $id (_online_source_ids()) {
		push @ordered, $sourcesById{$id} if $sourcesById{$id};
	}
	@sources = @ordered;

	$totalSources = scalar @sources;
	$reportProgress->();

	unless (@sources) {
		return $finish->();
	}

	Async::Util::amap(
		inputs => \@sources,
		action => sub {
			my ($source, $acb) = @_;

			return $acb->() if $done;

			my %args = %$lookupArgs;
			my $priority = 0;
			for (my $i = 0; $i < @sources; $i++) {
				if ( $sources[$i] eq $source ) {
					$priority = $i;
					last;
				}
			}

			if ( $source->{custom} ) {
				$log->debug('Lyrics chooser querying Perl scripts');
				Plugins::MusicArtistInfo::Lyrics::PerlScripts->getCandidates(
					\%args,
					sub {
						my $result = shift || [];
						$log->debug('Lyrics chooser Perl scripts returned ' . scalar(@$result) . ' candidates');

						if ( !$onCandidate ) {
							foreach my $candidate (@$result) {
								next unless ref $candidate eq 'HASH';
								$candidate->{priority} = $priority;
								push @candidates, $candidate;
							}
						}
						if ( $stopAfterFirst && @candidates ) {
							$finish->();
							return;
						}

						$sourceDone->();
						$acb->();
					},
					$onCandidate ? sub {
						my $candidate = shift;
						return if $done || !$candidate || ref $candidate ne 'HASH';
						$candidate->{priority} = $priority;
						push @candidates, $candidate;
						$onCandidate->($candidate);
						$reportProgress->();
					} : undef,
					$source->{file},
				);

				return;
			}

			my $handler = $lyricsProvider->{$source->{id}};

			unless ($handler) {
				$sourceDone->();
				$acb->();
				return;
			}

			$handler->(\%args, sub {
				my $result = shift;

				if ( $result && ref $result && !$result->{error} && $result->{lyrics} ) {
					my $candidate = Plugins::MusicArtistInfo::Lyrics::Candidates->normalize(
						$result,
						$source->{label},
					);

					if ($candidate) {
						$candidate->{priority} = $priority;
						push @candidates, $candidate;
						$onCandidate->($candidate) if $onCandidate && !$done;
						$reportProgress->();
						if ( $stopAfterFirst && @candidates ) {
							$finish->();
							return;
						}
					}
				}

				$sourceDone->();
				$acb->();
			});
		},
		cb => sub {
			$finish->();
		},
		at_a_time => scalar(@sources) || 1,
	);
}

sub _trim_param {
	my ($value) = @_;

	return '' unless defined $value;
	$value =~ s/^\s+//;
	$value =~ s/\s+$//;
	$value = substr($value, 0, $MAX_OVERRIDE_LENGTH) if length($value) > $MAX_OVERRIDE_LENGTH;

	return $value;
}

sub _decode_param {
	my ($value) = @_;

	return $value unless defined $value;

	eval {
		if ( Slim::Utils::Unicode::looks_like_utf8($value) ) {
			$value = Slim::Utils::Unicode::utf8on($value);
		}
	};

	return $value;
}

sub _chooser_args {
	my ($params) = @_;

	my $track;
	my $trackId = $params->{track_id};

	if ( defined $trackId && $trackId =~ /^\d+$/ ) {
		$track = Slim::Schema->find('Track', $trackId);
	}

	$track ||= Slim::Schema->objectForUrl($params->{url})
		if $params->{url};

	if ( !$track && $params->{player} ) {
		my $client = eval { Slim::Player::Client::getClient($params->{player}) };

		if ($client) {
			my $song = eval { $client->playingSong };
			$track = $song->track if $song && eval { $song->track };

			if ( !$track ) {
				my $status = eval {
					Slim::Control::Request::executeRequest(
						$client,
						['status', 0, 10, 'tags:title,artist,album,url'],
					);
				};

				if ($status && !$status->isStatusError) {
					my $loop = $status->getResult('playlist_loop');
					my $index = $status->getResult('playlist_cur_index');
					my $item;

					if ( ref $loop eq 'ARRAY' && @$loop ) {
						foreach my $candidate (@$loop) {
							if ( defined $index && defined $candidate->{'playlist index'}
								&& $candidate->{'playlist index'} eq $index ) {
								$item = $candidate;
								last;
							}
						}

						$item ||= $loop->[0];
					}

					if ($item) {
						$params->{title}  = $item->{title}  if !defined $params->{title}  || $params->{title} eq '';
						$params->{artist} = $item->{artist} if !defined $params->{artist} || $params->{artist} eq '';
						$params->{album}  = $item->{album}  if !defined $params->{album}  || $params->{album} eq '';
						$params->{url}    = $item->{url}    if !defined $params->{url}    || $params->{url} eq '';
						$params->{track_id} = $item->{id}   if defined $item->{id};
						$track = Slim::Schema->find('Track', $item->{id}) if defined $item->{id};
					}
				}
			}
		}
	}

	my $original = {
		title    => _decode_param($params->{title}),
		artist   => _decode_param($params->{artist}),
		album    => _decode_param($params->{album}),
		duration => _decode_param($params->{duration}),
		url      => $params->{url},
		track_id => $trackId,
	};

	if ($track) {
		$original->{track}    = $track;
		$original->{track_id} = $track->id;
		$original->{url}      = $track->url;
		$original->{title}    ||= $track->title;
		$original->{artist}   ||= $track->artistName;
		$original->{album}    ||= $track->albumname;
		$original->{duration} ||= $track->secs;
	}

	my $titleOverride  = _trim_param(_decode_param($params->{title}));
	my $artistOverride = _trim_param(_decode_param($params->{artist}));
	my $albumOverride  = _trim_param(_decode_param($params->{album}));
	my $durationOverride = _trim_param(_decode_param($params->{duration}));

	my %lookup = %$original;
	$lookup{title}  = $titleOverride  if $titleOverride ne '';
	$lookup{artist} = $artistOverride if $artistOverride ne '';
	$lookup{album}  = $albumOverride  if $albumOverride ne '';
	$lookup{duration} = $durationOverride if $durationOverride ne '';

	return ($original, \%lookup);
}

sub _track_cache_key {
	my $args = shift || {};
	my $key = join "\x1f",
		$args->{track_id} || '',
		$args->{url} || '',
		$args->{title} || '',
		$args->{artist} || '',
		$args->{album} || '';
	utf8::encode($key);
	return md5_hex($key);
}

sub _candidate_cache_key {
	my $args = shift || {};
	return 'mai_lyrics_candidates_' . ($cache->get('mai_lyrics_track_epoch') || 'initial') . '_' . _track_cache_key($args);
}

sub _candidate_cache_get {
	my $args = shift || {};
	my $raw = $cache->get(_candidate_cache_key($args));
	return unless defined $raw && !ref $raw;
	my $data = eval { JSON::PP->new->utf8->decode($raw) };
	return unless $data && ref $data eq 'HASH' && ref $data->{candidates} eq 'ARRAY';
	return $data;
}

sub _candidate_cache_store {
	my ($args, $candidates, $saveArgs) = @_;
	return unless ref $candidates eq 'ARRAY';

	my $save = { %{ $saveArgs || {} } };
	delete $save->{track};

	my $raw = eval {
		JSON::PP->new->utf8->encode({
			candidates => $candidates,
			save_args  => $save,
			created    => time(),
		});
	};
	return unless defined $raw;
	$cache->set(_candidate_cache_key($args), $raw, 6 * 3600);
}

sub _new_candidate_session {
	my ($candidates, $saveArgs) = @_;

	my $session = md5_hex(rand() . time() . $$);
	my $save = { %{ $saveArgs || {} } };
	delete $save->{track};

	my $sessionData = JSON::PP->new->utf8->encode({
		candidates => $candidates || [],
		save_args  => $save,
		created    => time(),
	});

	$cache->set("mai_lyrics_chooser_$session", $sessionData, $CANDIDATE_SESSION_EXPIRES);
	return $session;
}

sub _send_json {
	my ($httpClient, $response, $data, $status) = @_;

	my $body = eval { JSON::PP->new->utf8->encode($data) } || '{}';

	$response->code($status || 200);
	$response->content_type('application/json; charset=utf-8');
	$response->header('Cache-Control' => 'no-cache');
	$response->header('Content-Length' => length($body));
	$response->header('Connection' => 'close');

	require Slim::Web::HTTP;
	Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$body)
		if $httpClient->connected;
}

sub _candidate_hash {
	my $candidate = shift || {};
	my $key = join "\x1f",
		$candidate->{source} || '',
		$candidate->{title}  || '',
		$candidate->{artist} || '',
		$candidate->{lyrics} || '';
	utf8::encode($key);
	return md5_hex($key);
}

sub _clean_candidate_text {
	my $text = shift;
	return '' unless defined $text;
	return '' if ref $text;
	$text = '' if $text =~ /^HASH\(0x[0-9a-f]+\)$/i;
	return $text;
}

sub _candidate_lrc_lines {
	my $lyrics = shift;
	return [] unless defined $lyrics && !ref $lyrics && $lyrics =~ /\S/;

	my @lines;
	foreach my $raw (split /\r?\n/, $lyrics) {
		my @times;
		while ( $raw =~ /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g ) {
			my ($min, $sec, $frac) = ($1, $2, $3);
			my $f = 0;
			if ( defined $frac ) {
				my $len = length($frac);
				$f = $frac / ($len == 3 ? 1000 : $len == 2 ? 100 : 10);
			}
			push @times, $min * 60 + $sec + $f;
		}
		next unless @times;
		my $text = $raw;
		$text =~ s/\[[^\]]*\]//g;
		$text =~ s/^\s+|\s+$//g;
		push @lines, map { { time => $_, text => $text } } @times;
	}
	@lines = sort { $a->{time} <=> $b->{time} } @lines;
	return \@lines;
}

sub _candidate_json {
	my $candidate = shift || {};
	return {
		hash    => _candidate_hash($candidate),
		index   => $candidate->{index},
		source  => $candidate->{source},
		title   => $candidate->{title},
		artist  => $candidate->{artist},
		album   => $candidate->{album},
		synced  => $candidate->{synced} ? 1 : 0,
		lyrics  => _clean_candidate_text($candidate->{lyrics}),
		preview => _clean_candidate_text($candidate->{preview}),
		lines   => $candidate->{synced} ? _candidate_lrc_lines(_clean_candidate_text($candidate->{lyrics})) : [],
	};
}

sub _store_search_state {
	my ($session, $state) = @_;

	my $data = JSON::PP->new->utf8->encode($state);
	$cache->set("mai_lyrics_chooser_$session", $data, $CANDIDATE_SESSION_EXPIRES);

	return 1;
}

sub _load_search_state {
	my $session = shift;
	return unless defined $session;

	my $cached = $cache->get("mai_lyrics_chooser_$session");
	return unless defined $cached && !ref $cached;

	my $state = eval { JSON::PP->new->utf8->decode($cached) };
	return unless $state && ref $state eq 'HASH';

	return $state;
}

sub _search_snapshot {
	my ($session, $state) = @_;

	$state ||= {};
	my @out = map { _candidate_json($_) } @{ $state->{candidates} || [] };

	return {
		search_id => $session,
		session   => $session,
		candidates => \@out,
		done      => $state->{done} ? 1 : 0,
		cancelled => $state->{cancelled} ? 1 : 0,
		progress  => $state->{progress} || 0,
		total     => $state->{total} || 0,
		found     => scalar @out,
		elapsed   => $state->{created} ? time() - $state->{created} : 0,
	};
}

sub _lyricsApi {
	my ($httpClient, $response) = @_;

	return unless $httpClient->connected;

	my $request = $response->request;
	my $path    = $request->uri->path;

	$log->debug("Lyrics chooser API request: $path");

	my %params;
	my @pairs = eval { $request->uri->query_form };
	if (@pairs) {
		for (my $i = 0; $i < @pairs; $i += 2) {
			$params{$pairs[$i]} = $pairs[$i + 1];
		}
	}

	if ( $path =~ m{/lyrics/script} ) {
		return _handle_lyrics_script($httpClient, $response, $request, \%params);
	}

	if ( $path =~ m{/lyrics/save-preview} ) {
		return _handle_save_preview($httpClient, $response, \%params);
	}

	if ( $path =~ m{/lyrics/select} ) {
		return _handle_lyrics_select($httpClient, $response, \%params);
	}

	if ( $path =~ m{/lyrics/search} ) {
		return _handle_lyrics_search($httpClient, $response, \%params);
	}

	if ( $path =~ m{/lyrics/cancel} ) {
		return _handle_lyrics_cancel($httpClient, $response, \%params);
	}

	return _handle_lyrics_candidates($httpClient, $response, \%params);
}

sub _handle_lyrics_script {
	my ($httpClient, $response, $request, $params) = @_;

	my $payload = {};
	if ( ($request->method || '') eq 'POST' && defined $request->content ) {
		$payload = eval { JSON::PP->new->utf8->decode($request->content) } || {};
	}

	my $action = $payload->{action} || $params->{action} || '';
	my $class = 'Plugins::MusicArtistInfo::Lyrics::PerlScripts';

	if ( $action eq 'template' ) {
		return _send_json($httpClient, $response, {
			content => $class->default_script_content,
		});
	}

	my $id = $payload->{id} || $params->{id} || '';
	my $old_name;
	if ( $action eq 'get' || $action eq 'delete' || $action eq 'save' ) {
		if ( $id =~ /^PerlScripts:(.+)$/ ) {
			$old_name = $1;
		}
	}

	if ( $action eq 'get' ) {
		return _send_json($httpClient, $response, { error => 'Invalid script id' }, 400)
			unless defined $old_name;
		my $result = $class->read_script($old_name);
		return _send_json($httpClient, $response, $result, $result->{error} ? 404 : 200);
	}

	if ( $action eq 'delete' ) {
		return _send_json($httpClient, $response, { error => 'Invalid script id' }, 400)
			unless defined $old_name;
		my $result = $class->delete_script($old_name);
		if ( !$result->{error} ) {
			_update_script_pref_id($id, undef);
		}
		return _send_json($httpClient, $response, $result, $result->{error} ? 400 : 200);
	}

	if ( $action eq 'save' ) {
		my $name    = $payload->{filename} || $params->{filename} || '';
		my $content = defined $payload->{content} ? $payload->{content}
			: defined $params->{content} ? $params->{content} : '';
		my $result = $class->save_script($old_name, $name, $content);
		if ( !$result->{error} ) {
			if ( defined $id && $id ne '' ) {
				_update_script_pref_id($id, $result->{id});
			}
			else {
				_append_script_pref_id($result->{id});
			}
		}
		return _send_json($httpClient, $response, $result, $result->{error} ? 400 : 200);
	}

	return _send_json($httpClient, $response, { error => 'Unknown action' }, 400);
}

sub _script_pref_items {
	my $key = shift;
	my $raw = $prefs->get($key);
	my $items = defined $raw && $raw ne '' ? eval { JSON::PP->new->decode($raw) } : [];
	return ref $items eq 'ARRAY' ? $items : [];
}

sub _save_script_pref_items {
	my ($key, $items) = @_;
	$prefs->set($key, JSON::PP->new->encode($items));
}

sub _update_script_pref_id {
	my ($old, $new) = @_;

	foreach my $key (qw(lyricsSourceOrder lyricsSourceDisabled)) {
		my @items = _script_pref_items($key);
		my %seen;
		my @updated;
		foreach my $item (@items) {
			my $id = ref $item eq 'HASH' ? $item->{id} : $item;
			if ( defined $id && $id eq $old ) {
				if ( defined $new && $new ne '' ) {
					if ( ref $item eq 'HASH' ) {
						$item->{id} = $new;
						push @updated, $item;
					}
					else {
						push @updated, $new;
					}
				}
			}
			else {
				push @updated, $item;
			}
		}
		@updated = grep { !$seen{ ref $_ eq 'HASH' ? $_->{id} : $_ }++ } @updated;
		_save_script_pref_items($key, \@updated);
	}
}

sub _append_script_pref_id {
	my $id = shift;
	return unless defined $id && $id ne '';
	my @items = _script_pref_items('lyricsSourceOrder');
	return if grep { (ref $_ eq 'HASH' ? $_->{id} : $_) eq $id } @items;
	push @items, $id;
	_save_script_pref_items('lyricsSourceOrder', \@items);
}

sub lyrics_source_options {
	my @out = (
		{
			id    => 'TagLyrics',
			label => string('PLUGIN_MUSICARTISTINFO_LYRICS_SOURCE_TAG'),
			desc  => string('PLUGIN_MUSICARTISTINFO_LYRICS_SOURCE_TAG_DESC'),
		},
		{
			id    => 'LocalLyrics',
			label => string('PLUGIN_MUSICARTISTINFO_LYRICS_SOURCE_LOCAL'),
			desc  => string('PLUGIN_MUSICARTISTINFO_LYRICS_SOURCE_LOCAL_DESC'),
		},
	);

	foreach my $id (@{$prefs->get('lyricsProviders') || $lyricsProviderPipeline}) {
		next if $id eq 'PerlScripts';
		next if $id =~ /^Genius/;
		next unless $lyricsProvider->{$id};
		my $label = $lyricsProviderLabels{$id} || $id;
		if ( $id eq 'GeniusNoDot' ) {
			$label = string('PLUGIN_MUSICARTISTINFO_LYRICS_SOURCE_GENIUS_NODOT');
		}
		my $desc = $id eq 'MAILyricsAPI' ? string('PLUGIN_MUSICARTISTINFO_LYRICS_SOURCE_MAI_DESC')
			: $id eq 'Genius' ? string('PLUGIN_MUSICARTISTINFO_LYRICS_SOURCE_GENIUS_DESC')
			: $id eq 'GeniusNoDot' ? string('PLUGIN_MUSICARTISTINFO_LYRICS_SOURCE_GENIUS_NODOT_DESC')
			: $label;
		push @out, { id => $id, label => $label, desc => $desc };
	}

	push @out, map { { %$_, script => 1 } } @{ Plugins::MusicArtistInfo::Lyrics::PerlScripts->script_sources };

	return \@out;
}


sub _handle_save_preview {
	my ($httpClient, $response, $params) = @_;

	my $track;
	if ( defined $params->{track_id} && $params->{track_id} =~ /^\d+$/ ) {
		$track = Slim::Schema->find('Track', $params->{track_id});
	}
	elsif ( $params->{url} ) {
		$track = eval { Slim::Schema->objectForUrl($params->{url}) };
	}
	elsif ( $params->{player} ) {
		my $client = eval { Slim::Player::Client::getClient($params->{player}) };
		my $song = $client ? eval { $client->playingSong } : undef;
		$track = $song ? eval { $song->track } : undef;
	}

	if ( !$track ) {
		foreach my $client ( Slim::Player::Client::clients() ) {
			my $song = eval { $client->playingSong };
			next unless $song;
			$track = eval { $song->track };
			last if $track;
		}
	}

	unless ($track) {
		return _send_json($httpClient, $response, { error => 'No current track' }, 400);
	}

	my $language = defined $params->{language}
		? $params->{language}
		: $prefs->get('templateLanguage') || 'lms';

	my $target = Plugins::MusicArtistInfo::Lyrics::SaveTarget->build($track, {
		template_language => $language,
		path_format     => defined $params->{path_format}
			? $params->{path_format}
			: $prefs->get('lyricsSavePathFormat'),
		file_format     => defined $params->{file_format}
			? $params->{file_format}
			: $prefs->get('lyricsSaveFileNameFormat'),
		lms_file_format => $prefs->get('lyricsFileNameFormat') || 'FILE',
	});

	return _send_json($httpClient, $response, $target);
}

sub _handle_lyrics_candidates {
	my ($httpClient, $response, $params) = @_;

	my ($saveArgs, $lookupArgs) = _chooser_args($params);

	unless ( defined $lookupArgs->{title} && $lookupArgs->{title} ne ''
		&& defined $lookupArgs->{artist} && $lookupArgs->{artist} ne '' ) {
		return _send_json($httpClient, $response, { error => 'Missing title or artist' }, 400);
	}

	if ( $params->{async} ) {
		return _handle_lyrics_candidates_async($httpClient, $response, $saveArgs, $lookupArgs);
	}

	my $cached = _candidate_cache_get($lookupArgs);
	if ($cached) {
		my $session = _new_candidate_session($cached->{candidates}, $cached->{save_args} || $saveArgs);
		return _send_json($httpClient, $response, {
			session    => $session,
			candidates => [ map { _candidate_json($_) } @{ $cached->{candidates} } ],
			cached     => 1,
		});
	}

	my $sent = 0;

	my $finish = sub {
		my $candidates = shift;

		return if $sent++;
		$log->debug('Lyrics chooser sending ' . scalar(@{ $candidates || [] }) . ' candidates');
		return unless $httpClient->connected;

		_candidate_cache_store($lookupArgs, $candidates, $saveArgs);
		my $session = _new_candidate_session($candidates, $saveArgs);

		my @out = map { _candidate_json($_) } @$candidates;

		_send_json($httpClient, $response, {
			session    => $session,
			candidates => \@out,
		});
	};

	my $token = {};
	my $timer = sub {
		$finish->([]);
	};
	Slim::Utils::Timers::setTimer($token, time() + $CANDIDATE_TIMEOUT + 5, $timer);

	collectCandidates($lookupArgs, sub {
		Slim::Utils::Timers::killTimers($token, $timer);
		$finish->(shift || []);
	});
}

sub _handle_lyrics_candidates_async {
	my ($httpClient, $response, $saveArgs, $lookupArgs) = @_;

	my $cached = _candidate_cache_get($lookupArgs);
	if ($cached) {
		my $session = md5_hex(rand() . time() . $$);
		my $save = { %{ $cached->{save_args} || $saveArgs || {} } };
		delete $save->{track};
		my $state = {
			candidates => $cached->{candidates},
			save_args  => $save,
			created    => time(),
			done       => 1,
			cancelled  => 0,
			progress   => scalar @{ $cached->{candidates} },
			total      => scalar @{ $cached->{candidates} },
			found      => scalar @{ $cached->{candidates} },
		};
		_store_search_state($session, $state);
		return _send_json($httpClient, $response, _search_snapshot($session, $state));
	}

	my $session = md5_hex(rand() . time() . $$);
	my $save = { %$saveArgs };
	delete $save->{track};

	my $state = {
		candidates => [],
		save_args  => $save,
		created    => time(),
		done       => 0,
		cancelled  => 0,
		progress   => 0,
		total      => 0,
		found      => 0,
	};

	_store_search_state($session, $state);

	my %seen;

	my $addCandidate = sub {
		my $candidate = shift;
		return unless $candidate && ref $candidate eq 'HASH';

		my $hash = _candidate_hash($candidate);
		return if $seen{$hash}++;

		my $current = _load_search_state($session);
		return unless $current;
		return if $current->{cancelled} || $current->{done};

		push @{ $current->{candidates} }, $candidate;
		$current->{found} = scalar @{ $current->{candidates} };
		$current->{progress} = $state->{progress} || 0;
		$current->{total} = $state->{total} || 0;

		_store_search_state($session, $current);
	};

	my $updateProgress = sub {
		my $progress = shift || {};

		my $current = _load_search_state($session);
		return unless $current;
		return if $current->{cancelled} || $current->{done};

		$current->{progress} = $progress->{done} || 0;
		$current->{total}    = $progress->{total} || 0;
		$current->{found}    = $progress->{found}
			|| scalar @{ $current->{candidates} || [] };

		$state->{progress} = $current->{progress};
		$state->{total}    = $current->{total};

		_store_search_state($session, $current);
	};

	collectCandidates($lookupArgs, sub {
		my $final = shift || [];

		_candidate_cache_store($lookupArgs, $final, $saveArgs);

		my $current = _load_search_state($session);
		return unless $current;
		return if $current->{cancelled};

		$current->{candidates} = $final;
		$current->{done}       = 1;
		$current->{progress}   = $current->{total} || scalar @$final;
		$current->{found}      = scalar @$final;

		_store_search_state($session, $current);
	}, {
		on_candidate => $addCandidate,
		on_progress  => $updateProgress,
	});

	my $current = _load_search_state($session) || $state;

	_send_json($httpClient, $response, _search_snapshot($session, $current));
}

sub _handle_lyrics_search {
	my ($httpClient, $response, $params) = @_;

	my $session = $params->{search_id} || '';

	unless ( $session =~ /^[a-f0-9]{32}$/i ) {
		return _send_json($httpClient, $response, { error => 'Invalid request' }, 400);
	}

	my $state = _load_search_state($session);
	unless ($state) {
		return _send_json($httpClient, $response, { error => 'Search result expired, please search again' }, 410);
	}

	_send_json($httpClient, $response, _search_snapshot($session, $state));
}

sub _handle_lyrics_cancel {
	my ($httpClient, $response, $params) = @_;

	my $request = $response->request;
	my $safe = lc($request->header('X-Requested-With') || '') eq 'xmlhttprequest';

	unless ($safe) {
		eval {
			require Slim::Web::HTTP::CSRF;
			$safe = Slim::Web::HTTP::CSRF->isRequestCSRFSafe($request, $response, {}, undef);
		};
	}

	unless ($safe) {
		return _send_json($httpClient, $response, { error => 'Forbidden' }, 403);
	}

	my $session = $params->{search_id} || '';

	unless ( $session =~ /^[a-f0-9]{32}$/i ) {
		return _send_json($httpClient, $response, { error => 'Invalid request' }, 400);
	}

	my $state = _load_search_state($session);
	unless ($state) {
		return _send_json($httpClient, $response, { error => 'Search result expired, please search again' }, 410);
	}

	$state->{cancelled} = 1;
	$state->{done}      = 1;
	$state->{progress}  = $state->{total} || $state->{progress} || 0;

	_store_search_state($session, $state);

	_send_json($httpClient, $response, _search_snapshot($session, $state));
}

sub _handle_lyrics_select {
	my ($httpClient, $response, $params) = @_;

	my $request = $response->request;
	my $safe = lc($request->header('X-Requested-With') || '') eq 'xmlhttprequest';

	unless ($safe) {
		eval {
			require Slim::Web::HTTP::CSRF;
			$safe = Slim::Web::HTTP::CSRF->isRequestCSRFSafe($request, $response, {}, undef);
		};
	}

	unless ($safe) {
		return _send_json($httpClient, $response, { error => 'Forbidden' }, 403);
	}

	my $session = $params->{session};
	my $index   = $params->{index};
	my $hash    = $params->{hash};

	unless ( defined $session && $session =~ /^[a-f0-9]{32}$/i
		&& ( ( defined $index && $index =~ /^\d+$/ )
			|| ( defined $hash && $hash =~ /^[a-f0-9]{32}$/i ) ) ) {
		return _send_json($httpClient, $response, { error => 'Invalid request' }, 400);
	}

	my $cached = $cache->get("mai_lyrics_chooser_$session");
	my $data;
	if ( defined $cached && !ref $cached ) {
		$data = eval { JSON::PP->new->utf8->decode($cached) };
	}

	unless ( $data && ref $data eq 'HASH' && $data->{candidates} && ref $data->{candidates} eq 'ARRAY' ) {
		return _send_json($httpClient, $response, { error => 'Search result expired, please search again' }, 410);
	}

	my $candidate;

	if ( defined $hash ) {
		foreach my $item ( @{ $data->{candidates} } ) {
			if ( ref $item eq 'HASH' && lc(_candidate_hash($item)) eq lc($hash) ) {
				$candidate = $item;
				last;
			}
		}
	}
	else {
		$candidate = $data->{candidates}->[$index];
	}

	unless ( $candidate && ref $candidate eq 'HASH' && defined $candidate->{lyrics} ) {
		return _send_json($httpClient, $response, { error => 'Invalid candidate' }, 400);
	}

	my $save = { %{ $data->{save_args} || {} } };

	if ( $save->{track_id} && $save->{track_id} =~ /^\d+$/ && !$save->{track} ) {
		$save->{track} = Slim::Schema->find('Track', $save->{track_id});
	}

	if ( !$save->{track} && $save->{url} ) {
		$save->{track} = Slim::Schema->objectForUrl($save->{url});
	}

	$chosenCache->save($save, $candidate->{lyrics});
	_cacheLyrics($save, $candidate->{lyrics});

	my $sidecar = _save_lyrics_next_to_song($save, $candidate->{lyrics}, undef, 1);

	_send_json($httpClient, $response, {
		lyrics  => _clean_candidate_text($candidate->{lyrics}),
		source  => $candidate->{source} || '',
		cached  => 1,
		sidecar => $sidecar && $sidecar->{file} ? $sidecar->{file} : '',
	});
}

sub _renderLyricsResponse {
	my ($lyrics, $request, $args) = @_;

	my $client = $request->client();

	$lyrics = Plugins::MusicArtistInfo::Text->ensure_text($lyrics);
	$lyrics = Plugins::MusicArtistInfo::Lyrics::Processor->process($lyrics);

	$lyrics =~ s/\\n/\n/g;
	$lyrics =~ s/\r\n/\n/g;
	$lyrics =~ s/\n\r/\n/g;
	$lyrics =~ s/\r/\n/g;

	$lyrics = Plugins::MusicArtistInfo::Parser::LRC->strip($lyrics, $request->getParam('timestamps') && !$args->{radioUrl});

	$request->addResult('lyrics', $lyrics) if $lyrics;
	$request->addResult('error', cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND')) unless $lyrics;
	$request->addResult('title', $args->{title}) if $args->{title};
	$request->addResult('artist', $args->{artist}) if $args->{artist};
}

sub updateLyricsProviders {
	my ($class) = @_;

	Slim::Utils::Timers::killTimers($class, \&updateLyricsProviders);

	Plugins::MusicArtistInfo::API->getLyricsProviders(sub {
		my $result = shift;

		if ($result && ref $result && ref $result eq 'HASH' && $result->{lyricsProviders} && ref $result->{lyricsProviders} eq 'ARRAY') {
			my @lyricsProviders = Slim::Utils::Misc::uniq(grep {
				$_ ne 'PerlScripts' && $lyricsProvider->{$_};
			} @{$result->{lyricsProviders}});

			$prefs->set('lyricsProviders', \@lyricsProviders) if @lyricsProviders;
		}

		Slim::Utils::Timers::setTimer($class, time() + 23*3600 + rand(3600), \&updateLyricsProviders);
	});
}


1;