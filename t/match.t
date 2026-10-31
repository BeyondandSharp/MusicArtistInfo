#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
require Plugins::MusicArtistInfo::Lyrics::Match;
my $class = 'Plugins::MusicArtistInfo::Lyrics::Match';
my $args = { title => 'The Birthday', artist => 'VINCENT SAID' };
is($class->score({ title => 'The Birthday', artist => 'VINCENT SAID' }, $args), 100, 'exact score');
ok($class->score({ title => 'The Birthday', artist => 'Someone' }, $args) < 100, 'artist mismatch');
is($class->score({ title => 'Unrelated', artist => 'Other' }, $args), 0, 'unrelated score');
my $best = $class->best([
	{ lyrics => 'a', title => 'The Birthday', artist => 'Other', priority => 1 },
	{ lyrics => 'b', title => 'The Birthday', artist => 'VINCENT SAID', priority => 2 },
], $args, { min => 50 });
is($best->{lyrics}, 'b', 'best candidate selected');
done_testing();
