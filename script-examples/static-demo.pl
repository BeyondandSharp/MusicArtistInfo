# A deterministic source for testing the custom-script provider.
return {
	name => 'Static Perl demo',
	getLyrics => sub {
		my ($args, $cb) = @_;

		my $title = defined $args->{title} ? $args->{title} : 'Unknown';
		$cb->({
			lyrics => "[00:01.00]Perl source for $title\n[00:02.00]Second line\n",
			source => 'Static Perl demo',
		});
	},
};
