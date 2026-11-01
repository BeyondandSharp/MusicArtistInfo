package Plugins::MusicArtistInfo::Lyrics::Translate::Detect;

use strict;

# Language detection for the lyrics translation pipeline.  Detection has three
# levels, cheapest first:
#
#   1. an optional language identification plugin (Plugins::LangID::API); it is
#      only consulted for CJK targets and only if the plugin reports itself as
#      available
#   2. local script proportions (Han / Kana / Hangul), no dependencies
#   3. a caller supplied LLM detector (asynchronous, optional)
#
# The module itself has no LMS dependency: the optional plugin is required
# lazily and guarded by eval, so everything can be unit tested outside of LMS.
# CJK labels and language names are written as \x{...} escapes to keep this
# source file ASCII (plugin files are loaded as bytes by LMS).
#
# Public entry points accept both class method and plain function calls:
#
#   Plugins::MusicArtistInfo::Lyrics::Translate::Detect->detect_target(...)
#   Plugins::MusicArtistInfo::Lyrics::Translate::Detect::detect_target(...)

my $external_override;
my $external_checked = 0;
my $external_package;

my @SCRIPT_KEYS = qw(han kana hangul latin cyrillic greek arabic hebrew);

# Prompt labels for the languages the settings offer.
my %TARGET_LABELS = (
	'zh-Hans'  => "\x{7B80}\x{4F53}\x{4E2D}\x{6587}",   # Simplified Chinese
	'zh-Hant'  => "\x{7E41}\x{9AD4}\x{4E2D}\x{6587}",   # Traditional Chinese
	en         => 'English',
	ja         => "\x{65E5}\x{672C}\x{8A9E}",            # Japanese
	ko         => "\x{D55C}\x{AD6D}\x{C5B4}",            # Korean
);

# Language names and aliases a detector might return.
my %LANGUAGE_ALIASES = (
	chinese    => 'zh',
	mandarin   => 'zh',
	cmn        => 'zh',
	"\x{4E2D}\x{6587}" => 'zh',                          # Chinese
	"\x{6C49}\x{8BED}" => 'zh',                          # Chinese, simplified
	"\x{6F22}\x{8A9E}" => 'zh',                          # Chinese, traditional
	japanese   => 'ja',
	jpn        => 'ja',
	jp         => 'ja',
	"\x{65E5}\x{672C}\x{8A9E}" => 'ja',                  # Japanese
	korean     => 'ko',
	kor        => 'ko',
	kr         => 'ko',
	"\x{D55C}\x{AD6D}\x{C5B4}" => 'ko',                  # Korean
	english    => 'en',
	eng        => 'en',
);

# Accept both $class->method(...) and method(...) calls.  Only a first
# argument which looks like this class name is stripped, so plain function
# calls and the coderef arguments of set_external_detector() are unaffected.
sub _strip_class {
	my @args = @_;

	shift @args
		if @args
		&& defined $args[0]
		&& !ref $args[0]
		&& $args[0] =~ /^Plugins::MusicArtistInfo::Lyrics::Translate::Detect(?:::|\z)/;

	return @args;
}

# Inject a detector for tests (and for callers which provide their own).
# Accepts a coderef ($detector->($text, $cb)), a package name using the
# Plugins::LangID::API method layout ($package->detect($text, $cb)), an object
# with a detect() method, or undef to drop an injected detector again.
sub set_external_detector {
	my ($detector) = _strip_class(@_);

	if ( !defined $detector || ( !ref $detector && $detector eq '' ) ) {
		$external_override = undef;
	}
	else {
		$external_override = $detector;
	}

	return 1;
}

# Forget an injected detector and the memoized plugin availability.
sub reset {
	_strip_class(@_);

	$external_override = undef;
	$external_checked  = 0;
	$external_package  = undef;

	return 1;
}

# Returns the injected detector, or the optional Plugins::LangID::API package
# name if that plugin is installed and available, or undef.  The plugin lookup
# is memoized.
sub external_detector {
	_strip_class(@_);

	return $external_override if defined $external_override;
	return $external_package  if $external_checked;

	$external_checked = 1;
	$external_package = eval {
		require Plugins::LangID::API;
		Plugins::LangID::API->available ? 'Plugins::LangID::API' : undef;
	};

	return $external_package;
}

# Count letters per writing system.  Punctuation, digits, symbols and
# whitespace are ignored, and so are scripts we do not know about.  'total' is
# the sum of the eight named counters, i.e. the basis for all ratios.
sub script_counts {
	my ($text) = _strip_class(@_);

	my %counts = map { $_ => 0 } @SCRIPT_KEYS;

	if ( defined $text && !ref $text && length $text ) {
		$counts{han}      = () = $text =~ /(?=\p{L})\p{Han}/g;
		$counts{kana}     = () = $text =~ /(?=\p{L})[\p{Hiragana}\p{Katakana}]/g;
		$counts{hangul}   = () = $text =~ /(?=\p{L})\p{Hangul}/g;
		$counts{latin}    = () = $text =~ /(?=\p{L})\p{Latin}/g;
		$counts{cyrillic} = () = $text =~ /(?=\p{L})\p{Cyrillic}/g;
		$counts{greek}    = () = $text =~ /(?=\p{L})\p{Greek}/g;
		$counts{arabic}   = () = $text =~ /(?=\p{L})\p{Arabic}/g;
		$counts{hebrew}   = () = $text =~ /(?=\p{L})\p{Hebrew}/g;
	}

	$counts{total} = 0;
	$counts{total} += $counts{$_} for @SCRIPT_KEYS;

	return \%counts;
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
#   threshold  number 0..1, default 0.5 - minimum confidence for a decision
#   mode       'auto' (default) | 'always' | 'llm'
#   llm_detect coderef $llm_detect->($text, $cb) with $cb->($confidence, $error)
#
# The callback is invoked exactly once with
#   { needs_translation => 0|1, source => 'langid'|'rules'|'llm'|'forced',
#     language => ..., confidence => ... }
# 'language' is the detected language for source 'langid', the normalized
# target id otherwise.
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
		$result->{source} = 'rules' unless defined $result->{source};

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

	# LLM only: skip the plugin and the local rules.  The configured model
	# weight is not applied here: the caller explicitly asked the model.
	if ( $mode eq 'llm' ) {
		return _llm_stage($text, $canonical, $threshold, $opts->{llm_detect}, $reply, 'llm');
	}

	# auto: LangID for CJK targets first, then local rules, then the LLM.
	# no_external lets a caller ask for a synchronous local-rules-only answer
	# (the translator uses it for its fast enqueue-time check).
	my $detector = $opts->{no_external} ? undef : external_detector();

	if ( $detector && _is_cjk($canonical) ) {
		return _langid_stage($text, $canonical, $threshold, $detector, $opts, $reply);
	}

	my $decision = _rules_decision($text, $canonical, $threshold);
	return $reply->($decision) if $decision;

	# When the local rules cannot decide, blend their target-likelihood with
	# the model's confidence.  weight = 1 means "trust the model directly";
	# the default 0.2 mirrors the reference implementation's w_deepseek.
	my $local  = local_score($text, $canonical);
	my $weight = _clamped_number($opts->{model_weight});
	$weight = 0.2 unless defined $weight;

	return _llm_stage(
		$text, $canonical, $threshold, $opts->{llm_detect}, $reply, 'rules', $local, $weight,
	);
}

# Target-likelihood from script proportions, 0..1.  Used only to blend with
# the model's confidence when the hard rules above are inconclusive.  Latin
# script targets get a neutral 0.5 because script proportions cannot tell
# English from, say, French.
sub local_score {
	my ($text, $target) = _strip_class(@_);

	$text = '' unless defined $text && !ref $text;

	my $canonical = _canonical_target($target);
	my $counts    = script_counts($text);
	my $total     = $counts->{total} || 0;

	return undef unless $total > 0;

	my $han    = $counts->{han} / $total;
	my $kana   = $counts->{kana} / $total;
	my $hangul = $counts->{hangul} / $total;

	my $score;

	if ( $canonical eq 'zh-Hans' || $canonical eq 'zh-Hant' ) {
		my $penalty = ( $kana + $hangul ) * 10;
		$penalty = 1 if $penalty > 1;
		$score = $han * ( 1 - $penalty );
	}
	elsif ( $canonical eq 'ja' ) {
		$score = $kana * 8 + $han * 0.3;
	}
	elsif ( $canonical eq 'ko' ) {
		$score = $hangul * 8;
	}
	else {
		$score = 0.5;
	}

	return _clamped_number($score);
}

sub _langid_stage {
	my ($text, $canonical, $threshold, $detector, $opts, $reply) = @_;

	my $settled = 0;
	my $on_result = sub {
		my ($result) = @_;
		return if $settled++;

		my ($language, $confidence);

		if ( ref $result eq 'HASH' && !$result->{error} ) {
			$language   = _normalize_language($result);
			$confidence = _clamped_number($result->{confidence});
		}

		if ( !defined $language
			|| $language eq ''
			|| !defined $confidence
			|| $confidence < $threshold ) {
			my $decision = _rules_decision($text, $canonical, $threshold);
			return $reply->($decision) if $decision;

			return _llm_stage($text, $canonical, $threshold, $opts->{llm_detect}, $reply, 'rules');
		}

		return $reply->({
			needs_translation => _matches_target($canonical, $language) ? 0 : 1,
			source            => 'langid',
			language          => $language,
			confidence        => $confidence,
		});
	};

	_invoke_detector($detector, $text, $on_result);

	return;
}

# Last stage: ask the caller supplied LLM detector.  A missing detector means
# "translate": the local rules could not prove that the text is target
# language already.  When a local score and a model weight are supplied, the
# decision uses (1 - weight) * local + weight * model confidence.
sub _llm_stage {
	my ($text, $canonical, $threshold, $llm_detect, $reply, $fallback, $local, $weight) = @_;

	my $source = defined $fallback && $fallback eq 'llm' ? 'llm' : 'rules';

	unless ( ref $llm_detect eq 'CODE' ) {
		return $reply->({
			needs_translation => 1,
			source            => $source,
			language          => $canonical,
		});
	}

	my $blend = defined $local && defined $weight && $weight < 1 ? 1 : 0;

	my $settled = 0;
	my $on_result = sub {
		my ($confidence, $error) = @_;
		return if $settled++;

		my $value = _clamped_number($confidence);

		if ( ( defined $error && $error ne '' ) || !defined $value ) {
			return $reply->({
				needs_translation => 1,
				source            => 'llm',
				language          => $canonical,
			});
		}

		my $score = $value;
		if ($blend) {
			$score = ( 1 - $weight ) * $local + $weight * $value;
			$score = _clamped_number($score);
			$score = $value unless defined $score;
		}

		return $reply->({
			needs_translation => $score >= $threshold ? 0 : 1,
			source            => 'llm',
			language          => $canonical,
			confidence        => $value,
			score             => $score,
			( $blend ? ( local_score => $local, model_weight => $weight ) : () ),
		});
	};

	my $result;
	my $ok = eval { $result = $llm_detect->($text, $on_result); 1 };

	return $on_result->(undef, $@ || 'llm detect failed') unless $ok;

	# a detector may answer synchronously by returning a result hash instead
	# of calling the callback
	$on_result->($result->{confidence}, $result->{error}) if ref $result eq 'HASH';

	return;
}

# Call the detector.  Supported shapes: coderef, package name or object with a
# detect() method (Plugins::LangID::API layout).  Asynchronous detectors call
# $cb later; a detector returning a hash ref is treated as a synchronous
# answer.  Detectors dying or returning nothing are treated as "no answer" and
# trigger the rule based fallback.
sub _invoke_detector {
	my ($detector, $text, $cb) = @_;

	my $settled = 0;
	my $once = sub {
		return if $settled++;
		$cb->(@_);
		return;
	};

	my $result;
	my $ok = eval {
		if ( ref $detector eq 'CODE' ) {
			$result = $detector->($text, $once);
		}
		else {
			$result = $detector->detect($text, $once);
		}
		1;
	};

	return $once->({ error => $@ || 'detector failed' }) unless $ok;

	$once->($result) if ref $result eq 'HASH';

	return;
}

# Local rules.  Only a positive "already target language" answer is produced;
# undef means "not decided, ask the next level".
sub _rules_decision {
	my ($text, $canonical, $threshold) = @_;

	my $counts = script_counts($text);
	my $total  = $counts->{total} || 0;

	return undef unless $total > 0;

	my $han    = $counts->{han} / $total;
	my $kana   = $counts->{kana} / $total;
	my $hangul = $counts->{hangul} / $total;

	if ( $canonical eq 'zh-Hans' || $canonical eq 'zh-Hant' ) {
		return undef if $han < $threshold;
		return undef if ( $kana + $hangul ) >= 0.02;

		return {
			needs_translation => 0,
			source            => 'rules',
			language          => $canonical,
			confidence        => $han,
		};
	}

	if ( $canonical eq 'ja' ) {
		my $confidence;

		if ( $kana >= 0.02 ) {
			$confidence = $kana;
		}
		elsif ( $counts->{kana} > 0 && ( $kana + $han ) >= $threshold ) {
			$confidence = $kana + $han;
		}

		return undef unless defined $confidence;

		return {
			needs_translation => 0,
			source            => 'rules',
			language          => $canonical,
			confidence        => $confidence,
		};
	}

	if ( $canonical eq 'ko' ) {
		return undef if $hangul < $threshold;

		return {
			needs_translation => 0,
			source            => 'rules',
			language          => $canonical,
			confidence        => $hangul,
		};
	}

	# latin script and custom targets have no local rule
	return undef;
}

sub _is_cjk {
	my ($canonical) = @_;

	return 0 unless defined $canonical;
	return 1 if $canonical eq 'zh-Hans' || $canonical eq 'zh-Hant';
	return 1 if $canonical eq 'ja' || $canonical eq 'ko';

	return 0;
}

# Does a detected language match the target?  Both Chinese targets accept any
# Chinese variety; the other targets must match their language code.
sub _matches_target {
	my ($canonical, $language) = @_;

	return 0 unless defined $language && !ref $language && $language ne '';

	my $target = lc $canonical;
	my $lang   = lc $language;

	if ( $target eq 'zh-hans' || $target eq 'zh-hant' ) {
		return $lang =~ /^zh(?:-|\z)/ ? 1 : 0;
	}

	return $lang =~ /^\Q$target\E(?:-|\z)/ ? 1 : 0;
}

# Detector results may carry a language name and/or an ISO code.  Prefer an
# alias we know, then the primary language subtag, then whatever was given.
sub _normalize_language {
	my ($result) = @_;

	my @candidates;
	foreach my $key (qw(iso language)) {
		next unless defined $result->{$key} && !ref $result->{$key};

		my $value = $result->{$key};
		$value =~ s/^\s+//;
		$value =~ s/\s+\z//;
		push @candidates, $value if $value ne '';
	}

	my $fallback;
	foreach my $value (@candidates) {
		my $language = lc $value;
		$language =~ tr/_/-/;

		return $LANGUAGE_ALIASES{$language} if defined $LANGUAGE_ALIASES{$language};
		return $1 if $language =~ /^(zh|ja|ko|en)(?:-|\z)/;

		$fallback = $language unless defined $fallback;
	}

	return $fallback;
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
