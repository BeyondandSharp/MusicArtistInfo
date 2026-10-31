#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Test::More;
use Slim::Utils::Prefs;
my $prefs = preferences('plugin.musicartistinfo');
$prefs->set('lyricsProcessingScriptPath', '');
$prefs->set('lyricsProcessingScript', q{
$lyrics =~ s/\x{feff}//;
$lyrics =~ s/\r\n?/\n/g;
$lyrics =~ s/[ \t]+$//mg;
$lyrics =~ s/\n{3,}/\n\n/g;
});
require Plugins::MusicArtistInfo::Lyrics::Processor;
my $class = 'Plugins::MusicArtistInfo::Lyrics::Processor';
my $in = "\x{feff}[00:01.00]a  \r\n\n\n\n[00:02.00]b";
my $out = $class->process($in);
unlike($out, qr/\x{feff}/, 'BOM removed');
unlike($out, qr/\r/, 'line endings normalized');
like($out, qr/\n\n\[00:02\.00\]b/, 'blank lines compressed');
done_testing();
