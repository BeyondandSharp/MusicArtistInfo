package Slim::Utils::Prefs;

use strict;
use Exporter 'import';

our @EXPORT = qw(preferences);

my %stores;

sub preferences {
	my ($namespace) = @_;
	return $stores{$namespace} ||= FakePrefs->new($namespace);
}

sub reset {
	%stores = ();
}

sub dir { '/tmp/mai-test-prefs' }

package FakePrefs;

sub new {
	my ($class, $namespace) = @_;
	return bless { namespace => $namespace, values => {} }, $class;
}

sub get {
	my ($self, $name) = @_;
	return $self->{values}->{$name};
}

sub set {
	my ($self, $name, $value) = @_;
	$self->{values}->{$name} = $value;
	return $value;
}

sub init {
	my ($self, $defaults) = @_;
	foreach my $key (keys %$defaults) {
		$self->{values}->{$key} = $defaults->{$key}
			unless exists $self->{values}->{$key};
	}
	return 1;
}

sub remove {
	my ($self, $name) = @_;
	delete $self->{values}->{$name};
}

1;
