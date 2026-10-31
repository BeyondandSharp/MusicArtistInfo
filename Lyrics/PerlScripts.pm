package Plugins::MusicArtistInfo::Lyrics::PerlScripts;

use strict;

use File::Basename qw(basename);
use File::Spec::Functions qw(catdir catfile);
use Time::HiRes qw(time);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

my $log    = logger('plugin.musicartistinfo');
my $prefs  = preferences('plugin.musicartistinfo');

my $PER_SCRIPT_TIMEOUT = 10;
my $TOTAL_TIMEOUT      = 25;
my $MAX_SCRIPTS        = 20;
my $MAX_SCRIPT_SIZE    = 1024 * 1024;

# Custom lyrics sources are ordinary Perl scripts loaded into the LMS process.
# A script is a *.pl file returning either a coderef, or a hashref:
#
#   return {
#       name => 'My source',
#       getLyrics => sub {
#           my ($args, $cb) = @_;
#           ...
#           $cb->({ lyrics => "...", source => 'My source' });
#       },
#   };
#
# Scripts are trusted code and must use asynchronous callbacks.  A script
# which blocks LMS cannot be interrupted safely.

sub enabled {
	my ($class) = @_;
	return $prefs->get('enableCustomLyricsSources') ? 1 : 0;
}

sub folder {
	my ($class) = @_;
	my $folder = $prefs->get('customLyricsSourcesFolder');
	return defined $folder && $folder ne '' ? $folder : $class->default_folder;
}

sub default_folder {
	my ($class) = @_;
	return catdir(Slim::Utils::Prefs::dir(), 'musicartistinfo', 'lyricsScripts');
}

sub scripts {
	my ($class) = @_;

	my $folder = $class->folder;
	return [] unless defined $folder && -d $folder;

	my $dh;
	opendir($dh, $folder) or return [];
	my @files = sort grep { /\.pl$/i } readdir($dh);
	closedir($dh);

	my @scripts;
	foreach my $name (@files) {
		my $file = catfile($folder, $name);
		next unless -f $file;
		next if -s $file > $MAX_SCRIPT_SIZE;
		push @scripts, $file;
		last if @scripts >= $MAX_SCRIPTS;
	}

	return \@scripts;
}

sub getLyrics {
	my ($class, $args, $cb) = @_;

	return $cb->() unless $class->enabled;

	my $scripts = $class->scripts;
	return $cb->() unless @$scripts;

	my $deadline = time() + $TOTAL_TIMEOUT;
	my $index = 0;

	my $next;
	$next = sub {
		my $finished = shift;

		return $finished->() if $index >= @$scripts || time() >= $deadline;

		my $file = $scripts->[$index++];

		$class->_run_script($file, $args, sub {
			my $result = shift;

			if ( _valid_result($result) ) {
				$result->{source} ||= basename($file);
				$result->{song}   ||= $args->{title};
				$result->{artist} ||= $args->{artist};
				return $finished->($result);
			}

			$next->($finished);
		});
	};

	$next->(sub { $cb->(shift) });
}

sub getCandidates {
	my ($class, $args, $cb, $onCandidate) = @_;

	return $cb->([]) unless $class->enabled;

	my $scripts = $class->scripts;
	return $cb->([]) unless @$scripts;

	my $deadline = time() + $TOTAL_TIMEOUT;
	my $index = 0;
	my @candidates;

	my $next;
	$next = sub {
		my $finished = shift;

		return $finished->() if $index >= @$scripts || time() >= $deadline;

		my $file = $scripts->[$index++];

		$class->_run_script($file, $args, sub {
			my $result = shift;

			if ( _valid_result($result) ) {
				$result->{source} ||= basename($file);
				$result->{song}   ||= $args->{title};
				$result->{artist} ||= $args->{artist};
				push @candidates, $result;
				$onCandidate->($result) if $onCandidate;
			}

			$next->($finished);
		});
	};

	$next->(sub { $cb->(\@candidates) });
}

sub _run_script {
	my ($class, $file, $args, $cb) = @_;

	my $script = do $file;

	if ( !$script ) {
		my $error = $@ || $! || 'script returned no value';
		$log->debug("Custom lyrics script $file could not be loaded: $error");
		return $cb->();
	}

	my $name;
	my $handler;

	if ( ref $script eq 'CODE' ) {
		$name    = basename($file);
		$handler = $script;
	}
	elsif ( ref $script eq 'HASH' && ref $script->{getLyrics} eq 'CODE' ) {
		$name    = $script->{name} || basename($file);
		$handler = $script->{getLyrics};
	}
	else {
		$log->debug("Custom lyrics script $file must return a coderef or { name, getLyrics }");
		return $cb->();
	}

	my $done = 0;
	my $token = {};
	my $timer;

	my $finish;
	$finish = sub {
		my $result = shift;
		return if $done++;
		Slim::Utils::Timers::killTimers($token, $timer) if $timer;
		$cb->($result);
	};

	$timer = sub { $finish->() };
	Slim::Utils::Timers::setTimer($token, time() + $PER_SCRIPT_TIMEOUT, $timer);

	my $ok = eval {
		$handler->($args, $finish);
		1;
	};

	unless ($ok) {
		my $error = $@ || 'unknown error';
		$log->debug("Custom lyrics script $file failed: $error");
		$finish->();
	}

	return;
}

sub _valid_result {
	my $result = shift;
	return 0 unless ref $result eq 'HASH';
	return 0 unless defined $result->{lyrics} && $result->{lyrics} =~ /\S/;
	return 1;
}

1;
