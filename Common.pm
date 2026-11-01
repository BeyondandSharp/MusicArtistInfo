package Plugins::MusicArtistInfo::Common;

use strict;

use Exporter::Lite;
use File::Spec::Functions qw(catdir);
use JSON::PP ();
use JSON::XS;
use List::Util qw(min);
use URI::Escape qw(uri_escape uri_escape_utf8);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

BEGIN {
	use Slim::Music::Artwork;
	use constant CAN_IMAGEPROXY => (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0);
	use constant CAN_ONLINE_LIBRARY => (Slim::Utils::Versions->compareVersions($::VERSION, '8.0.0') >= 0);
	use constant CAN_LMS_ARTIST_ARTWORK => (Slim::Utils::Versions->compareVersions($::VERSION, '9.1.0') >= 0 && Slim::Music::Artwork->can('generateImageId')) ? 1 : 0;
	use constant CAN_LMS_WORKS => (Slim::Utils::Versions->compareVersions($::VERSION, '9.1.0') >= 0 ? 1 : 0);
	use constant CAN_LMS_IS_DIR_WRITABLE => (Slim::Utils::Versions->compareVersions($::VERSION, '9.2.0') >= 0 && Slim::Utils::Misc->can('isDirWritable') ? 1 : 0);
	use constant CAN_LMS_CAN_WEBLINK => (Slim::Utils::Versions->compareVersions($::VERSION, '9.0.0') >= 0 && Slim::Utils::Misc->can('canFollowWeblinks') ? 1 : 0);
	use constant CAN_DISCOGS => 0;
	use constant CAN_LFM => 1;
	use constant CLICOMMAND => 'musicartistinfo';

	use constant REVIEW_TYPE_ALBUM => 'album';
	use constant REVIEW_TYPE_WORK => 'work';
	use constant REVIEW_TYPE_TRACK => 'track';

	use Exporter::Lite;
	our @EXPORT_OK = qw( CLICOMMAND CAN_IMAGEPROXY CAN_LMS_ARTIST_ARTWORK CAN_LMS_WORKS CAN_ONLINE_LIBRARY CAN_DISCOGS CAN_LFM
		CAN_LMS_IS_DIR_WRITABLE CAN_LMS_CAN_WEBLINK REVIEW_TYPE_ALBUM REVIEW_TYPE_WORK REVIEW_TYPE_TRACK
		isDirWritable validateLanguage
	 );
}

my $contentLanguages = {
	CS => 'cs',
	DA => 'da',
	DE => 'de',
	EN => 'en',
	ES => 'es',
	FR => 'fr',
	HU => 'hu',
	IT => 'it',
	NL => 'nl',
	PL => 'pl',
	PT => 'pt',
	SV => 'sv',
	ZH_CN	=> 'zh'
};

my $cache = Slim::Utils::Cache->new();
my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.musicartistinfo',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_MUSICARTISTINFO',
} );
my $prefs = preferences('plugin.musicartistinfo');

my $ua;
my %killWords = ();

# delay requests in case of 429s
my $delay = 0;
use constant MAX_DELAY => 30;

sub validateLanguage {
	my ($client, $lang) = @_;
	return $lang || $contentLanguages->{$prefs->get('preferredLanguage')} || cstring($client, 'PLUGIN_MUSICARTISTINFO_WIKIPEDIA_LANGUAGE');
}

sub storeContentLanguageStrings {
	Slim::Utils::Strings::storeExtraStrings([{
		strings => $contentLanguages,
		token   => 'PLUGIN_MUSICARTISTINFO_WIKIPEDIA_LANGUAGE',
	}]);
}

sub getContentLanguages {
	return [ keys %$contentLanguages ];
}

sub getKillWords { \%killWords }

sub updateKillWords {
	my $class = shift;

	Plugins::MusicArtistInfo::API->getKillwords(
		sub {
			my $killWordsList = shift;

			if ($killWordsList && ref $killWordsList eq 'HASH' && scalar @{$killWordsList->{killWords} || []}) {
				%killWords = map { $_ => 1 } @{$killWordsList->{killWords}};
			}
		},
		{
			cache => 1,
		}
	);
}


sub cleanupAlbumName {
	my $album = shift;

	# keep a backup copy, in case cleaning would wipe all of it
	my $fullAlbum = $album;

	main::INFOLOG && $log->info("Cleaning up album name: '$album'");

	$album = '' if $killWords{lc($album)};

	# remove everything between (), {} or []... But don't for PG's eponymous first four albums :-)
	$album =~ s/(?<!^)[(\[{].*?[}\])]//g if $album !~ /Peter Gabriel .*\b(?:[1-4]|Car|Scratch|Melt|Security)\b/i && $album !~ /beatles.*white album/i;

	# remove stuff like "CD02", "1 of 2"
	$album =~ s/\b(disc \d+ of \d+)\b//ig;
	# would break Justin Timberlake's "The 20/20 Experience"
	# $album =~ s/\d+\/\d+//ig;
	$album =~ s/\b(cd\s*\d+|\d+ of \d+|disc \d+)\b//ig;
	$album =~ s/- live\b//i;

	# remove additional information added by the Radio Now Playing plugin
	$album =~ s/\|.*//;

	# remove trailing non-word characters
	$album =~ s/[\s\W]{2,}$//;
	$album =~ s/\s*$//;
	$album =~ s/^\s*//;
	$album =~ s/(\s)\s+/$1/g;

	main::INFOLOG && $log->info("Album name cleaned up:  '$album'");

	return $album || $fullAlbum;
}

sub matchAlbum {
	my ($class, $wanted, $candidate, $strict) = @_;

	my $artist = Slim::Utils::Text::ignoreCaseArticles($wanted->{artist}, 1);
	my $album  = Slim::Utils::Text::ignoreCaseArticles($wanted->{album}, 1);

	return if !$artist || !$album;

	my $albumLC = lc( $wanted->{album} );
	my $artist2 = $wanted->{artist};
	$artist2 =~ s/&/and/g;
	$artist2 = Slim::Utils::Text::ignoreCaseArticles($artist2, 1);

	my $artistName = Slim::Utils::Text::ignoreCaseArticles($candidate->{artist}, 1);

	if ( $artistName =~ /\Q$artist\E/i || $artistName =~ /\Q$artist2\E/i ) {
		if ( lc($candidate->{album}) eq $albumLC ) {
			return 1;
		}

		if ( !$strict && Slim::Utils::Text::ignoreCaseArticles($candidate->{album}, 1) =~ /\Q$album\E/i ) {
			return 1;
		}
	}

	return;
}

sub getMetadataFor {
	my ($client, $track) = @_;

	return unless $track && $track->isRemoteURL && (my $url = $track->url);

	my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);

	if ( $handler && $handler->can('getMetadataFor') ) {
		if (my $meta = $handler->getMetadataFor( $client, $url )) {
			return $meta;
		}
	}

	return {};
}

sub getTrackAndRadioUrl {
	my ($client, $args) = @_;

	$args ||= {};
	return unless $args->{track} || $client;

	my $track = $args->{track} || Slim::Player::Playlist::track($client);

	$args->{radioUrl} = $track->url if $track && Slim::Music::Info::isHTTPURL($track->url);

	return $track;
}

my @HEADER_DATA = map {
	# s/=*$|\s//sg;
	MIME::Base64::decode_base64($_);
} <Plugins::MusicArtistInfo::Common::DATA>;

$HEADER_DATA[CAN_DISCOGS] = eval { decode_json($HEADER_DATA[CAN_DISCOGS]) };

sub isDirWritable {
	my ($folder) = @_;

	return unless $folder;

	if (CAN_LMS_IS_DIR_WRITABLE) {
		return Slim::Utils::Misc::isDirWritable($folder);
	}

	# this fallback isn't safe, in particular not on Windows. But good enough for most.
	return -d $folder && (main::ISWINDOWS || -w _);
}

sub imageInFolder {
	my ($folder, @names) = @_;

	return unless $folder && @names;

	main::INFOLOG && $log->info("Trying to find artwork in $folder");

	return fileInFolder($folder, ['jpg', 'JPG', 'jpeg', 'JPEG', 'png', 'PNG', 'gif', 'GIF'], @names);
}

sub fileInFolder {
	my ($folder, $extensions, @names) = @_;

	my $file;
	my %seen;

	foreach my $name (@names) {
		next if $seen{$name}++;
		foreach my $ext (@$extensions) {
			my $candidate = catdir($folder, $name . ".$ext");

			if (-f $candidate) {
				$file = $candidate;
				last;
			}
		}

		last if $file;
	}

	return $file;
}

sub getLocalnameVariants {
	my ($name) = @_;

	# Remove wildcards and other stuff potentially conflicting with file system limitations
	# For whatever reason those aren't removed by S::U::Misc::cleanupFilename()
	$name =~ s/[:?*]//g;

	my @candidates = map {
		(
			$_,
			Slim::Utils::Unicode::utf8encode($_),
			Slim::Utils::Text::ignorePunct($_)
		);
	} (Slim::Utils::Misc::cleanupFilename($name), $name);
	push @candidates, Slim::Utils::Unicode::utf8toLatin1Transliterate($candidates[-1]);

	# de-dupe results
	my %seen;
	return [ grep { !$seen{$_}++ } @candidates ];
}

sub getExternalLinks {
	my ($client, $data, $release_mbid) = @_;

	return '' unless $data && ref $data eq 'HASH';

	my $linkList = '';
	foreach my $id (sort { $a cmp $b } keys %$data) {
		my $url = $data->{$id};
		next unless $url && $url =~ m{^(https?://)};

		# make sure we don't have a trailing slash
		$url =~ s{/$}{};

		# for some legacy reasons, we use 'url' as a key for the main Wikipedia URL
		if ($id eq 'url') {
			$id = 'wikipedia' if $url =~ /wikipedia.org/;
			$id = 'wikidata' if $url =~ /wikidata.org/;
			$id = 'wiki' if $url =~ /wiki\.org/;

			next if $id eq 'url';   # we have a separate link for that
		}

		my $label = 'PLUGIN_MUSICARTISTINFO_' . uc($id);
		my $label = Slim::Utils::Strings::stringExists($label)
			? cstring($client, $label)
			: ucfirst($id);

		$linkList .= '<li><a href="' . $url . '" target="_blank">' . $label . '</a></li>';
	}

	if ($release_mbid) {
		# add MusicBrainz release link (we might only have the release group link)
		my $mbUrl = 'https://musicbrainz.org/release/' . $release_mbid;
		$linkList .= '<li><a href="' . $mbUrl . '" target="_blank">' . cstring($client, 'PLUGIN_MUSICARTISTINFO_MUSICBRAINZ_RELEASE') . '</a></li>';
	}

	return $linkList ? sprintf("<h4>%s</h4><ul class=\"maiExternalLinksList\">%s</ul>", cstring($client, 'PLUGIN_MUSICARTISTINFO_READ_MORE'), $linkList) : '';
}


sub call {
	my ($class, $url, $cb, $params) = @_;

	$url =~ s/\?$//;

	main::INFOLOG && $log->is_info && $log->info((main::SCANNER ? 'Sync' : 'Async') . ' API call: GET ' . _debug($url) );

	# we can get a list of error codes which we'll ignore in the error messaging - lyrics often end in 404
	my $noWarn = join('|', grep /\d{3}/, @{delete $params->{ignoreError} || []});
	my $wantsError = delete $params->{wantError};

	$params->{timeout} ||= 15;
	my %headers = %{delete $params->{headers} || {}};
	# We must use the "legacy" user agent string to comply with Discogs' TOU.
	$headers{'User-Agent'} = Slim::Utils::Misc::userAgentString('legacy');

	my $cb2 = sub {
		my ($response, $error) = @_;

		main::INFOLOG && $log->is_info && $log->info("Got response from " . _debug($url));
		main::DEBUGLOG && $log->is_debug && $response->code !~ /2\d\d/ && $log->debug(_debug(Data::Dump::dump($response, @_)));

		my $result;

		if ($error) {
			$log->error(sprintf("Failed to call %s: %s", _debug($response->url), $error)) if (!$noWarn || $noWarn !~ /^($noWarn)/) || (main::INFOLOG && $log->is_info) || (main::DEBUGLOG && $log->is_debug);
			$result = {};
			$result->{error} = $error if $wantsError;
		}

		$result ||= eval {
			my $content = $response->can('decoded_content')
				? $response->decoded_content
				: $response->content;

			if ( $response->headers->content_type =~ /xml/ ) {
				require XML::Simple;
				XML::Simple::XMLin( $content );
			}
			elsif ( $response->headers->content_type =~ /json/ ) {
				decode_json( $content );
			}
			else {
				$content;
			}
		};

		$result ||= {};

		if ($@) {
			 $log->error($@);
			 $result->{error} = $@;
		}

		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

		$cb->($result, $response->headers);
	};

	if (main::SCANNER) {
		my $cacheKey = "mai_$url";

		my $cached = $cache->get($cacheKey);
		if ($cached && ref $cached && ref $cached eq 'HTTP::Response') {
			main::INFOLOG && $log->is_info && $log->info("Using cached response for $url");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($cached));

			$cached->header('x-discogs-ratelimit-remaining' => 999) if defined $cached->header('x-discogs-ratelimit-remaining');
			return $cb2->($cached);
		}

		$ua ||= $class->getUA({
			timeout => $params->{timeout}
		});

		# our sometimes outdated HTML::Parser seems to trip over some headers - ignore them...
		$ua->parse_head($url =~ /last\.fm/ ? 0 : 1);

		my $response = $ua->get($url, %headers);

		if ($response->code == 429) {
			$delay = $delay ? min($delay*2, MAX_DELAY) : 5;
			$log->error("Hit rate limiter - delay next call by $delay seconds...");
			sleep $delay;
		}
		else {
			$cache->set($cacheKey, $response, $params->{expires} || '1d') if $response->code == 200;
			$delay = 0;
		}

		$cb2->($response);
	}
	else {
		Slim::Networking::SimpleAsyncHTTP->new(
			$cb2,
			$cb2,
			$params
		)->get($url, %headers);
	}
}

# POST a JSON body, as a small companion to call().  The response body is
# decoded as JSON and handed to the callback: $cb->($data, $headers).
# Transport and HTTP errors are reported as { error => "..." } in $data (unless
# wantError => 0 is requested), because callers like the translation client
# need a string to show/decide on.
#
# The request body and the headers are never logged: they contain lyrics and
# credentials.
sub post_json {
	my ($class, $url, $opts, $cb) = @_;

	$opts ||= {};
	$cb   ||= sub {};
	$url  = '' unless defined $url;

	my $wantError = exists $opts->{wantError} ? delete $opts->{wantError} : 1;
	$wantError = 1 if !defined $wantError;
	my $timeout = $opts->{timeout} || 15;

	my $body;
	if ( !defined $opts->{json} ) {
		$body = '';
	}
	elsif ( ref $opts->{json} ) {
		$body = eval { JSON::PP->new->utf8->canonical(1)->encode($opts->{json}) };
		if ( !defined $body ) {
			my $error = $@ || 'unknown error';
			$error =~ s/\s+/ /g;
			return $cb->(
				$wantError ? { error => "Could not encode request body: $error" } : {},
				undef,
			);
		}
	}
	else {
		$body = $opts->{json};
	}

	my %headers;
	foreach my $name ( keys %{ ref $opts->{headers} eq 'HASH' ? $opts->{headers} : {} } ) {
		next if lc($name) eq 'content-type';
		my $value = $opts->{headers}->{$name};
		next unless defined $value && !ref $value;
		$headers{$name} = $value;
	}

	# We must use the "legacy" user agent string to comply with Discogs' TOU.
	$headers{'User-Agent'} = Slim::Utils::Misc::userAgentString('legacy');

	# Same identification headers as the GET helper in API.pm.
	if ( Slim::Utils::Misc->can('apiHeaders') ) {
		my $extra = eval { Slim::Utils::Misc::apiHeaders('Plugins::MusicArtistInfo::Plugin') };
		if ( $extra && ref $extra eq 'HASH' ) {
			foreach my $name ( keys %$extra ) {
				$headers{$name} = $extra->{$name} unless exists $headers{$name};
			}
		}
	}
	elsif ( !exists $headers{'X-LMS-Plugin-ID'} ) {
		$headers{'X-LMS-Plugin-ID'} = 'Plugins::MusicArtistInfo::Plugin';
	}

	main::INFOLOG && $log->is_info && $log->info('API call: POST ' . _debug($url));

	my $done = 0;
	my $finish = sub {
		my ($data, $resultHeaders) = @_;
		return if $done++;
		$cb->($data, $resultHeaders);
		return;
	};

	my $cb2 = sub {
		my ($response, $error) = @_;

		if ($error) {
			my $message = ref $error ? "$error" : $error;
			$message = 'request-failed' unless defined $message && $message ne '';
			return $finish->($wantError ? { error => $message } : {}, undef);
		}

		my $status  = eval { $response->code };
		my $content = eval {
			$response->can('decoded_content') ? $response->decoded_content : $response->content;
		};
		$content = '' unless defined $content;

		my $resultHeaders = eval { $response->headers };

		if ( !defined $status || $status < 200 || $status >= 300 ) {
			my $message = defined $status ? "http-$status" : 'http-error';

			my $parsed = eval { JSON::PP->new->utf8->decode($content) };
			if ( ref $parsed eq 'HASH' ) {
				my $detail = _json_error_message($parsed);
				$message .= ': ' . $detail if defined $detail && $detail ne '';
			}

			return $finish->($wantError ? { error => $message } : {}, $resultHeaders);
		}

		my $parsed = eval { JSON::PP->new->utf8->decode($content) };
		return $finish->($wantError ? { error => 'invalid-response' } : {}, $resultHeaders)
			unless defined $parsed;

		return $finish->($parsed, $resultHeaders);
	};

	if ( defined &main::SCANNER && main::SCANNER() ) {
		return $finish->(
			$wantError ? { error => 'post_json is not available in the scanner' } : {},
			undef,
		);
	}

	my $ok = eval {
		Slim::Networking::SimpleAsyncHTTP->new(
			$cb2,
			$cb2,
			{ timeout => $timeout, cache => 0 },
		)->post($url, 'Content-Type' => 'application/json', %headers, $body);
		1;
	};

	unless ($ok) {
		my $error = $@ || 'unknown error';
		$error =~ s/\s+/ /g;
		$finish->($wantError ? { error => "request-failed: $error" } : {}, undef);
	}

	return;
}

sub _json_error_message {
	my $data = shift || {};

	my $error = $data->{error};

	if ( ref $error eq 'HASH' ) {
		return $error->{message}
			|| $error->{type}
			|| $error->{code}
			|| 'api-error';
	}

	return $error if defined $error && !ref $error && $error ne '';

	return;
}

sub getUA { if (main::SCANNER) {
	my ($class, $args) = @_;

	require HTTP::Message;
	require LWP::UserAgent;

	eval {
		require IO::Socket::SSL;

		# our old LWP::UserAgent doesn't support ssl_opts yet
		IO::Socket::SSL::set_defaults(
			SSL_verify_mode => 0
		);
	};

	if ($@) {
		$log->warn("Unable to load IO::Socket::SSL, will try connecting to SSL servers in non-SSL mode\n$@\n");
	}

	my $ua = LWP::UserAgent->new(
		agent   => Slim::Utils::Misc::userAgentString(),
		timeout => $args->{timeout} || 15,
	);

	if (my $encodings = eval { scalar HTTP::Message::decodable() }) {
		$ua->default_header('Accept-Encoding' => $encodings);
	}

	return $ua;
}
else {
	$log->warn('getUA() is only available in the scanner!');
} }

sub getQueryString {
	my ($class, $args) = @_;

	$args ||= {};
	my @query;

	while (my ($k, $v) = each %$args) {
		next if $k =~ /^_/;		# ignore keys starting with an underscore

		if (ref $v eq 'ARRAY') {
			foreach (@$v) {
				push @query, $k . '=' . uri_escape_utf8($_);
			}
		}
		else {
			push @query, $k . '=' . uri_escape_utf8($v);
		}
	}

	return sort @query;
}

sub _debug {
	my $msg = shift;
	$msg =~ s/api_key=.*?(&|$)//gi;
	return $msg;
}

sub getHeaders {
	return $HEADER_DATA[{'discogs' => CAN_DISCOGS, 'lfm' => CAN_LFM}->{$_[1]}]
}

1;

__DATA__
eyJBdXRob3JpemF0aW9uIjoiRGlzY29ncyBrZXk9aFd3c2RBamFQQmhIQVVqZlJ2RnosIHNlY3JldD1ZVWFtamJPVnJUdlpDQnZJVHRkc3NKZ2hGU1VkbllReCJ9
YXBpX2tleT1jNmFiYzUxZTg0N2I5MWFiYTBkZTJlZGUzMzg3NWUyNA