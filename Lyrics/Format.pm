package Plugins::MusicArtistInfo::Lyrics::Format;

use strict;

use Slim::Utils::Prefs;

# Optional bridges to external formatter plugins.  MAI works without them;
# the template-language selector disables engines which are unavailable.

my $prefs = preferences('plugin.musicartistinfo');
my %API;

sub _plugin_api {
	my ($id, $plugin, $module) = @_;

	my $loaded = eval {
		require Slim::Utils::PluginManager;
		Slim::Utils::PluginManager->isEnabled($id)
			|| Slim::Utils::PluginManager->isEnabled($plugin);
	};

	return unless $loaded;

	$API{$module} ||= eval {
		require $module;
		$module->available ? $module : undef;
	};

	return $API{$module};
}

sub _fb2k_api {
	my $loaded = eval {
		require Slim::Utils::PluginManager;
		Slim::Utils::PluginManager->isEnabled('Plugins::FB2KFormat::Plugin');
	};
	return unless $loaded;

	$API{'Plugins::FB2KFormat::API'} ||= eval {
		require Plugins::FB2KFormat::API;
		Plugins::FB2KFormat::API->available ? 'Plugins::FB2KFormat::API' : undef;
	};

	return $API{'Plugins::FB2KFormat::API'};
}

sub _xslate_api {
	my $loaded = eval {
		require Slim::Utils::PluginManager;
		Slim::Utils::PluginManager->isEnabled('Plugins::TextXslate::Plugin');
	};
	return unless $loaded;

	$API{'Plugins::TextXslate::API'} ||= eval {
		require Plugins::TextXslate::API;
		Plugins::TextXslate::API->available ? 'Plugins::TextXslate::API' : undef;
	};

	return $API{'Plugins::TextXslate::API'};
}

sub language {
	my ($class) = @_;
	my $lang = $prefs->get('templateLanguage') || 'lms';
	$lang = 'lms' unless $lang =~ /^(?:lms|fb2k|textxslate)$/;
	return $lang;
}

sub available_for {
	my ($class, $lang) = @_;
	$lang ||= $class->language;
	return 1 if $lang eq 'lms';
	return 1 if $lang eq 'fb2k' && $class->available;
	return 1 if $lang eq 'textxslate' && $class->textxslate_available;
	return 0;
}

sub available {
	return _fb2k_api ? 1 : 0;
}

sub textxslate_available {
	return _xslate_api ? 1 : 0;
}

sub format {
	my ($class, $fields, $template, $lang) = @_;

	$lang ||= $class->language;
	$fields ||= {};

	if ( $lang eq 'fb2k' ) {
		my $api = _fb2k_api;
		return { text => '', error => 'FB2KFormat plugin is not available' } unless $api;
		return $api->format($fields, $template);
	}
	if ( $lang eq 'textxslate' ) {
		my $api = _xslate_api;
		return { text => '', error => 'TextXslate plugin or Text::Xslate is not available' } unless $api;
		return $api->format($fields, $template);
	}

	return { text => '', error => 'LMS formatting is not a template engine' };
}

sub fields_for_track {
	my ($class, $track, $lang) = @_;

	$lang ||= $class->language;
	my $api = $lang eq 'textxslate' ? _xslate_api : _fb2k_api;
	return $api->fields_for_track($track) if $api;
	return {};
}

sub format_track {
	my ($class, $track, $template, $lang) = @_;

	$lang ||= $class->language;
	return { text => '', error => 'LMS formatting is not a template engine' }
		if $lang eq 'lms';

	my $api = $lang eq 'textxslate' ? _xslate_api : _fb2k_api;
	return { text => '', error => 'Selected template plugin is not available' } unless $api;

	return $api->format_track($track, $template);
}

sub format_fields {
	my ($class, $fields, $template, $lang) = @_;
	return $class->format($fields, $template, $lang);
}

1;
