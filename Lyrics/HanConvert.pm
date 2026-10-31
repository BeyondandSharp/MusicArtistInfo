package Plugins::MusicArtistInfo::Lyrics::HanConvert;

use strict;

# Optional simplified/traditional conversion adapter.  LMS does not ship a
# converter by default.  If Encode::HanConvert (or a compatible module) is
# installed, it will be used; otherwise conversion rules are ignored and the
# caller can explain that to the user.

my $MODULE;
my $LOADED = 0;

sub _load {
	return $MODULE if $LOADED++;
	foreach my $module (qw(Encode::HanConvert Text::OpenCC)) {
		if ( eval "require $module; 1" ) {
			$MODULE = $module;
			last;
		}
	}
	return $MODULE;
}

sub available {
	return _load ? 1 : 0;
}

sub convert {
	my ($class, $text, $direction) = @_;

	return $text unless defined $text && $text ne '';
	my $module = _load;
	return $text unless $module;

	my $out = eval {
		if ( $module eq 'Encode::HanConvert' ) {
			if ( $direction eq 'simplified' && $module->can('trad2simp') ) {
				return $module->trad2simp($text);
			}
			if ( $direction eq 'traditional' && $module->can('simp2trad') ) {
				return $module->simp2trad($text);
			}
		}
		elsif ( $module eq 'Text::OpenCC' ) {
			my $cc = $module->new;
			return $direction eq 'simplified' ? $cc->t2s($text) : $cc->s2t($text);
		}
	};

	return defined $out ? $out : $text;
}

1;
