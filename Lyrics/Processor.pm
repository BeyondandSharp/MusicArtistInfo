package Plugins::MusicArtistInfo::Lyrics::Processor;

use strict;

use JSON::PP ();

use Slim::Utils::Prefs;

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

	foreach my $rule (@{ $class->rules }) {
		next unless ref $rule eq 'HASH' && $rule->{enabled};
		my $op = $rule->{op} || '';

		if ( $op eq 'standardize' ) {
			$lyrics =~ s/^\x{feff}//;
			$lyrics =~ s/\r\n?/\n/g;
			$lyrics =~ s/[ \t]+$//mg;
		}
		elsif ( $op eq 'compress_blank' ) {
			$lyrics =~ s/\n{3,}/\n\n/g;
		}
		elsif ( $op eq 'simplified' || $op eq 'traditional' ) {
			if ( eval { require Plugins::MusicArtistInfo::Lyrics::HanConvert; 1 } ) {
				$lyrics = Plugins::MusicArtistInfo::Lyrics::HanConvert->convert($lyrics, $op)
					if Plugins::MusicArtistInfo::Lyrics::HanConvert->available;
			}
		}
	}

	return $lyrics;
}

1;
