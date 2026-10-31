package Plugins::MusicArtistInfo::Lyrics::Format;

use strict;

# Optional bridge to the FB2KFormat plugin.  MAI works without that plugin;
# the switch in the lyrics settings is only enabled when the API is present.

my $loaded;

sub _api {
	return unless eval {
		require Slim::Utils::PluginManager;
		Slim::Utils::PluginManager->isEnabled('Plugins::FB2KFormat::Plugin');
	};

	$loaded ||= eval {
		require Plugins::FB2KFormat::API;
		Plugins::FB2KFormat::API->available ? 'Plugins::FB2KFormat::API' : undef;
	};

	return $loaded;
}

sub available {
	return _api ? 1 : 0;
}

sub format {
	my ($class, $fields, $template) = @_;

	my $api = _api;
	return { text => '', error => 'FB2KFormat plugin is not available' } unless $api;

	$fields ||= {};
	return $api->format($fields, $template);
}

sub fields_for_track {
	my ($class, $track) = @_;

	my $api = _api;
	return $api->fields_for_track($track) if $api;

	return {};
}

sub format_track {
	my ($class, $track, $template) = @_;

	my $api = _api;
	return { text => '', error => 'FB2KFormat plugin is not available' } unless $api;

	return $api->format_track($track, $template);
}

sub format_fields {
	my ($class, $fields, $template) = @_;
	return $class->format($fields, $template);
}

1;
