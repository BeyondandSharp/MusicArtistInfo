#!/usr/bin/perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";

use File::Spec::Functions qw(catfile);
use File::Temp qw(tempdir);
use Test::More;

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.musicartistinfo');
my $dir = tempdir(CLEANUP => 1);

open(my $fh, '>', catfile($dir, 'a-valid.pl')) or die $!;
print {$fh} <<'SCRIPT';
return {
    name => 'First source',
    getLyrics => sub {
        my ($args, $cb) = @_;
        $cb->({ lyrics => "[00:01.00]from first\n", source => 'First source' });
    },
};
SCRIPT
close $fh;

$prefs->set('enableCustomLyricsScripts', 1);
$prefs->set('customLyricsScriptsFolder', $dir);

require Plugins::MusicArtistInfo::Lyrics::PerlScripts;
my $class = 'Plugins::MusicArtistInfo::Lyrics::PerlScripts';

my @result;
$class->getLyrics({ title => 'T', artist => 'A' }, sub { @result = @_ });
Slim::Utils::Timers::run_pending();

is(scalar @result, 1, 'script callback invoked');
like($result[0]{lyrics}, qr/from first/, 'lyrics returned');
is($result[0]{source}, 'First source', 'source name preserved');

# A broken script must not prevent a later script from being used.
open($fh, '>', catfile($dir, '00-broken.pl')) or die $!;
print {$fh} "die 'boom';\n";
close $fh;
@result = ();
$class->getLyrics({ title => 'T', artist => 'A' }, sub { @result = @_ });
Slim::Utils::Timers::run_pending();
like($result[0]{lyrics}, qr/from first/, 'broken script skipped');

$prefs->set('enableCustomLyricsScripts', 0);
my $called = 0;
$class->getLyrics({ title => 'T', artist => 'A' }, sub { $called = 1 });
ok($called, 'disabled provider calls back');

done_testing();
