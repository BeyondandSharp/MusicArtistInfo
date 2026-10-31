# LRCLib example using MAI's asynchronous HTTP helper.
use strict;
use warnings;
use JSON::PP ();
use URI::Escape qw(uri_escape_utf8);

return {
	name => 'LRCLib (Perl example)',
	getLyrics => sub {
		my ($args, $cb) = @_;

		my $url = 'https://lrclib.net/api/get'
			. '?artist_name=' . uri_escape_utf8($args->{artist} || '')
			. '&track_name='  . uri_escape_utf8($args->{title}  || '')
			. '&album_name='  . uri_escape_utf8($args->{album}  || '');

		Plugins::MusicArtistInfo::Common->call($url, sub {
			my $body = shift;
			my $data = eval { JSON::PP->new->utf8->decode($body) };

			return $cb->() unless $data && ref $data eq 'HASH';

			my $lyrics = $data->{syncedLyrics} || $data->{plainLyrics};
			return $cb->() unless defined $lyrics && $lyrics =~ /\S/;

			$cb->({
				lyrics => $lyrics,
				source => 'LRCLib',
			});
		}, {
			timeout => 5,
			cache => 1,
			expires => 86400,
		});
	},
};
