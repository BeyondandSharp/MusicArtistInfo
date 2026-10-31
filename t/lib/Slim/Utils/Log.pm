package Slim::Utils::Log;

use strict;
use Exporter 'import';

our @EXPORT = qw(logger);

sub logger { return FakeLogger->new }

package FakeLogger;

sub new { bless {}, shift }
sub info  { 0 }
sub debug { 0 }
sub warn  { 0 }
sub error { 0 }
sub is_info  { 0 }
sub is_debug { 0 }

1;
