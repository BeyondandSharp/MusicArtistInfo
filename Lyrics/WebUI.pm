package Plugins::MusicArtistInfo::Lyrics::WebUI;

use strict;

use JSON::PP ();

# Builds the HTML fragment shown in the LMS web UI's lyrics view.  The
# fragment is injected as the content of a type=textarea item, which LMS
# renders without HTML escaping (see HTML/*/xmlbrowser.html).  Keep this
# module free of LMS dependencies and make sure the generated markup is a
# single line: the template filter html_line_break() would otherwise turn
# newlines into <br /> tags.

my $DEFAULT_ENDPOINT = '/plugins/MusicArtistInfo/lyrics';
my $DEFAULT_SCRIPT   = '/plugins/MusicArtistInfo/html/lyricsChooser.js';

sub escape_html {
	my ($class, $text) = @_;

	$text = '' unless defined $text;
	$text =~ s/&/&amp;/g;
	$text =~ s/</&lt;/g;
	$text =~ s/>/&gt;/g;
	$text =~ s/"/&quot;/g;
	$text =~ s/'/&#39;/g;

	return $text;
}

sub _attr {
	my ($class, $text) = @_;

	return $class->escape_html($text);
}

sub build {
	my ($class, %args) = @_;

	my $strings = ref $args{strings} eq 'HASH' ? $args{strings} : {};

	my $lyrics = defined $args{lyrics} && $args{lyrics} =~ /\S/ ? $args{lyrics} : '';
	my $error  = defined $args{error}  ? $args{error} : '';

	my $text = $lyrics ne '' ? $lyrics : $error;

	$text = $class->escape_html($text);
	$text =~ s/\r\n?/\n/g;
	$text =~ s/\n/<br \/>/g;

	my $buttonLabel = $strings->{choose} || 'Choose lyrics';
	$buttonLabel = $class->escape_html($buttonLabel);

	my $endpoint = $args{endpoint} || $DEFAULT_ENDPOINT;
	my $script   = $args{script}   || $DEFAULT_SCRIPT;

	my $stringsJson = eval { JSON::PP->new->canonical(1)->encode($strings) };
	$stringsJson = '{}' if !defined $stringsJson || $@;
	$stringsJson = $class->_attr($stringsJson);

	my $onclick = q{(function(b){if(window.MAILyrics){return window.MAILyrics.open(b);}var s=document.createElement('script');s.src=b.getAttribute('data-script');s.onload=function(){window.MAILyrics.open(b);};s.onerror=function(){if(window.console){console.error('MusicArtistInfo: failed to load lyrics chooser');}};document.head.appendChild(s);})(this)};

	my $html = '';
	$html .= '<div class="maiLyricsWrapper">';
	$html .= '<div id="maiLyricsText" class="maiLyricsText" style="white-space: pre-wrap">' . $text . '</div>';
	$html .= '<div class="maiLyricsActions">';
	$html .= '<button type="button" class="maiLyricsChooserButton stdclick"';
	$html .= ' data-endpoint="' . $class->_attr($endpoint) . '"';
	$html .= ' data-script="' . $class->_attr($script) . '"';
	$html .= ' data-track-id="' . $class->_attr($args{track_id} || '') . '"';
	$html .= ' data-url="' . $class->_attr($args{url} || '') . '"';
	$html .= ' data-title="' . $class->_attr($args{title} || '') . '"';
	$html .= ' data-artist="' . $class->_attr($args{artist} || '') . '"';
	$html .= ' data-album="' . $class->_attr($args{album} || '') . '"';
	$html .= ' data-duration="' . $class->_attr($args{duration} || '') . '"';
	$html .= ' data-player="' . $class->_attr($args{player} || '') . '"';
	$html .= ' data-strings="' . $stringsJson . '"';
	$html .= ' onclick="' . $onclick . '">' . $buttonLabel . '</button>';
	$html .= '<span id="maiLyricsPageStatus" class="maiLyricsStatus"></span>';
	$html .= '</div>';
	$html .= '</div>';

	return $html;
}

1;
