#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use Encode qw(encode);
use File::Spec::Functions qw(catfile);
use File::Temp qw(tempdir);
use Test::More;

use Plugins::MusicArtistInfo::Text;

my $class = 'Plugins::MusicArtistInfo::Text';
my $dir = tempdir(CLEANUP => 1);

sub check {
	my ($name, $bytes, $expected, $opts) = @_;
	my $decoded = $class->decode($bytes, $opts);
	is($decoded, $expected, $name);
	unlike($decoded, qr/^\x{FEFF}/, "$name: no BOM");
}

my $text = "你好 hello";
my $utf8 = encode('UTF-8', $text);

check('UTF-8', $utf8, $text);
check('UTF-8 BOM', "\xEF\xBB\xBF" . $utf8, $text);

my %bom = (
	'UTF-16LE' => "\xFF\xFE",
	'UTF-16BE' => "\xFE\xFF",
	'UTF-32LE' => "\xFF\xFE\x00\x00",
	'UTF-32BE' => "\x00\x00\xFE\xFF",
);

foreach my $encoding (sort keys %bom) {
	my $bytes = $bom{$encoding} . encode($encoding, $text);
	check($encoding . ' BOM', $bytes, $text);
}

my $utf16 = encode('UTF-16LE', $text);
check('UTF-16LE without BOM heuristic', $utf16, $text, { hints => [ $text ] });
check('UTF-16BE without BOM heuristic', encode('UTF-16BE', $text), $text, { hints => [ $text ] });
check('UTF-32LE without BOM heuristic', encode('UTF-32LE', $text), $text, { hints => [ $text ] });

my $gbk = encode('cp936', $text);
check('CP936 auto with hints', $gbk, $text, { hints => [ '你好' ] });
check('CP936 explicit', $gbk, $text, { encoding => 'cp936' });

my $japanese = 'こんにちは';
my $sjis = encode('cp932', $japanese);
check('CP932 auto with hints', $sjis, $japanese, { hints => [ 'こんにちは' ] });

my $russian = 'Привет';
my $cp1251 = encode('cp1251', $russian);
check('CP1251 auto with hints', $cp1251, $russian, { hints => [ $russian ] });

my $western = 'Ça va très bien';
my $cp1252 = encode('cp1252', $western);
check('CP1252 auto with hints', $cp1252, $western, { hints => [ $western ] });

my $big5 = encode('big5-hkscs', '你好');
check('Big5 explicit', $big5, '你好', { encoding => 'big5-hkscs' });

my $eucjp = encode('euc-jp', 'こんにちは');
check('EUC-JP explicit', $eucjp, 'こんにちは', { encoding => 'euc-jp' });

my $cp949 = encode('cp949', '안녕하세요');
check('CP949 explicit', $cp949, '안녕하세요', { encoding => 'cp949' });

is($class->decode(''), '', 'empty input');
is($class->decode("\xEF\xBB\xBF"), '', 'BOM-only input');
like($class->decode("\xFF\xFF\xFF"), qr/\S?/, 'invalid bytes do not die');

is($class->strip_bom("\x{FEFF}hello"), 'hello', 'strip_bom handles wide text');

my $path = catfile($dir, 'lyrics.lrc');
open(my $fh, '>:raw', $path) or die $!;
print {$fh} "\xEF\xBB\xBF" . encode('UTF-8', "[00:01.00]你好\n");
close $fh;
is($class->read_file($path), "[00:01.00]你好\n", 'read_file decodes BOM file');
ok(!defined $class->read_file(catfile($dir, 'missing')), 'missing file returns undef');

done_testing();
