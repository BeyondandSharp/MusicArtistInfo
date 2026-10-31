# Musixmatch lyrics source.
# Based on ohyeah's ESLyric musixmatch.js.  Perl port using the public
# desktop web API; no Node.js or querystring library is required.
use strict;
use warnings;
use JSON::PP ();
use URI::Escape qw(uri_escape_utf8);

my $BASE = 'https://apic-desktop.musixmatch.com/ws/1.1/';
my $COOKIE = 'AWSELBCORS=0; AWSELB=0';
my $APP_ID = 'web-desktop-app-v1.0';

sub _url {
	my ($endpoint, @pairs) = @_;
	return $BASE . $endpoint . '?' . join '&', map {
		uri_escape_utf8($_->[0]) . '=' . uri_escape_utf8($_->[1] // '')
	} @pairs;
}

sub _call {
	my ($url, $cb) = @_;

	Plugins::MusicArtistInfo::Common->call($url, $cb, {
		timeout => 8,
		cache   => 0,
		headers => { cookie => $COOKIE },
		ignoreError => [404],
	});
}

sub _data {
	my $response = shift;
	return $response if ref $response eq 'HASH' || ref $response eq 'ARRAY';
	return unless defined $response && $response ne '';
	return eval { JSON::PP->new->utf8->decode($response) };
}

sub _body {
	my $response = _data(shift);
	return unless $response && ref $response eq 'HASH';
	return $response->{message}{body} if ref $response->{message} eq 'HASH';
	return;
}

sub _norm {
	my $text = defined $_[0] ? lc $_[0] : '';
	$text =~ s/\s+//g;
	$text =~ s/[^\p{L}\p{N}]//g;
	return $text;
}

sub _matches {
	my ($song, $title, $artist) = @_;

	my $st = _norm($song->{track_name});
	my $sa = _norm($song->{artist_name});
	my $nt = _norm($title);
	my $na = _norm($artist);

	return 0 unless $st ne '' && $sa ne '';
	return 1 if $nt eq '' || index($st, $nt) >= 0 || index($nt, $st) >= 0;
	return 1 if $na eq '' || index($sa, $na) >= 0 || index($na, $sa) >= 0;
	return 0;
}

sub _query_lyric {
	my ($token, $id, $sync, $cb) = @_;

	my $endpoint = $sync ? 'track.subtitle.get' : 'track.lyrics.get';
	my $key      = $sync ? 'subtitle' : 'lyrics';
	my $bodyKey  = $sync ? 'subtitle_body' : 'lyrics_body';

	my $url = _url($endpoint,
		[user_language => 'en'],
		[app_id => $APP_ID],
		[commontrack_id => $id],
		[usertoken => $token],
	);

	_call($url, sub {
		my $body = _body(shift);
		my $lyrics = $body && ref $body eq 'HASH'
			? $body->{$key}{$bodyKey}
			: undef;

		$cb->(defined $lyrics && $lyrics =~ /\S/ ? $lyrics : undef);
	});
}

return {
	name => 'Musixmatch',
	getLyrics => sub {
		my ($args, $cb) = @_;

		my $title  = $args->{title}  || '';
		my $artist = $args->{artist} || '';
		return $cb->() unless $title =~ /\S/;

		my $tokenUrl = _url('token.get',
			[user_language => 'en'],
			[app_id => $APP_ID],
			[t => time],
		);

		_call($tokenUrl, sub {
			my $body = _body(shift);
			my $token = $body && ref $body eq 'HASH'
				? $body->{user_token}
				: undef;

			$token = '' unless defined $token;
			$token = '' if $token eq 'UpgradeOnlyUpgradeOnlyUpgradeOnlyUpgradeOnly';

			my $searchUrl = _url('track.search',
				[user_language => 'en'],
				[app_id => $APP_ID],
				[format => 'json'],
				[subtitle_format => 'lrc'],
				[q_track => $title],
				[q_artist => $artist],
				[q_album => $args->{album} || ''],
				[f_has_lyrics => 1],
				[usertoken => $token],
				[t => time],
			);

			_call($searchUrl, sub {
				my $searchBody = _body(shift);
				my $tracks = $searchBody && ref $searchBody eq 'HASH'
					? $searchBody->{track_list}
					: undef;

				return $cb->() unless $tracks && ref $tracks eq 'ARRAY';

				my ($track) = grep {
					ref $_ eq 'HASH' && ref $_->{track} eq 'HASH'
					&& ($_->{track}{has_subtitles} || $_->{track}{has_lyrics})
					&& _matches($_->{track}, $title, $artist)
				} @$tracks;

				return $cb->() unless $track;

				my $song = $track->{track};
				my $id = $song->{commontrack_id};
				return $cb->() unless defined $id && $id;

				my $finish = sub {
					my $lyrics = shift;
					return $cb->() unless defined $lyrics && $lyrics =~ /\S/;
					$cb->({
						lyrics => $lyrics,
						song   => $song->{track_name} || $title,
						artist => $song->{artist_name} || $artist,
						album  => $song->{album_name} || '',
						source => 'Musixmatch',
					});
				};

				my $tryPlain = sub {
					_query_lyric($token, $id, 0, $finish);
				};

				if ($song->{has_subtitles}) {
					_query_lyric($token, $id, 1, sub {
						my $lyrics = shift;
						return $finish->($lyrics) if defined $lyrics;
						return $tryPlain->() if $song->{has_lyrics};
						$cb->();
					});
				}
				elsif ($song->{has_lyrics}) {
					$tryPlain->();
				}
				else {
					$cb->();
				}
			});
		});
	},
};
