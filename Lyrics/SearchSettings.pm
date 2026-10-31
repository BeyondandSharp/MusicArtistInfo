package Plugins::MusicArtistInfo::Lyrics::SearchSettings;

use strict;

use JSON::PP ();

use Slim::Utils::Prefs;

use Plugins::MusicArtistInfo::Lyrics::Format;
use Plugins::MusicArtistInfo::Lyrics::ScriptRunner;
use Plugins::MusicArtistInfo::Lyrics::Scripts;

my $prefs = preferences('plugin.musicartistinfo');

sub filters {
	my $class = shift;
	my $raw = $prefs->get('lyricsSearchFilters');
	return [] unless defined $raw && $raw ne '';
	my $decoded = eval { JSON::PP->new->decode($raw) };
	return ref $decoded eq 'ARRAY' ? $decoded : [];
}

sub processing {
	my $class = shift;
	my $raw = $prefs->get('lyricsFieldProcessing');
	return [] unless defined $raw && $raw ne '';
	my $decoded = eval { JSON::PP->new->decode($raw) };
	return ref $decoded eq 'ARRAY' ? $decoded : [];
}

sub skip_auto_search {
	my ($class, $args) = @_;

	my $result = $class->_run_script($args || {});
	return $result && $result->{skip} ? 1 : 0;
}

sub _run_script {
	my ($class, $args) = @_;

	my $script = $prefs->get('lyricsSearchScript');
	$script = Plugins::MusicArtistInfo::Lyrics::Scripts->default_search_script
		if !defined $script || $script eq '';
	my $path = $prefs->get('lyricsSearchScriptPath') || '';

	return Plugins::MusicArtistInfo::Lyrics::ScriptRunner->run(
		$script,
		$path,
		{
			title  => $args->{title}  || '',
			artist => $args->{artist} || '',
			album  => $args->{album}  || '',
			url    => $args->{url}    || '',
			skip   => 0,
		},
	);
}


sub prepare_args {
	my ($class, $args) = @_;

	return $args unless ref $args eq 'HASH';

	my %out = %$args;
	my $title  = defined $out{title}  ? $out{title}  : '';
	my $artist = defined $out{artist} ? $out{artist} : '';

	if ( $prefs->get('lyricsCustomSearchFields') && $prefs->get('useFb2kFormat') && Plugins::MusicArtistInfo::Lyrics::Format->available ) {
		my $fields = {
			title  => $title,
			artist => $artist,
			album  => $out{album} || '',
			path   => $out{url} || $out{path} || '',
		};

		$title = _format_field($fields, $prefs->get('lyricsSearchTitleFormat') || '%title%', $title);
		$artist = _format_field($fields, $prefs->get('lyricsSearchArtistFormat') || '[%artist%]', $artist);
	}

	my $script = $class->_run_script({
		%out,
		title  => $title,
		artist => $artist,
	});

	if ( $script && !$script->{error} ) {
		$title  = $script->{title}  if defined $script->{title};
		$artist = $script->{artist} if defined $script->{artist};
		$out{skip} = 1 if $script->{skip};
	}

	$out{title}  = $title  if defined $title;
	$out{artist} = $artist if defined $artist;

	return \%out;
}

sub _format_field {
	my ($fields, $template, $fallback) = @_;

	my $result = Plugins::MusicArtistInfo::Lyrics::Format->format_fields($fields, $template);
	return $fallback if !$result || $result->{error} || !defined $result->{text};
	return $result->{text} ne '' ? $result->{text} : $fallback;
}

sub _apply_rule {
	my ($rule, $text) = @_;

	$text = '' unless defined $text;
	my $op = $rule->{op} || '';
	my $p1 = defined $rule->{param1} ? $rule->{param1} : '';
	my $p2 = defined $rule->{param2} ? $rule->{param2} : '';

	if ( $op eq 'remove_chars' && $p1 ne '' ) {
		my %chars = map { $_ => 1 } split //, $p1;
		$text = join '', grep { !$chars{$_} } split //, $text;
	}
	elsif ( $op eq 'regex_remove' && $p1 ne '' ) {
		eval { $text =~ s/$p1//g };
	}
	elsif ( $op eq 'regex_replace' && $p1 ne '' ) {
		eval { $text =~ s/$p1/$p2/g };
	}
	elsif ( $op eq 'simplified' || $op eq 'traditional' ) {
		if ( eval { require Plugins::MusicArtistInfo::Lyrics::HanConvert; 1 } ) {
			$text = Plugins::MusicArtistInfo::Lyrics::HanConvert->convert($text, $op)
				if Plugins::MusicArtistInfo::Lyrics::HanConvert->available;
		}
	}

	return $text;
}

1;
