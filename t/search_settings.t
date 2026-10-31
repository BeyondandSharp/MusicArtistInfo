#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Test::More;
use Slim::Utils::Prefs;
my $prefs = preferences('plugin.musicartistinfo');
$prefs->set('lyricsCustomSearchFields', 0);
$prefs->set('lyricsSearchScriptPath', '');
$prefs->set('lyricsSearchScript', q{
$title =~ s/!//g;
$skip = 1 if $title =~ /伴奏/;
});
require Plugins::MusicArtistInfo::Lyrics::SearchSettings;
my $class = 'Plugins::MusicArtistInfo::Lyrics::SearchSettings';
ok($class->skip_auto_search({title => 'Song (伴奏)'}), 'script filter matches title');
ok(!$class->skip_auto_search({title => 'Song'}), 'script filter does not match');
my $args = $class->prepare_args({title => 'Song!', artist => 'Artist'});
is($args->{title}, 'Song', 'search script processing applied');
done_testing();
