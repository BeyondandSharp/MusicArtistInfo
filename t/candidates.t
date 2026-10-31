#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/lib";

use Test::More;

require Plugins::MusicArtistInfo::Lyrics::Candidates;

my $class = 'Plugins::MusicArtistInfo::Lyrics::Candidates';

my $normalized = $class->normalize({
	title => 'Title',
	artist => 'Artist',
	lyrics => "[00:01.00]你好\n[00:02.00]line two\n[00:03.00]line three\nline four",
}, 'Source');

is($normalized->{source}, 'Source', 'source set');
is($normalized->{synced}, 1, 'timestamps detected');
like($normalized->{preview}, qr/你好/, 'preview includes first lines');
unlike($normalized->{preview}, qr/line four/, 'preview is limited');

ok(!$class->normalize({ lyrics => '' }, 'Source'), 'empty lyrics skipped');
ok(!$class->normalize({ lyrics => 'x', instrumental => 1 }, 'Source'), 'instrumental skipped');
ok(!$class->normalize({ error => 'x' }, 'Source'), 'error skipped');

my $plain = $class->normalize({ lyrics => "no timestamps\nsecond" }, 'Plain');
is($plain->{synced}, 0, 'plain lyrics detected');

my $deduped = $class->dedupe([
	{ title => 'T', artist => 'A', lyrics => 'same' },
	{ title => 'T', artist => 'A', lyrics => 'same' },
	{ title => 'T', artist => 'A', lyrics => 'other' },
]);

is(scalar @$deduped, 2, 'dedupe by artist/title/lyrics');

my @many = map {
	{ title => 'T', artist => 'A', lyrics => "line $_" }
} (1 .. 60);

my $final = $class->finalize(\@many);
is(scalar @$final, 50, 'candidate limit enforced');
is($final->[0]->{index}, 0, 'index added');
is($final->[49]->{index}, 49, 'last index added');

my $best = $class->best([
	{ lyrics => 'plain', synced => 0 },
	{ lyrics => '[00:01.00]synced', synced => 1 },
]);
like($best->{lyrics}, qr/synced/, 'best prefers synced lyrics');

is($class->best([]), undef, 'best handles empty list');

done_testing();
