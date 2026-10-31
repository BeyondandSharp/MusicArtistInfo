package Plugins::MusicArtistInfo::Parser::HTML;

use strict;

use File::Basename qw(dirname basename);
use File::Spec::Functions qw(catfile);
use HTML::TreeBuilder;

use Plugins::MusicArtistInfo::Text;

sub parse {
	my ($class, $path) = @_;

	my $html = Plugins::MusicArtistInfo::Text->read_file($path);
	$html = '' unless defined $html;

	return HTML::TreeBuilder->new_from_content($html);
}

sub renderAsHTML {
	my ($class, $httpClient, $response, $path) = @_;

	my $baseDir = dirname($path);
	my $tree = $class->parse($path);

	# links
	foreach my $link ( $tree->look_down('_tag', 'a') ) {
		$link->attr('href', _proxiedUrl($baseDir, $link->attr('href')));
	}

	# style sheets
	foreach my $link ( $tree->look_down('_tag', 'link', 'rel', 'stylesheet') ) {
		$link->attr('href', _proxiedUrl($baseDir, $link->attr('href')));
	}

	# images
	foreach my $link ( $tree->look_down('_tag', 'img') ) {
		$link->attr('src', _proxiedUrl($baseDir, $link->attr('src')));
	}

	$response->content_type('text/html');
	$response->header('Connection' => 'close');
	$response->content($tree->as_HTML());

	$httpClient->send_response($response);
	Slim::Web::HTTP::closeHTTPSocket($httpClient);

	return;
}

sub _proxiedUrl {
	my ($baseDir, $url) = @_;

	# we only need to re-write relative paths up the folder hierarchy
	if ($url && $url =~ /^\.\./) {
		require Cwd;
		my $absolutePath = Cwd::abs_path(catfile($baseDir, $url));
		$url = Plugins::MusicArtistInfo::LocalFile::_proxiedUrl(dirname($absolutePath), basename($absolutePath));
	}

	return $url;
}

1;