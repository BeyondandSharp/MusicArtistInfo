package Plugins::MusicArtistInfo::Lyrics::ScriptRunner;

use strict;

use Digest::MD5 qw(md5_hex);
use File::Spec::Functions qw(catfile);

# Runs a small user-supplied Perl snippet for search in//lyrics processing.
# The snippet receives lexical variables (title, artist, album, url, lyrics,
# skip) and may modify them.  It is trusted code and runs inside LMS.

sub run {
	my ($class, $source, $path, $vars) = @_;

	$vars ||= {};
	return { error => 'No script' } if !defined $source && !defined $path;

	my $code = '';
	if ( defined $path && $path ne '' && -d $path ) {
		my $dh;
		if ( opendir($dh, $path) ) {
			my @files = sort grep { /\.pl$/i } readdir($dh);
			closedir $dh;
			$path = catfile($path, $files[0]) if @files;
		}
	}
	if ( defined $path && $path ne '' && -r $path ) {
		if ( open(my $fh, '<:raw', $path) ) {
			local $/;
			$code = <$fh>;
			close $fh;
		}
		else {
			return { error => "Could not read script $path: $!" };
		}
	}
	elsif ( defined $source ) {
		$code = $source;
	}

	return { error => 'Empty script' } if !defined $code || $code !~ /\S/;

	my @names = qw(title artist album url lyrics skip);
	my $package = 'Plugins::MusicArtistInfo::Lyrics::ScriptRunner::' . md5_hex($code . rand());

	my $prefix = "package $package;\nuse strict;\nuse warnings;\n"
		. "my \$ctx = \$Plugins::MusicArtistInfo::Lyrics::ScriptRunner::CONTEXT;\n";
	foreach my $name (@names) {
		$prefix .= "my \$$name = \$ctx->{'$name'};\n";
	}

	my $suffix = "\nreturn {\n";
	foreach my $name (@names) {
		$suffix .= "  $name => \$$name,\n";
	}
	$suffix .= "  skip => (\$skip ? 1 : 0),\n};\n";

	my $result;
	{
		local $Plugins::MusicArtistInfo::Lyrics::ScriptRunner::CONTEXT = $vars;
		$result = eval $prefix . $code . $suffix;
		if ($@) {
			return { error => $@ };
		}
	}

	return $result && ref $result eq 'HASH'
		? { %$result, error => '' }
		: { error => 'Script returned no result' };
}

1;
