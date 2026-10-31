package Plugins::MusicArtistInfo::Lyrics::ChosenCache;

use strict;

use Digest::MD5 qw(md5_hex);

# Remembers lyrics explicitly chosen in the web UI.  The cache implementation
# is injectable for tests.

my $EXPIRES = 30 * 24 * 60 * 60;

sub new {
	my ($class, $cache) = @_;

	return bless {
		cache => $cache,
	}, $class;
}

sub _cache {
	my ($self) = @_;

	unless ( $self->{cache} ) {
		require Slim::Utils::Cache;
		$self->{cache} = Slim::Utils::Cache->new;
	}

	return $self->{cache};
}

sub key {
	my ($class, $args) = @_;

	$args ||= {};

	my $url = $args->{url};
	$url ||= $args->{track}->url if $args->{track};

	my $keyText = join "\x1f",
		lc($args->{artist} || ''),
		lc($args->{title}  || ''),
		$url || '';
	utf8::encode($keyText);

	return 'mai_chosen_lyrics_' . md5_hex($keyText);
}

sub get {
	my ($self, $args) = @_;

	my $lyrics = $self->_cache->get($self->key($args));

	return unless defined $lyrics && !ref $lyrics && $lyrics =~ /\S/;

	utf8::decode($lyrics);

	return $lyrics;
}

sub save {
	my ($self, $args, $lyrics) = @_;

	return unless defined $lyrics && $lyrics =~ /\S/;

	my $encoded = $lyrics;
	utf8::encode($encoded);

	$self->_cache->set($self->key($args), $encoded, $EXPIRES);

	return 1;
}

sub remove {
	my ($self, $args) = @_;

	$self->_cache->remove($self->key($args));

	return 1;
}

sub expires { $EXPIRES }

1;
