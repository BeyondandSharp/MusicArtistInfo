# NetEase Cloud Music (网易云音乐) lyrics source.
# Based on Robotxm's ESLyric netease_ex.js (GPL-3.0), which is based on
# ohyeah's original source.  This is a Perl port using the classic web API;
# it does not use Node.js or crypto-es.
use strict;
use warnings;
use JSON::PP ();
use URI::Escape qw(uri_escape_utf8);

my $REFERER = 'https://music.163.com';
my $HEADERS = {
	Referer => $REFERER,
	Origin  => 'https://music.163.com',
};

sub _call {
	my ($url, $cb) = @_;

	Plugins::MusicArtistInfo::Common->call($url, $cb, {
		timeout => 8,
		cache   => 0,
		headers => $HEADERS,
		ignoreError => [404],
	});
}

sub _data {
	my $response = shift;
	return $response if ref $response eq 'HASH' || ref $response eq 'ARRAY';
	return unless defined $response && $response ne '';
	return eval { JSON::PP->new->utf8->decode($response) };
}

sub _clean {
	my $text = shift;
	return '' unless defined $text;
	$text =~ s/^\s*\{[^}]*\}\s*//mg;
	$text =~ s/^\s+|\s+$//g;
	return $text;
}

return {
	name => 'NetEase Cloud Music',
	getLyrics => sub {
		my ($args, $cb) = @_;

		my $query = join ' ', grep { defined && $_ ne '' } ($args->{title}, $args->{artist});
		return $cb->() unless $query =~ /\S/;

		my $url = 'https://music.163.com/api/search/get?s='
			. uri_escape_utf8($query) . '&type=1&limit=10&offset=0';

		_call($url, sub {
			my $search = _data(shift);
			my $songs = $search && ref $search eq 'HASH'
				? $search->{result}{songs}
				: undef;

			return $cb->() unless $songs && ref $songs eq 'ARRAY' && @$songs;

			my $song = $songs->[0];
			my $id = $song->{id};
			return $cb->() unless defined $id;

			my $title = $song->{name} || $args->{title};
			my $artist = join ' / ', grep { defined && $_ ne '' } map {
				ref $_ eq 'HASH' ? $_->{name} : undef
			} @{ $song->{artists} || [] };
			$artist ||= $args->{artist};
			my $album = $song->{album}{name} if ref $song->{album} eq 'HASH';

			my $lyricUrl = 'https://music.163.com/api/song/lyric?id='
				. uri_escape_utf8($id) . '&lv=-1&kv=-1&tv=-1';

			_call($lyricUrl, sub {
				my $data = _data(shift);
				return $cb->() unless $data && ref $data eq 'HASH';

				my $lyrics = _clean($data->{lrc}{lyric});
				return $cb->() unless $lyrics ne '';

				if (my $translation = _clean($data->{tlyric}{lyric})) {
					$lyrics .= "\n" . $translation;
				}

				$cb->({
					lyrics => $lyrics,
					song   => $title,
					artist => $artist,
					album  => $album || '',
					source => 'NetEase Cloud Music',
				});
			});
		});
	},
};
