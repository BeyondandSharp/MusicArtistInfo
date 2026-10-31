#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/lib";

use Test::More;

require Plugins::MusicArtistInfo::Lyrics::WebUI;

my $class = 'Plugins::MusicArtistInfo::Lyrics::WebUI';

my $html = $class->build(
	lyrics   => "line one\n<b>not bold</b> & \"quoted\"",
	track_id => 42,
	url      => 'file:///music/a.flac',
	title    => 'Title & "quotes"',
	artist   => 'Artist',
	album    => 'Album',
	duration => 180,
	strings  => { choose => 'Choose & pick' },
);

like($html, qr/id="maiLyricsText"/, 'lyrics container present');
like($html, qr/line one<br \/>/, 'newlines converted');
like($html, qr/&lt;b&gt;not bold&lt;\/b&gt;/, 'lyrics HTML escaped');
like($html, qr/&amp; &quot;quoted&quot;/, 'quotes escaped');
like($html, qr/data-track-id="42"/, 'track id attribute');
like($html, qr/data-title="Title &amp; &quot;quotes&quot;"/, 'title attribute escaped');
like($html, qr/Choose &amp; pick/, 'button label escaped');
like($html, qr/window\.MAILyrics\.open/, 'dynamic loader used');
like($html, qr/data-script="\/plugins\/MusicArtistInfo\/html\/lyricsChooser\.js"/, 'script URL');
unlike($html, qr/<\/script>/, 'no inline script tag needed');

my $errorHtml = $class->build(
	error   => 'not found <here>',
	strings => {},
);
like($errorHtml, qr/not found &lt;here&gt;/, 'error text escaped');

done_testing();
