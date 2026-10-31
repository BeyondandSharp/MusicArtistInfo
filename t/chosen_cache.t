#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/lib";

use Test::More;

require Plugins::MusicArtistInfo::Lyrics::ChosenCache;

package FakeCache;

sub new { bless { values => {} }, shift }
sub get { $_[0]->{values}->{$_[1]} }
sub set { $_[0]->{values}->{$_[1]} = $_[2]; $_[0]->{expires}->{$_[1]} = $_[3]; 1 }
sub remove { delete $_[0]->{values}->{$_[1]} }

package main;

my $cache = FakeCache->new;
my $chosen = Plugins::MusicArtistInfo::Lyrics::ChosenCache->new($cache);

my $args = { artist => 'Artist', title => 'Title', url => 'file:///music/song.flac' };
my $key = Plugins::MusicArtistInfo::Lyrics::ChosenCache->key($args);

like($key, qr/^mai_chosen_lyrics_[a-f0-9]{32}$/, 'key format');

ok(!$chosen->get($args), 'no lyrics initially');

$chosen->save($args, "[00:01.00]你好");
is($chosen->get($args), "[00:01.00]你好", 'lyrics saved and read');
is($cache->{expires}->{$key}, 30 * 24 * 60 * 60, '30 day expiry');

my $args2 = { artist => 'Artist', title => 'Title', url => 'file:///music/other.flac' };
isnt(Plugins::MusicArtistInfo::Lyrics::ChosenCache->key($args2), $key, 'URL is part of key');

$chosen->remove($args);
ok(!$chosen->get($args), 'lyrics removed');

$chosen->save($args, " \n ");
ok(!$chosen->get($args), 'empty lyrics are not stored');

done_testing();
