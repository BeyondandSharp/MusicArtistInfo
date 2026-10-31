#!/usr/bin/perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";

use Test::More;

require Plugins::MusicArtistInfo::Lyrics::FileName;

my $class = 'Plugins::MusicArtistInfo::Lyrics::FileName';

is(
	$class->lyrics_filename(undef, 'FILE', sub { 'Song' }),
	'Song.lrc',
	'FILE format',
);

is(
	$class->lyrics_filename(undef, 'ARTIST - TITLE', sub { 'Artist - Title' }),
	'Artist - Title.lrc',
	'metadata format',
);

is(
	$class->lyrics_filename(undef, 'X', sub { 'Artist / Title: 100%' }),
	'Artist Title 100%.lrc',
	'invalid path characters are removed',
);

is(
	$class->lyrics_filename(undef, 'X', sub { 'CON' }),
	'_CON.lrc',
	'Windows reserved names are prefixed',
);

is(
	$class->lyrics_filename(undef, 'X', sub { 'Song.lrc' }),
	'Song.lrc',
	'duplicate .lrc suffix is removed',
);

is(
	$class->lyrics_filename(undef, 'X', sub { '' }),
	'lyrics.lrc',
	'empty result falls back',
);

is(
	$class->lyrics_filename(undef, 'X', sub { die 'broken formatter' }),
	'lyrics.lrc',
	'broken formatter falls back',
);

my $long = 'a' x 400;
my $result = $class->lyrics_filename(undef, 'X', sub { $long });
ok(length($result) <= 154, 'long names are truncated');
like($result, qr/\.lrc$/, 'long name keeps .lrc');

is(
	$class->lyrics_filename(undef, '', sub { 'Song' }),
	'Song.lrc',
	'empty format falls back to FILE',
);

done_testing();
