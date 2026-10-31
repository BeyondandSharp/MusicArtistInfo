package Plugins::MusicArtistInfo::Lyrics::MaterialSkin;

use strict;

use File::Basename qw(dirname);
use File::Path qw(make_path);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');

my $BEGIN_MARKER = '/* BEGIN MusicArtistInfo lyrics chooser (managed by MusicArtistInfo) */';
my $END_MARKER   = '/* END MusicArtistInfo lyrics chooser */';

sub material_enabled {
	return 0 unless eval { require Slim::Utils::PluginManager; 1 };

	return eval { Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin') } ? 1 : 0;
}

sub custom_js_path {
	return Slim::Utils::Prefs::dir() . '/material-skin/custom.js';
}

sub _block {
	my $version = eval { $Plugins::MusicArtistInfo::Plugin::VERSION } || '1.30.1';

	return $BEGIN_MARKER . "\n"
		. "(function(){\n"
		. "  if (window.__MAI_MATERIAL_LOADER) return;\n"
		. "  window.__MAI_MATERIAL_LOADER = true;\n"
		. "  var s = document.createElement('script');\n"
		. "  s.src = '/plugins/MusicArtistInfo/html/materialLyricsChooser.js?v=$version';\n"
		. "  s.async = true;\n"
		. "  document.head.appendChild(s);\n"
		. "})();\n"
		. $END_MARKER . "\n";
}

sub _strip_block {
	my $content = shift || '';

	$content =~ s/\Q$BEGIN_MARKER\E.*?\Q$END_MARKER\E\s*//s;

	return $content;
}

sub sync {
	my ($class) = @_;

	return unless main::WEBUI;

	my $enabled = $prefs->get('integrateMaterialSkin') && $class->material_enabled;
	my $path    = $class->custom_js_path();

	return unless $enabled || -e $path;

	my $content = '';
	if ( -e $path ) {
		if ( open(my $fh, '<:raw', $path) ) {
			local $/;
			$content = <$fh> || '';
			close $fh;
		}
	}

	my $new = _strip_block($content);

	if ($enabled) {
		make_path(dirname($path)) unless -d dirname($path);
		$new .= "\n" if $new ne '' && $new !~ /\n\z/;
		$new .= $class->_block;
	}

	return if $new eq $content;

	my $fh;
	unless ( open($fh, '>:raw', $path) ) {
		$log->warn("Could not update Material Skin custom.js: $!");
		return;
	}

	print {$fh} $new;
	close $fh;

	main::INFOLOG && $log->is_info && $log->info("Updated Material Skin lyrics chooser integration");

	return 1;
}

sub remove {
	my ($class) = @_;

	my $path = $class->custom_js_path();
	return unless -e $path;

	my $content = '';
	if ( open(my $fh, '<:raw', $path) ) {
		local $/;
		$content = <$fh> || '';
		close $fh;
	}

	my $new = _strip_block($content);
	return if $new eq $content;

	if ( open(my $fh, '>:raw', $path) ) {
		print {$fh} $new;
		close $fh;
	}

	return 1;
}

1;
