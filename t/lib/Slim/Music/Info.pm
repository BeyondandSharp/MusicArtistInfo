package Slim::Music::Info;

use strict;

sub isFileURL { defined $_[0] && $_[0] =~ /^file:/i }
sub isHTTPURL { defined $_[0] && $_[0] =~ /^https?:/i }

1;
