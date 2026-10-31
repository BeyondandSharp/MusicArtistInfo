#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use Encode qw(encode);
use File::Spec::Functions qw(catfile);
use File::Temp qw(tempdir);
use Test::More;

use Plugins::MusicArtistInfo::Parser::LRC;

my $class = 'Plugins::MusicArtistInfo::Parser::LRC';
my $dir = tempdir(CLEANUP => 1);

my $path = catfile($dir, 'bom.lrc');
open(my $fh, '>:raw', $path) or die $!;
print {$fh} "\xEF\xBB\xBF" . encode('UTF-8', "[00:01.00]你好\n[00:02.00]世界\n");
close $fh;

is($class->parse($path), "你好\n世界", 'UTF-8 BOM LRC parsed');

my $utf16_path = catfile($dir, 'utf16.lrc');
open($fh, '>:raw', $utf16_path) or die $!;
print {$fh} "\xFF\xFE" . encode('UTF-16LE', "[00:03.00]こんにちは\n");
close $fh;

is($class->parse($utf16_path), 'こんにちは', 'UTF-16LE BOM LRC parsed');

done_testing();
