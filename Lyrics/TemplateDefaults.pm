package Plugins::MusicArtistInfo::Lyrics::TemplateDefaults;

use strict;

sub defaults_for {
	my ($class, $language) = @_;

	return {
		path_format  => '$directory_path(%path%)',
		file_format   => '',
		search_title  => '%title%',
		search_artist => '[%artist%]',
	}
	if !defined $language || $language eq 'lms';

	return {
		path_format  => '$directory_path(%path%)',
		file_format   => '%artist% - %title%',
		search_title  => '%title%',
		search_artist => '[%artist%]',
	}
	if $language eq 'fb2k';

	return {
		path_format  => '<: $directory :>',
		file_format   => '<: $artist :> - <: $title :>',
		search_title  => '<: $title :>',
		search_artist => '<: $artist :>',
	}
	if $language eq 'textxslate';

	return $class->defaults_for('lms');
}

sub path_format { return shift->defaults_for(shift)->{path_format} }
sub file_format { return shift->defaults_for(shift)->{file_format} }
sub search_title { return shift->defaults_for(shift)->{search_title} }
sub search_artist { return shift->defaults_for(shift)->{search_artist} }

1;
