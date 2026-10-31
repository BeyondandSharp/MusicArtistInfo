package Slim::Utils::Misc;

use strict;

sub pathFromFileURL {
	my ($url) = @_;
	$url =~ s/^file:\/\///;
	$url =~ s/%([0-9a-fA-F]{2})/chr(hex($1))/ge;
	return "/$url" unless $url =~ m{^/};
	return $url;
}

sub getTempDir { '/tmp' }

sub cleanupFilename {
	my ($filename) = @_;
	$filename =~ tr|:\x00-\x1f\/\\| |s;
	$filename =~ s/^\.//;
	return $filename;
}

1;
