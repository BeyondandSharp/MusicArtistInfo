package Slim::Utils::Timers;

use strict;
use Exporter 'import';

our @EXPORT = qw(setTimer killTimers);

my @timers;

sub setTimer {
	my ($obj, $when, $cb, @args) = @_;
	push @timers, { obj => $obj, cb => $cb, args => \@args };
	return;
}

sub killTimers {
	my ($obj, $cb) = @_;
	@timers = grep {
		!((defined $obj && defined $_->{obj} && "$obj" eq "$_->{obj}")
			&& (!defined $cb || $_->{cb} == $cb))
	} @timers;
	return 1;
}

sub run_pending {
	my $limit = 100;
	while (@timers && $limit--) {
		my $timer = shift @timers;
		$timer->{cb}->($timer->{obj}, @{ $timer->{args} });
	}
}

1;
