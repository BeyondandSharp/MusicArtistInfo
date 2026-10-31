package Plugins::MusicArtistInfo::Lyrics::Processor;

use strict;

use Slim::Utils::Prefs;

use Plugins::MusicArtistInfo::Lyrics::ScriptRunner;
use Plugins::MusicArtistInfo::Lyrics::Scripts;

my $prefs = preferences('plugin.musicartistinfo');

sub rules {
	my $raw = $prefs->get('lyricsProcessingRules');
	return [] unless defined $raw && $raw ne '';
	my $decoded = eval { JSON::PP->new->decode($raw) };
	return ref $decoded eq 'ARRAY' ? $decoded : [];
}

sub process {
	my ($class, $lyrics, $opts) = @_;

	$opts ||= {};
	return $lyrics unless defined $lyrics && $lyrics ne '';
	return $lyrics unless $opts->{enabled} // 1;

	my $script = $prefs->get('lyricsProcessingScript');
	$script = Plugins::MusicArtistInfo::Lyrics::Scripts->default_processing_script
		if !defined $script || $script eq '';
	my $path = $prefs->get('lyricsProcessingScriptPath') || '';

	my $result = Plugins::MusicArtistInfo::Lyrics::ScriptRunner->run(
		$script,
		$path,
		{ lyrics => $lyrics },
	);

	return $lyrics if !$result || $result->{error} || !defined $result->{lyrics};
	return $result->{lyrics};
}


1;
