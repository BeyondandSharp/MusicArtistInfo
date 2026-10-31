package Proc::Background;

use strict;

use JSON::PP ();

our $NEXT_RESULT;
our $WRITE_OUTPUT = 1;

sub new {
	my ($class, $opts, $command) = @_;

	my $output;
	for (my $i = 0; $i < @$command - 1; $i++) {
		$output = $command->[$i + 1] if $command->[$i] eq '--output';
	}

	if ($WRITE_OUTPUT && $output) {
		my $result = defined $NEXT_RESULT ? $NEXT_RESULT : {
			script  => 'fake',
			name    => 'Fake source',
			candidates => [
				{
					title     => 'Test Song',
					artist    => 'Test Artist',
					album     => 'Test Album',
					lyricText => '[00:01.00]Fake line',
					location  => 'fake:1',
					fileType  => '',
					parsed    => 0,
				},
			],
		};

		open(my $fh, '>:raw', $output) or die $!;
		print {$fh} JSON::PP->new->utf8->encode($result);
		close $fh;
	}

	return bless { done => 1 }, $class;
}

sub alive { 0 }
sub wait { 0 }
sub terminate { 1 }

1;
