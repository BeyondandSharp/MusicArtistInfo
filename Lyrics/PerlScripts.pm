package Plugins::MusicArtistInfo::Lyrics::PerlScripts;

use strict;

use Digest::MD5 qw(md5_hex);
use Encode qw(FB_CROAK);
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

my %SCRIPT_CACHE;

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
	return 1;
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

sub script_sources {
	my ($class) = @_;

	return [] unless $class->enabled;

	my @out;
	foreach my $file (@{ $class->scripts }) {
		my $name = basename($file);
		push @out, {
			id    => "PerlScripts:$name",
			file  => $file,
			label => "Perl: $name",
		};
	}

	return \@out;
}

sub script_path {
	my ($class, $name) = @_;

	$name = $class->normalize_name($name);
	return unless defined $name;

	my $folder = $class->folder;
	return catfile($folder, $name);
}

sub normalize_name {
	my ($class, $name) = @_;

	return unless defined $name;
	$name =~ s/^\s+//;
	$name =~ s/\s+$//;
	return if $name eq '';
	return if $name =~ m{[/\\\x00]};
	return if $name =~ /^\.\.?$/;
	$name .= '.pl' unless $name =~ /\.pl$/i;
	return if $name !~ /\.pl$/i;
	return if length($name) > 200;
	return $name;
}

sub read_script {
	my ($class, $name) = @_;

	my $path = $class->script_path($name);
	return { error => 'Invalid script name' } unless $path;
	return { error => 'Script not found' } unless -f $path;

	my $raw = '';
	if ( open(my $fh, '<:raw', $path) ) {
		local $/;
		$raw = <$fh>;
		close $fh;
	}
	else {
		return { error => "Could not read script: $!" };
	}

	my $content = eval { Encode::decode('UTF-8', $raw, FB_CROAK) };
	$content = $raw if !defined $content || $@;

	return {
		id      => "PerlScripts:$name",
		name    => $name,
		file    => $path,
		content => $content,
	};
}

sub save_script {
	my ($class, $old_name, $name, $content) = @_;

	$name = $class->normalize_name($name);
	return { error => 'Invalid script name' } unless $name;

	$content = '' unless defined $content;
	return { error => 'Script is too large' } if length($content) > $MAX_SCRIPT_SIZE;

	my $folder = $class->folder;
	my $target = catfile($folder, $name);
	my $old_path;
	if ( defined $old_name && $old_name ne '' ) {
		my $old_norm = $class->normalize_name($old_name);
		$old_path = $old_norm ? catfile($folder, $old_norm) : undef;
	}

	return { error => 'Another script already uses that name' }
		if $target ne ($old_path || '') && -e $target;

	unless ( -d $folder ) {
		require File::Path;
		eval { File::Path::mkpath($folder) };
	}

	my $encoded = Encode::encode('UTF-8', $content);
	my $tmp = $target . '.tmp.' . $$;
	if ( open(my $fh, '>:raw', $tmp) ) {
		print $fh $encoded;
		close $fh;
	}
	else {
		return { error => "Could not write script: $!" };
	}

	if ( $old_path && $old_path ne $target && -e $old_path ) {
		unless ( rename($old_path, $target) ) {
			unlink $tmp;
			return { error => "Could not rename script: $!" };
		}
	}

	unless ( rename($tmp, $target) ) {
		unlink $tmp;
		return { error => "Could not save script: $!" };
	}

	return {
		id      => "PerlScripts:$name",
		name    => $name,
		file    => $target,
		content => $content,
	};
}

sub delete_script {
	my ($class, $name) = @_;

	my $path = $class->script_path($name);
	return { error => 'Invalid script name' } unless $path;
	return { error => 'Script not found' } unless -f $path;
	unlink($path) or return { error => "Could not delete script: $!" };
	return { ok => 1, id => "PerlScripts:" . $class->normalize_name($name) };
}

sub default_script_content {
	return <<'SCRIPT';
# Custom lyrics source.
# Return a hash with a name and a getLyrics callback.
# The callback receives the lookup arguments and an async callback.
#
# return {
#     name => 'My source',
#     getLyrics => sub {
#         my ($args, $cb) = @_;
#         # ... fetch lyrics asynchronously ...
#         $cb->({ lyrics => "..." });
#     },
# };
SCRIPT
}

sub getLyrics {
	my ($class, $args, $cb, $file) = @_;

	return $cb->() unless $class->enabled;

	my $scripts = $file ? [ $file ] : $class->scripts;
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
	my ($class, $args, $cb, $onCandidate, $file) = @_;

	return $cb->([]) unless $class->enabled;

	my $scripts = $file ? [ $file ] : $class->scripts;
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
				$result->{title}  ||= $result->{song};
				push @candidates, $result;
				$onCandidate->($result) if $onCandidate;
			}

			$next->($finished);
		});
	};

	$next->(sub { $cb->(\@candidates) });
}

sub _load_script {
	my ($class, $file) = @_;

	my $mtime = (stat($file))[9] || 0;
	my $cached = $SCRIPT_CACHE{$file};
	return $cached->{definition}
		if $cached && $cached->{mtime} == $mtime;

	# Load every script into its own package.  Without this, helper
	# subroutines with the same name in two scripts would overwrite each
	# other, and reloading a script would emit "Subroutine redefined".
	my $package = 'Plugins::MusicArtistInfo::Lyrics::PerlScripts::Source_'
		. md5_hex($file . ':' . $mtime);

	my $source;
	if ( open(my $fh, '<:raw', $file) ) {
		local $/;
		$source = <$fh>;
		close $fh;
	}

	unless ( defined $source ) {
		$log->debug("Custom lyrics script $file could not be read: $!");
		return;
	}

	my $definition = eval "package $package;\n" . $source;
	my $error = $@;

	if ( !$definition ) {
		$error ||= $! || 'script returned no value';
		$log->debug("Custom lyrics script $file could not be loaded: $error");
		return;
	}

	$SCRIPT_CACHE{$file} = {
		mtime      => $mtime,
		definition => $definition,
	};

	return $definition;
}

sub _run_script {
	my ($class, $file, $args, $cb) = @_;

	my $script = $class->_load_script($file);
	return $cb->() unless $script;

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
