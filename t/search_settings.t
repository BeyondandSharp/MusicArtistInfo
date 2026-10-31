#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Test::More;
use Slim::Utils::Prefs;
my $prefs = preferences('plugin.musicartistinfo');
$prefs->set('lyricsSearchFilters', '[{"enabled":1,"field":"title","op":"contains","value":"伴奏"}]');
$prefs->set('lyricsFieldProcessing', '[{"enabled":1,"op":"remove_chars","param1":"!","target":"all"}]');
$prefs->set('lyricsCustomSearchFields', 0);
require Plugins::MusicArtistInfo::Lyrics::SearchSettings;
my $class = 'Plugins::MusicArtistInfo::Lyrics::SearchSettings';
ok($class->skip_auto_search({title => 'Song (伴奏)'}), 'filter matches title');
ok(!$class->skip_auto_search({title => 'Song'}), 'filter does not match');
my $args = $class->prepare_args({title => 'Song!', artist => 'Artist'});
is($args->{title}, 'Song', 'field processing applied');
done_testing();
