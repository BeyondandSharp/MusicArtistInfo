package Slim::Utils::Prefs;

use strict;
use Exporter 'import';

our @EXPORT = qw(preferences dir);

my $prefs = bless {}, 'FakePrefs';

sub preferences { return $prefs }
sub dir { return '/tmp' }

package FakePrefs;

sub get {
	my ($self, $key) = @_;
	return $self->{$key};
}

sub set {
	my ($self, $key, $value) = @_;
	$self->{$key} = $value;
	return 1;
}

1;
