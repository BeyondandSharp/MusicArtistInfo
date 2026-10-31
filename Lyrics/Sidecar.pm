package Plugins::MusicArtistInfo::Lyrics::Sidecar;

use strict;

use Encode ();
use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);
use File::Temp ();

# Writes lyrics next to a local audio file.  No Slim dependencies, so it can
# be tested outside of LMS.

sub path_for {
	my ($class, $audioPath, $basename) = @_;

	return unless defined $audioPath && defined $basename && $basename ne '';

	# Never allow a "filename" to escape the song's folder
	return if $basename =~ m{[/\\]} || $basename eq '.' || $basename eq '..';

	return catfile(dirname($audioPath), $basename);
}

sub normalize {
	my ($class, $lyrics) = @_;

	$lyrics = '' unless defined $lyrics;
	$lyrics =~ s/^\x{feff}//;
	$lyrics =~ s/\\n/\n/g;
	$lyrics =~ s/\r\n/\n/g;
	$lyrics =~ s/\r/\n/g;
	$lyrics =~ s/\n*\z/\n/;

	return $lyrics;
}

sub save {
	my ($class, $audioPath, $basename, $lyrics, $opts) = @_;

	return { error => 'Missing audio path' } unless defined $audioPath && $audioPath ne '';
	return { error => 'Audio file not found' } unless -f $audioPath;

	my $file = $class->path_for($audioPath, $basename);
	return { error => 'Invalid lyrics filename' } unless $file;

	return $class->save_path($file, $lyrics, $opts);
}

sub save_path {
	my ($class, $file, $lyrics, $opts) = @_;

	$opts ||= {};

	return { error => 'Missing lyrics target' } unless defined $file && $file ne '';

	my $dir = dirname($file);
	return { error => "Lyrics folder not writable: $dir" }
		unless -d $dir && -w $dir;

	return { skipped => 'exists', file => $file }
		if -e $file && !$opts->{overwrite};

	my $text = $class->normalize($lyrics);
	return { error => 'Empty lyrics' } unless $text =~ /\S/;

	my $encoded = Encode::encode('UTF-8', $text);
	$encoded = "\xEF\xBB\xBF" . $encoded if $opts->{bom};

	my $tmp = eval {
		File::Temp->new(
			DIR      => $dir,
			TEMPLATE => '.mai-lyrics-XXXXXX',
			SUFFIX   => '.tmp',
			UNLINK   => 1,
		);
	};

	return { error => "Could not create temporary lyrics file: $@" } unless $tmp;

	binmode $tmp, ':raw';

	unless ( print {$tmp} $encoded ) {
		return { error => "Could not write temporary lyrics file: $!" };
	}

	unless ( close $tmp ) {
		return { error => "Could not close temporary lyrics file: $!" };
	}

	my $tmpFile = $tmp->filename;

	unless ( rename($tmpFile, $file) ) {
		# Windows does not rename over an existing file
		my $renameError = $!;
		unlink $file if -e $file;

		unless ( rename($tmpFile, $file) ) {
			return { error => "Could not save lyrics to $file: $renameError / $!" };
		}
	}

	return { file => $file };
}

1;
