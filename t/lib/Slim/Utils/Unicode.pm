package Slim::Utils::Unicode;

use strict;

sub looks_like_utf8 {
	my ($value) = @_;
	return 0 unless defined $value;
	return $value =~ /[\x80-\xff]/ ? 1 : 0;
}

sub utf8on { return $_[0] }

1;
