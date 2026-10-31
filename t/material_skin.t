#!/usr/bin/perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";

use File::Spec::Functions qw(catfile);
use File::Temp qw(tempdir);
use Test::More;

use Slim::Utils::Prefs;

package main;
use constant WEBUI => 1;
use constant INFOLOG => 0;

require Plugins::MusicArtistInfo::Lyrics::MaterialSkin;

my $class = 'Plugins::MusicArtistInfo::Lyrics::MaterialSkin';
my $dir = tempdir(CLEANUP => 1);
my $custom = catfile($dir, 'custom.js');

{
	no warnings qw(redefine once);
	*Plugins::MusicArtistInfo::Lyrics::MaterialSkin::custom_js_path = sub { $custom };
}

my $prefs = preferences('plugin.musicartistinfo');
$prefs->set('integrateMaterialSkin', 1);

open(my $fh, '>', $custom) or die $!;
print {$fh} "var userCode = 1;\n";
close $fh;

$class->sync;

my $content = do { local $/; open($fh, '<', $custom) or die $!; <$fh> };
close $fh;

like($content, qr/var userCode = 1;/, 'existing custom code preserved');
like($content, qr/BEGIN MusicArtistInfo lyrics chooser/, 'loader block added');
like($content, qr/materialLyricsChooser\.js/, 'loader points at chooser script');

$class->remove;

$content = do { local $/; open($fh, '<', $custom) or die $!; <$fh> };
close $fh;

like($content, qr/var userCode = 1;/, 'custom code remains after removal');
unlike($content, qr/BEGIN MusicArtistInfo lyrics chooser/, 'loader block removed');

$prefs->set('integrateMaterialSkin', 0);
$class->sync;
$content = do { local $/; open($fh, '<', $custom) or die $!; <$fh> };
close $fh;
unlike($content, qr/BEGIN MusicArtistInfo lyrics chooser/, 'disabled integration removes block');

done_testing();
