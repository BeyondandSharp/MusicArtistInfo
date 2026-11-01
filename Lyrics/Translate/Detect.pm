package Plugins::MusicArtistInfo::Lyrics::Translate::Detect;

use strict;

# Language detection for the lyrics translation pipeline.  The confidence that
# a text already is in the target language comes from the language detection
# plugin's suite of detectors (lingua + fastlang), weighted with the configured
# weights.  When the suite cannot decide, a caller supplied LLM detector
# decides.
#
# Detection levels:
#   1. injected suite detector:  $opts->{suite_detect}->($text, $target, $cb)
#   2. Plugins::LangID::API->detect_suite, if that plugin is available
#   3. caller supplied LLM detector: $opts->{llm_detect}->($text, $cb)
#      with $cb->($confidence, $error)
#
# Suite result contract:
#   { lingua   => { confidence => 0..1, language => 'zh', name => 'Chinese' } | undef,
#     fastlang => { confidence => 0..1, language => 'zh', name => 'Chinese' } | undef,
#     error    => '...' | undef }
#
# The module itself has no LMS dependency: the plugin is required lazily and
# guarded by eval, so everything can be unit tested outside of LMS.  CJK
# labels are written as \x{...} escapes to keep this source file ASCII (plugin
# files are loaded as bytes by LMS).
#
# Public entry points accept both class method and plain function calls:
#
#   Plugins::MusicArtistInfo::Lyrics::Translate::Detect->detect_target(...)
#   Plugins::MusicArtistInfo::Lyrics::Translate::Detect::detect_target(...)

my $suite_checked = 0;
my $suite_package;

# Prompt labels for the languages the settings offer.
my %TARGET_LABELS = (
	'zh-Hans'  => "\x{7B80}\x{4F53}\x{4E2D}\x{6587}",   # Simplified Chinese
	'zh-Hant'  => "\x{7E41}\x{9AD4}\x{4E2D}\x{6587}",   # Traditional Chinese
	en         => 'English',
	ja         => "\x{65E5}\x{672C}\x{8A9E}",            # Japanese
	ko         => "\x{D55C}\x{AD6D}\x{C5B4}",            # Korean
);

# Accept both $class->method(...) and method(...) calls.  Only a first
# argument which looks like this class name is stripped.
sub _strip_class {
	my @args = @_;

	shift @args
		if @args
		&& defined $args[0]
		&& !ref $args[0]
		&& $args[0] =~ /^Plugins::MusicArtistInfo::Lyrics::Translate::Detect(?:::|\z)/;

	return @args;
}

# Forget the memoized language detection plugin lookup.  Only needed by tests
# and by callers which want to pick up a plugin installed at runtime.
sub reset {
	_strip_class(@_);

	$suite_checked = 0;
	$suite_package = undef;

	return 1;
}

# Package name of the language detection plugin if it is installed, available
# and provides the suite API; undef otherwise.  The lookup is memoized.
sub suite_detector {
	_strip_class(@_);

	return $suite_package if $suite_checked;

	$suite_checked = 1;
	$suite_package = eval {
		require Plugins::LangID::API;
		Plugins::LangID::API->can('detect_suite') && Plugins::LangID::API->available
			? 'Plugins::LangID::API'
			: undef;
	};

	return $suite_package;
}

# Prompt label for a target language.  'custom' returns the trimmed custom
# language name, unknown targets fall back to the requested identifier.
sub target_label {
	my ($target, $custom) = _strip_class(@_);

	my $canonical = _canonical_target($target);

	if ( $canonical eq 'custom' ) {
		my $label = defined $custom && !ref $custom ? $custom : '';
		$label =~ s/^\s+//;
		$label =~ s/\s+\z//;
		return $label;
	}

	return $TARGET_LABELS{$canonical} if defined $TARGET_LABELS{$canonical};

	return $canonical;
}

# Decide whether $text needs a translation into $target.
#
# Options:
#   threshold       number 0..1, default 0.5
#   mode            'auto' (default) | 'always' | 'llm'
#   suite_detect    coderef $suite->($text, $target, $cb) - injected detector
#   lingua_weight   weight of the lingua confidence, default 0.5
#   fastlang_weight weight of the fastlang confidence, default 0.5
#   llm_detect      coderef $llm->($text, $cb) with $cb->($confidence, $error)
#
# The callback is invoked exactly once with
#   { needs_translation => 0|1,
#     source            => 'suite'|'suite+llm'|'llm'|'forced',
#     language          => canonical target,
#     confidence        => number (LLM confidence, or the score),
#     score             => weighted suite score (when available),
#     lingua_confidence, fastlang_confidence,
#     lingua_language, fastlang_language }
sub detect_target {
	my ($text, $target, $opts, $cb) = _strip_class(@_);

	$opts = {} unless ref $opts eq 'HASH';
	$cb   = sub {} unless ref $cb eq 'CODE';
	$text = '' unless defined $text && !ref $text;

	my $threshold = _threshold($opts->{threshold});
	my $mode      = _mode($opts->{mode});
	my $canonical = _canonical_target($target);

	# make sure the caller is called back exactly once, even if a detector
	# answers twice or dies after answering
	my $settled = 0;
	my $reply = sub {
		my ($result) = @_;
		return if $settled++;

		$result ||= {};
		$result->{needs_translation} = $result->{needs_translation} ? 1 : 0;
		$result->{source}   = 'suite' unless defined $result->{source};
		$result->{language} = $canonical unless defined $result->{language};

		$cb->($result);

		return;
	};

	# forced translation: no detection at all
	if ( $mode eq 'always' ) {
		return $reply->({
			needs_translation => 1,
			source            => 'forced',
			language          => $canonical,
		});
	}

	# LLM only: skip the suite entirely
	if ( $mode eq 'llm' ) {
		return _llm_stage($text, $canonical, $threshold, $opts->{llm_detect}, $reply, undef, 'llm');
	}

	# auto: ask the suite first, the LLM decides ambiguous results
	my $suite = $opts->{suite_detect};
	$suite = suite_detector() unless ref $suite eq 'CODE';

	unless ($suite) {
		return _llm_stage($text, $canonical, $threshold, $opts->{llm_detect}, $reply, undef, 'llm');
	}

	_suite_stage($text, $canonical, $threshold, $suite, $opts, $reply);

	return;
}

sub _suite_stage {
	my ($text, $canonical, $threshold, $suite, $opts, $reply) = @_;

	my $settled = 0;
	my $once = sub {
		my ($result) = @_;
		return if $settled++;

		_suite_decision($text, $canonical, $threshold, $opts, $reply, $result);

		return;
	};

	my $result;
	my $ok = eval {
		$result = ref $suite eq 'CODE'
			? $suite->($text, $canonical, $once)
			: $suite->detect_suite($text, $canonical, $once);
		1;
	};

	return $once->({ error => $@ || 'suite detector failed' }) unless $ok;

	# a detector may answer synchronously by returning a result hash
	$once->($result) if ref $result eq 'HASH';

	return;
}

sub _suite_decision {
	my ($text, $canonical, $threshold, $opts, $reply, $result) = @_;

	my ($lingua, $fastlang);

	if ( ref $result eq 'HASH' && !$result->{error} ) {
		$lingua   = _suite_confidence($result->{lingua});
		$fastlang = _suite_confidence($result->{fastlang});
	}

	my %fields = (
		lingua_confidence   => $lingua,
		fastlang_confidence => $fastlang,
		lingua_language     => _suite_language($result->{lingua}),
		fastlang_language   => _suite_language($result->{fastlang}),
	);

	my $score = _blend_score($lingua, $fastlang, $opts);

	# the suite produced no usable confidence: let the model decide
	unless ( defined $score ) {
		return _llm_stage($text, $canonical, $threshold, $opts->{llm_detect}, $reply, \%fields, 'llm');
	}

	$fields{score} = $score;

	# clearly target or clearly not target: no need for the model
	if ( $score >= 0.9 ) {
		return $reply->({
			%fields,
			needs_translation => 0,
			source            => 'suite',
			confidence        => $score,
		});
	}

	if ( $score <= 0.1 ) {
		return $reply->({
			%fields,
			needs_translation => 1,
			source            => 'suite',
			confidence        => $score,
		});
	}

	# ambiguous band: the model decides, or the score is compared to the
	# threshold when no model is available
	return _llm_stage($text, $canonical, $threshold, $opts->{llm_detect}, $reply, \%fields, 'suite+llm');
}

# Final decision stage.  $fallback is 'suite+llm' (there is a suite score) or
# 'llm' (there is none).  Without a model, a suite score is compared to the
# threshold; with neither, the text is translated.
sub _llm_stage {
	my ($text, $canonical, $threshold, $llm_detect, $reply, $fields, $fallback) = @_;

	$fields ||= {};
	my $score  = $fields->{score};
	my $source = ( defined $fallback && $fallback eq 'llm' ) ? 'llm' : 'suite+llm';

	# no model: use the score if there is one, otherwise translate
	unless ( ref $llm_detect eq 'CODE' ) {
		if ( defined $score ) {
			return $reply->({
				%$fields,
				needs_translation => $score >= $threshold ? 0 : 1,
				source            => 'suite',
			});
		}

		return $reply->({
			%$fields,
			needs_translation => 1,
			source            => 'llm',
		});
	}

	my $settled = 0;
	my $on_llm = sub {
		my ($confidence, $error) = @_;
		return if $settled++;

		my $value = _clamped_number($confidence);

		if ( ( defined $error && $error ne '' ) || !defined $value ) {
			if ( defined $score ) {
				return $reply->({
					%$fields,
					needs_translation => $score >= $threshold ? 0 : 1,
					source            => 'suite',
				});
			}

			return $reply->({
				%$fields,
				needs_translation => 1,
				source            => 'llm',
			});
		}

		return $reply->({
			%$fields,
			needs_translation => $value >= $threshold ? 0 : 1,
			source            => $source,
			confidence        => $value,
		});
	};

	my $result;
	my $ok = eval { $result = $llm_detect->($text, $on_llm); 1 };

	return $on_llm->(undef, $@ || 'llm detect failed') unless $ok;

	# a detector may answer synchronously by returning a result hash
	$on_llm->($result->{confidence}, $result->{error}) if ref $result eq 'HASH';

	return;
}

# Weighted blend of the detector confidences: 0..1 or undef when the suite
# returned no usable confidence.
sub _blend_score {
	my ($lingua, $fastlang, $opts) = @_;

	my $linguaWeight   = _weight($opts->{lingua_weight});
	my $fastlangWeight = _weight($opts->{fastlang_weight});

	if ( defined $lingua && defined $fastlang ) {
		my $sum = $linguaWeight + $fastlangWeight;
		return undef if $sum <= 0;

		return _clamped_number(
			( $linguaWeight * $lingua + $fastlangWeight * $fastlang ) / $sum
		);
	}

	# A detector with weight 0 is ignored, even when it is the only one.
	return $lingua   if defined $lingua   && $linguaWeight   > 0;
	return $fastlang if defined $fastlang && $fastlangWeight > 0;

	return undef;
}

sub _suite_confidence {
	my ($detector) = @_;

	return undef unless ref $detector eq 'HASH';

	return _clamped_number($detector->{confidence});
}

sub _suite_language {
	my ($detector) = @_;

	return undef unless ref $detector eq 'HASH';

	foreach my $key (qw(language iso name)) {
		next unless defined $detector->{$key} && !ref $detector->{$key};

		my $value = $detector->{$key};
		$value =~ s/^\s+//;
		$value =~ s/\s+\z//;

		return $value if $value ne '';
	}

	return undef;
}

# Canonical target identifier: 'zh-Hans', 'zh-Hant', 'ja', 'ko', 'en' or
# 'custom'.  Common aliases (zh_CN, zh-TW, ja-JP, en-US, ...) are accepted.
sub _canonical_target {
	my ($target) = @_;

	my $value = defined $target && !ref $target ? $target : '';
	$value =~ s/^\s+//;
	$value =~ s/\s+\z//;
	$value = lc $value;
	$value =~ tr/_/-/;

	return 'custom' if $value eq '' || $value eq 'custom' || $value eq 'other';

	if ( $value =~ /^zh(?:-|\z)/ || $value eq 'chinese' || $value =~ /^cmn(?:-|\z)/ ) {
		return 'zh-Hant' if $value =~ /(?:^|-)(?:hant|tw|hk|mo)(?:-|\z)/;
		return 'zh-Hans';
	}

	return 'ja' if $value =~ /^ja(?:-|\z)/ || $value eq 'jp' || $value eq 'jpn' || $value eq 'japanese';
	return 'ko' if $value =~ /^ko(?:-|\z)/ || $value eq 'kr' || $value eq 'kor' || $value eq 'korean';
	return 'en' if $value =~ /^en(?:-|\z)/ || $value eq 'eng' || $value eq 'english';

	return $value;
}

sub _threshold {
	my ($value) = @_;

	my $threshold = _clamped_number($value);
	return defined $threshold ? $threshold : 0.5;
}

sub _weight {
	my ($value) = @_;

	my $weight = _clamped_number($value);
	return defined $weight ? $weight : 0.5;
}

sub _mode {
	my ($value) = @_;

	return 'auto' unless defined $value && !ref $value;

	my $mode = lc $value;
	$mode =~ s/^\s+//;
	$mode =~ s/\s+\z//;

	return $mode if $mode eq 'auto' || $mode eq 'always' || $mode eq 'llm';

	return 'auto';
}

# Clamp a numeric value to 0..1; anything non-numeric returns undef.
sub _clamped_number {
	my ($value) = @_;

	return undef unless defined $value && !ref $value;
	return undef unless $value =~ /^\s*[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\s*\z/;

	my $number = 0 + $value;

	return 0 if $number < 0;
	return 1 if $number > 1;

	return $number;
}

1;
