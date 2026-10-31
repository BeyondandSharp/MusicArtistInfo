#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/lib";

use File::Spec::Functions qw(catfile);
use File::Temp qw(tempdir);
use Test::More;

require Plugins::MusicArtistInfo::Lyrics::Sidecar;

my $class = 'Plugins::MusicArtistInfo::Lyrics::Sidecar';
my $dir = tempdir(CLEANUP => 1);
my $audio = catfile($dir, 'Song.mp3');
open(my $fh, '>', $audio) or die $!;
print {$fh} "audio";
close $fh;

is($class->path_for($audio, 'Song.lrc'), catfile($dir, 'Song.lrc'), 'path_for');

my $result = $class->save($audio, 'Song.lrc', "[00:01.00]你好\r\n[00:02.00]line\\nnext");
ok($result->{file}, 'save returns file') or diag explain $result;

my $file = catfile($dir, 'Song.lrc');
ok(-f $file, 'lyrics file exists');

open(my $read, '<:raw', $file) or die $!;
local $/;
my $content = <$read>;
close $read;
utf8::decode($content);

like($content, qr/\[00:01\.00\]你好/, 'UTF-8 content written');
like($content, qr/line\nnext/, 'literal newlines normalized');
like($content, qr/\n\z/, 'trailing newline added');

$result = $class->save($audio, 'Song.lrc', 'new lyrics');
is($result->{skipped}, 'exists', 'does not overwrite by default');

$result = $class->save($audio, 'Song.lrc', 'new lyrics', { overwrite => 1 });
ok($result->{file}, 'overwrite allowed');

open($read, '<:raw', $file) or die $!;
$content = <$read>;
close $read;
utf8::decode($content);
like($content, qr/^new lyrics\n\z/, 'content overwritten');

$result = $class->save(catfile($dir, 'missing.mp3'), 'Song.lrc', 'x');
like($result->{error}, qr/not found/i, 'missing audio rejected');

$result = $class->save($audio, 'bad/name.lrc', 'x');
like($result->{error}, qr/Invalid lyrics filename/, 'path traversal rejected');

$result = $class->save($audio, 'Song2.lrc', " \n ", { overwrite => 1 });
like($result->{error}, qr/empty/i, 'empty lyrics rejected');

is($class->normalize("\x{feff}a\r\nb\rc"), "a\nb\nc\n", 'normalize handles BOM and line endings');

# save_path/BOM support
my $bomFile = catfile($dir, 'WithBom.lrc');
my $bomResult = $class->save_path($bomFile, 'hello', { overwrite => 1, bom => 1 });
ok($bomResult->{file}, 'save_path writes BOM file');
open($read, '<:raw', $bomFile) or die $!;
$content = <$read>;
close $read;
is(substr($content, 0, 3), "\xEF\xBB\xBF", 'UTF-8 BOM written');

$bomResult = $class->save_path(catfile($dir, 'missing-dir', 'x.lrc'), 'x');
like($bomResult->{error}, qr/not writable/i, 'missing target folder rejected');

# UTF-16LE output
my $utf16File = catfile($dir, 'Utf16.lrc');
my $utf16 = $class->save_path($utf16File, 'hello', { overwrite => 1, encoding => 'utf16le' });
ok($utf16->{file}, 'utf16le file written');
open($read, '<:raw', $utf16File) or die $!;
$content = <$read>;
close $read;
is(substr($content, 0, 2), "\xFF\xFE", 'UTF-16LE BOM written');

done_testing();
