package Plugins::MusicArtistInfo::Lyrics::TranslateSettings;

# Configuration and API-key handling for the LLM lyrics translation feature.
#
# The API key is deliberately not an LMS preference: it is stored in a
# separate file with mode 0600 (see key_file()), or taken from the
# DEEPSEEK_API_KEY environment variable.  No function returns the plain key
# except api_key(), which is only used to build the HTTP request.  key_status()
# and config() never expose it.

use strict;

use Digest::MD5 qw(md5_hex);
use Encode ();
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use File::Basename qw(dirname);
use File::Path ();
use File::Spec::Functions qw(catfile);

use Slim::Utils::Prefs;

my @TARGETS = qw(zh-Hans zh-Hant en ja ko custom);

my %PLACEHOLDERS = (
	batch  => [qw(target json source count path)],
	line   => [qw(target line source index total path)],
	detect => [qw(target text path lines)],
);

my %TARGET_LABELS = (
	'zh-Hans' => "\x{7b80}\x{4f53}\x{4e2d}\x{6587}",
	'zh-Hant' => "\x{7e41}\x{9ad4}\x{4e2d}\x{6587}",
	'en'      => 'English',
	'ja'      => "\x{65e5}\x{672c}\x{8a9e}",
	'ko'      => "\x{d55c}\x{ad6d}\x{c5b4}",
);

my $PROMPT_BATCH = q~You are a professional {{target}} native translator. Translate each source item accurately and fluently into {{target}}.

## Translation Requirements
- Treat each source item as a complete translation unit, including a single word, short phrase, heading, label, or site name. Do not ask for more context, a full article, or additional text.
- Return only the translated content for each item, following the required response format. Do not add explanations, apologies, greetings, or commentary. If an item should remain untranslated, return it unchanged.
- Preserve its meaning, tone, paragraph structure, and meaningful formatting.
- Keep code, placeholders, and content that must not be translated unchanged.
- Use supplied document context and terminology consistently.~;

my $PROMPT_LINE = $PROMPT_BATCH . "\n\nThe following is for context reference: {{source}}";

my $PROMPT_DETECT = q~You are a language detection expert. The user will send a segment of lyrics text. Determine whether that text is already in {{target}}, and reply with a confidence score between 0 and 1 (0 means definitely not, 1 means definitely yes). Reply with the number only.~;

my %DEFAULTS = (
	# master switch / target
	lyricsTranslate                   => 0,
	lyricsTranslateTarget             => 'zh-Hans',
	lyricsTranslateTargetCustom       => '',
	# service
	lyricsTranslateApiBase            => 'https://api.deepseek.com',
	lyricsTranslateApiPath            => '/chat/completions',
	lyricsTranslateModel              => 'deepseek-flash',
	lyricsTranslateAuthHeader         => 'Authorization',
	lyricsTranslateAuthPrefix         => 'Bearer ',
	lyricsTranslateExtraHeaders       => '',
	lyricsTranslateResponseFormat     => 1,
	# triggers
	lyricsTranslateOnFileLoad         => 1,
	lyricsTranslateOnSave             => 1,
	# mode
	lyricsTranslateMode               => 'batch',
	# batch stage
	lyricsTranslateBatchSize          => 0,
	lyricsTranslateBatchTemperature   => 1.3,
	lyricsTranslateBatchTimeout       => 60,
	lyricsTranslateBatchMaxTokens     => 0,
	# line stage
	lyricsTranslateLineConcurrency    => 4,
	lyricsTranslateLineTemperature    => 1.3,
	lyricsTranslateLineTimeout        => 60,
	lyricsTranslateLineMaxTokens      => 0,
	# reasoning
	lyricsTranslateThinking           => 0,
	lyricsTranslateReasoningEffort    => '',
	# language detection
	lyricsTranslateDetect             => 'auto',
	lyricsTranslateDetectThreshold    => 0.5,
	lyricsTranslateDetectModelWeight  => 0.2,
	lyricsTranslateDetectTimeout      => 30,
	# output
	lyricsTranslateMarker             => "[re:Deepseek\x{7ffb}\x{8bd1}]",
	lyricsTranslateMinTimestamps      => 3,
	lyricsTranslateMaxRepeatedTimestamps => 3,
	lyricsTranslateMultiline          => 'drop',
	lyricsTranslateFailedLine         => 'original',
	# cache
	lyricsTranslateCache              => 1,
	lyricsTranslateCacheTtl           => '30d',
	# backup
	lyricsTranslateBackup             => 'once',
	# queue
	lyricsTranslateQueueLimit         => 20,
	lyricsTranslateMaxAttempts        => 2,
	lyricsTranslateRetryDelay         => 60,
	lyricsTranslateFailCooldown       => 600,
	# prompts (system messages; user messages are {{json}} / {{line}} / {{text}})
	lyricsTranslateBatchSystem        => $PROMPT_BATCH,
	lyricsTranslateLineSystem         => $PROMPT_LINE,
	lyricsTranslateDetectSystem       => $PROMPT_DETECT,
);

sub defaults {
	return { %DEFAULTS };
}

sub targets {
	return wantarray ? @TARGETS : [@TARGETS];
}

sub placeholders {
	my ($class, $stage) = @_;

	my $placeholders = $PLACEHOLDERS{$stage} || [];

	return wantarray ? @$placeholders : [@$placeholders];
}

sub target_label {
	my ($class, $target, $custom) = @_;

	$target = '' unless defined $target;

	if ($target eq 'custom') {
		$custom = '' unless defined $custom;
		$custom =~ s/^\s+|\s+$//g;
		return $custom ne '' ? $custom : 'custom';
	}

	return $TARGET_LABELS{$target} if exists $TARGET_LABELS{$target};

	return $target ne '' ? $target : 'zh-Hans';
}

# Render a prompt template.  Unknown placeholders are reported as errors;
# allowed but missing values stay as literal placeholders so a prompt can be
# rendered in several steps.
sub render_template {
	my ($class, $template, $values, $stage) = @_;

	$values ||= {};

	my $allowed = $PLACEHOLDERS{$stage};
	return (undef, 'invalid-stage') unless $allowed;

	my %allowed = map { $_ => 1 } @$allowed;
	my $text = defined $template ? $template : '';
	my $error;

	$text =~ s/\{\{(\w+)\}\}/_render_placeholder(\%allowed, $values, \$error, $1)/gex;

	return ($text, $error);
}

sub _render_placeholder {
	my ($allowed, $values, $error_ref, $name) = @_;

	if (!$allowed->{$name}) {
		$$error_ref ||= "unknown-placeholder:$name";
		return "{{$name}}";
	}

	if (exists $values->{$name} && defined $values->{$name} && !ref $values->{$name}) {
		return $values->{$name};
	}

	return "{{$name}}";
}

sub config {
	my $class = shift;

	my $prefs = preferences('plugin.musicartistinfo');
	my $defaults = $class->defaults;

	my %values;
	foreach my $name (keys %$defaults) {
		my $value = $prefs->get($name);
		$values{$name} = defined $value ? $value : $defaults->{$name};
	}

	# Preferences are stored as byte strings by LMS.  Decode every text value
	# we send to the LLM or write into a lyrics file, otherwise non-ASCII
	# prompts, target names or markers would be double-encoded.
	foreach my $name (qw(
		lyricsTranslateTarget
		lyricsTranslateTargetCustom
		lyricsTranslateApiBase
		lyricsTranslateApiPath
		lyricsTranslateModel
		lyricsTranslateAuthHeader
		lyricsTranslateAuthPrefix
		lyricsTranslateExtraHeaders
		lyricsTranslateMode
		lyricsTranslateDetect
		lyricsTranslateMultiline
		lyricsTranslateFailedLine
		lyricsTranslateBackup
		lyricsTranslateCacheTtl
		lyricsTranslateReasoningEffort
		lyricsTranslateMarker
		lyricsTranslateBatchSystem
		lyricsTranslateLineSystem
		lyricsTranslateDetectSystem
	)) {
		$values{$name} = $class->_to_chars($values{$name}) if defined $values{$name};
	}

	my @errors;

	my $target = $values{lyricsTranslateTarget};
	$target = $defaults->{lyricsTranslateTarget} unless defined $target && $target ne '';

	my $custom = defined $values{lyricsTranslateTargetCustom} ? $values{lyricsTranslateTargetCustom} : '';
	my $label  = $class->target_label($target, $custom);

	my %rendered;
	foreach my $stage (qw(batch line detect)) {
		my $pref = 'lyricsTranslate' . ucfirst($stage) . 'System';
		my $template = defined $values{$pref} && $values{$pref} ne ''
			? $values{$pref}
			: $defaults->{$pref};

		my ($text, $error) = $class->render_template($template, { target => $label }, $stage);

		if ($error) {
			push @errors, "invalid-prompt-$stage: $error";
			($text) = $class->render_template($defaults->{$pref}, { target => $label }, $stage);
		}

		$rendered{$stage} = defined $text ? $text : '';
	}

	my $key_status = eval { $class->key_status } || {};

	my $marker = $values{lyricsTranslateMarker};
	$marker = $class->_to_chars($marker) if defined $marker;

	return {
		enabled     => $values{lyricsTranslate} ? 1 : 0,
		target      => $target,
		target_custom => $custom,
		target_label  => $label,

		api_base => $values{lyricsTranslateApiBase},
		api_path => $values{lyricsTranslateApiPath},
		model    => $values{lyricsTranslateModel},

		auth_header => $values{lyricsTranslateAuthHeader},
		auth_prefix => $values{lyricsTranslateAuthPrefix},

		extra_headers     => _parse_extra_headers($values{lyricsTranslateExtraHeaders}),
		extra_headers_raw => $values{lyricsTranslateExtraHeaders},

		response_format => $values{lyricsTranslateResponseFormat} ? 1 : 0,

		mode      => $values{lyricsTranslateMode},
		batch_size        => 0 + $values{lyricsTranslateBatchSize},
		batch_temperature => 0 + $values{lyricsTranslateBatchTemperature},
		batch_timeout     => 0 + $values{lyricsTranslateBatchTimeout},
		batch_max_tokens  => 0 + $values{lyricsTranslateBatchMaxTokens},

		line_concurrency => 0 + $values{lyricsTranslateLineConcurrency},
		line_temperature => 0 + $values{lyricsTranslateLineTemperature},
		line_timeout     => 0 + $values{lyricsTranslateLineTimeout},
		line_max_tokens  => 0 + $values{lyricsTranslateLineMaxTokens},

		thinking         => $values{lyricsTranslateThinking} ? 1 : 0,
		reasoning_effort => $values{lyricsTranslateReasoningEffort},

		detect             => $values{lyricsTranslateDetect},
		detect_threshold   => 0 + $values{lyricsTranslateDetectThreshold},
		detect_model_weight => 0 + $values{lyricsTranslateDetectModelWeight},
		detect_timeout     => 0 + $values{lyricsTranslateDetectTimeout},

		marker                  => $marker,
		min_timestamps          => 0 + $values{lyricsTranslateMinTimestamps},
		max_repeated_timestamps => 0 + $values{lyricsTranslateMaxRepeatedTimestamps},
		multiline               => $values{lyricsTranslateMultiline},
		failed_line             => $values{lyricsTranslateFailedLine},

		cache     => $values{lyricsTranslateCache} ? 1 : 0,
		cache_ttl => $values{lyricsTranslateCacheTtl},

		backup        => $values{lyricsTranslateBackup},
		queue_limit   => 0 + $values{lyricsTranslateQueueLimit},
		max_attempts  => 0 + $values{lyricsTranslateMaxAttempts},
		retry_delay   => 0 + $values{lyricsTranslateRetryDelay},
		fail_cooldown => 0 + $values{lyricsTranslateFailCooldown},

		batch_system  => $rendered{batch},
		line_system   => $rendered{line},
		detect_system => $rendered{detect},

		# only the status, never the key itself
		api_key_configured => $key_status->{configured} ? 1 : 0,
		api_key_source     => $key_status->{source} || 'none',

		prefs  => \%values,
		errors => \@errors,
	};
}

# A short fingerprint of the settings which influence the LLM request (used by
# Translator for status/debugging, never contains credentials).
sub cache_signature {
	my ($class, $config) = @_;

	$config ||= $class->config;

	my $raw = join("\0",
		defined $config->{model} ? $config->{model} : '',
		defined $config->{target_label} ? $config->{target_label}
			: defined $config->{target} ? $config->{target} : '',
		defined $config->{batch_temperature} ? $config->{batch_temperature} : '',
		defined $config->{line_temperature} ? $config->{line_temperature} : '',
		defined $config->{detect_model_weight} ? $config->{detect_model_weight} : '',
		$config->{thinking} ? 1 : 0,
		defined $config->{reasoning_effort} ? $config->{reasoning_effort} : '',
		$config->{response_format} ? 1 : 0,
		defined $config->{api_base} ? $config->{api_base} : '',
		defined $config->{api_path} ? $config->{api_path} : '',
		defined $config->{batch_system} ? $config->{batch_system} : '',
		defined $config->{line_system} ? $config->{line_system} : '',
		defined $config->{detect_system} ? $config->{detect_system} : '',
	);

	utf8::encode($raw);

	return md5_hex($raw);
}

# Validate settings submitted by the web UI.  Accepts either raw pref names
# ("lyricsTranslateMode") or form names ("pref_lyricsTranslateMode").
# Returns an arrayref of human readable errors.  The API key is never
# validated here and never appears in an error message.
sub validate {
	my ($class, $submitted) = @_;

	$submitted ||= {};

	my @errors;
	my %seen;

	my $value = sub {
		my $name = shift;
		return $submitted->{"pref_$name"} if exists $submitted->{"pref_$name"};
		return $submitted->{$name} if exists $submitted->{$name};
		return undef;
	};

	# target language
	my $target = $value->('lyricsTranslateTarget');
	if (defined $target && $target ne '') {
		my %targets = map { $_ => 1 } @TARGETS;
		if (!$targets{$target}) {
			push @errors, 'Invalid target language';
		}
		elsif ($target eq 'custom') {
			my $custom = $value->('lyricsTranslateTargetCustom');
			$custom = '' unless defined $custom;
			$custom =~ s/^\s+|\s+$//g;
			if ($custom eq '') {
				push @errors, 'Custom target language must not be empty';
			}
			elsif ($custom =~ /[\r\n]/ || length($custom) > 64) {
				push @errors, 'Custom target language is invalid or too long';
			}
		}
	}

	my %enums = (
		lyricsTranslateMode            => [qw(batch line)],
		lyricsTranslateDetect          => [qw(auto always llm)],
		lyricsTranslateMultiline       => [qw(drop space)],
		lyricsTranslateFailedLine      => [qw(original omit)],
		lyricsTranslateBackup          => [qw(none once timestamped)],
		lyricsTranslateReasoningEffort => [ '', qw(low high max) ],
	);

	foreach my $name (sort keys %enums) {
		my $submitted_value = $value->($name);
		next unless defined $submitted_value;
		my %allowed = map { $_ => 1 } @{ $enums{$name} };
		push @errors, "Invalid value for $name" unless $allowed{$submitted_value};
	}

	# API endpoint
	my $base = $value->('lyricsTranslateApiBase');
	if (defined $base) {
		push @errors, 'API base URL must start with http:// or https://'
			unless $base =~ m{^https?://\S+}i;
	}

	my $path = $value->('lyricsTranslateApiPath');
	if (defined $path) {
		push @errors, 'API path must start with /'
			unless $path =~ m{^/\S*};
	}

	my $auth_header = $value->('lyricsTranslateAuthHeader');
	if (defined $auth_header && $auth_header ne '') {
		push @errors, 'Invalid authentication header name'
			unless $auth_header =~ /^[A-Za-z0-9-]+$/;
	}

	my $auth_prefix = $value->('lyricsTranslateAuthPrefix');
	if (defined $auth_prefix) {
		push @errors, 'Invalid authentication prefix'
			if $auth_prefix =~ /[\r\n]/ || length($auth_prefix) > 64;
	}

	my $extra = $value->('lyricsTranslateExtraHeaders');
	if (defined $extra) {
		my @lines = split /\r?\n/, $extra;
		for (my $i = 0; $i < @lines; $i++) {
			my $line = $lines[$i];
			next unless $line =~ /\S/;
			unless ($line =~ /^\s*([A-Za-z0-9-]+)\s*:\s*(.*?)\s*$/) {
				push @errors, 'Invalid extra header on line ' . ($i + 1);
				next;
			}
			my ($name, $header_value) = ($1, $2);
			if (lc($name) eq 'content-type') {
				push @errors, 'Content-Type cannot be overridden by extra headers';
			}
			elsif ($header_value eq '') {
				push @errors, 'Empty value for extra header on line ' . ($i + 1);
			}
		}
	}

	# numeric settings: name => [min, max, integer]
	my %numbers = (
		lyricsTranslateBatchSize          => [ 0,   200,   1 ],
		lyricsTranslateBatchTemperature   => [ 0,   2,     0 ],
		lyricsTranslateBatchTimeout       => [ 1,   1800,  1 ],
		lyricsTranslateBatchMaxTokens     => [ 0,   32768, 1 ],
		lyricsTranslateLineConcurrency    => [ 1,   16,    1 ],
		lyricsTranslateLineTemperature    => [ 0,   2,     0 ],
		lyricsTranslateLineTimeout        => [ 1,   1800,  1 ],
		lyricsTranslateLineMaxTokens      => [ 0,   32768, 1 ],
		lyricsTranslateDetectThreshold    => [ 0,   1,     0 ],
		lyricsTranslateDetectModelWeight  => [ 0,   1,     0 ],
		lyricsTranslateDetectTimeout      => [ 1,   1800,  1 ],
		lyricsTranslateMinTimestamps      => [ 0,   100,   1 ],
		lyricsTranslateMaxRepeatedTimestamps => [ 1, 100,   1 ],
		lyricsTranslateQueueLimit         => [ 1,   1000,  1 ],
		lyricsTranslateMaxAttempts        => [ 1,   10,    1 ],
		lyricsTranslateRetryDelay         => [ 0,   86400, 1 ],
		lyricsTranslateFailCooldown       => [ 0,   86400, 1 ],
	);

	foreach my $name (sort keys %numbers) {
		my $submitted_value = $value->($name);
		next unless defined $submitted_value && $submitted_value ne '';
		my ($min, $max, $integer) = @{ $numbers{$name} };
		my $pattern = $integer ? qr/^\d+$/ : qr/^\d+(?:\.\d+)?$/;
		if ($submitted_value !~ $pattern) {
			push @errors, "Invalid number for $name";
			next;
		}
		my $number = 0 + $submitted_value;
		if ($number < $min || $number > $max) {
			push @errors, "$name must be between $min and $max";
		}
	}

	# cache TTL: seconds (max 30 days, matching Slim::Utils::Cache) or 30d style
	my $ttl = $value->('lyricsTranslateCacheTtl');
	if (defined $ttl) {
		my $ok = $ttl =~ /^\d+[smhdwMy]$/ ? 1 : 0;
		if (!$ok && $ttl =~ /^\d+$/) {
			$ok = $ttl <= 2592000 ? 1 : 0;
		}
		push @errors, 'Invalid cache TTL (use seconds up to 30 days or <n><s|m|h|d|w|M|y>)'
			unless $ok;
	}

	my $marker = $value->('lyricsTranslateMarker');
	if (defined $marker) {
		if ($marker eq '') {
			push @errors, 'Marker must not be empty';
		}
		elsif ($marker =~ /[\r\n]/ || length($marker) > 64) {
			push @errors, 'Marker is invalid or too long';
		}
	}

	foreach my $stage (qw(batch line detect)) {
		my $name = 'lyricsTranslate' . ucfirst($stage) . 'System';
		my $prompt = $value->($name);
		next unless defined $prompt;

		if ($prompt !~ /\S/) {
			push @errors, "Prompt for $stage must not be empty";
			next;
		}

		my (undef, $error) = $class->render_template($prompt, {}, $stage);
		push @errors, "Prompt for $stage has an unknown placeholder" if $error;
	}

	return \@errors;
}

# ---------------------------------------------------------------------------
# API key handling (file, mode 0600; never part of the prefs)
# ---------------------------------------------------------------------------

sub key_file {
	return catfile(Slim::Utils::Prefs::dir(), 'musicartistinfo', 'lyricsTranslate.key');
}

sub api_key {
	my $class = shift;

	my $key = $class->_read_key_file;
	return $key if defined $key && $key ne '';

	my $env = $ENV{DEEPSEEK_API_KEY};
	if (defined $env) {
		$env =~ s/^\s+|\s+$//g;
		return $env if $env ne '';
	}

	return undef;
}

sub key_status {
	my $class = shift;

	my $key = $class->_read_key_file;
	return { configured => 1, source => 'file' } if defined $key && $key ne '';

	my $env = $ENV{DEEPSEEK_API_KEY};
	if (defined $env) {
		$env =~ s/^\s+|\s+$//g;
		return { configured => 1, source => 'env' } if $env ne '';
	}

	return { configured => 0, source => 'none' };
}

sub store_key {
	my ($class, $key) = @_;

	return 0 unless defined $key && !ref $key;

	$key =~ s/^\s+|\s+$//g;

	return 0 if $key eq '' || length($key) > 512 || $key =~ /[\r\n]/;

	my $file = $class->key_file();
	my $dir  = dirname($file);

	return 0 unless -d $dir || eval { File::Path::mkpath($dir); 1 };
	return 0 unless -d $dir;

	my $bytes = Encode::encode('UTF-8', $key);

	my ($temp, $fh);

	for (my $try = 0; $try < 10; $try++) {
		$temp = $file . '.tmp.' . $$ . '.' . int(rand(1000000));

		if (sysopen($fh, $temp, O_WRONLY | O_CREAT | O_EXCL, 0600)) {
			last;
		}

		$temp = undef;
	}

	return 0 unless defined $temp;

	binmode($fh, ':raw');
	my $written = print {$fh} $bytes;

	unless (close($fh) && $written) {
		unlink $temp;
		return 0;
	}

	unless (chmod(0600, $temp)) {
		unlink $temp;
		return 0 unless $^O eq 'MSWin32';
	}

	unless (rename($temp, $file)) {
		# Windows cannot rename over an existing file
		unlink $file;
		unless (rename($temp, $file)) {
			unlink $temp;
			return 0;
		}
	}

	chmod(0600, $file);

	return 1;
}

sub clear_key {
	my $class = shift;

	my $file = $class->key_file();

	return 1 unless -e $file;

	return unlink($file) ? 1 : 0;
}

# Repair overly permissive permissions (called before reading the key).
sub key_permissions_ok {
	my $class = shift;

	my $file = $class->key_file();

	return 1 unless -e $file;

	my $mode = (stat($file))[2];
	return 1 unless defined $mode;

	$mode &= 0777;

	return 1 unless $mode & 077;

	return chmod(0600, $file) ? 1 : ($^O eq 'MSWin32' ? 1 : 0);
}

# ---------------------------------------------------------------------------

sub _read_key_file {
	my $class = shift;

	my $file = $class->key_file();

	return undef unless -f $file;

	$class->key_permissions_ok;

	my $fh;
	unless (open($fh, '<:raw', $file)) {
		return undef;
	}

	local $/;
	my $raw = <$fh>;
	close($fh);

	return undef unless defined $raw && $raw ne '';

	my $key = eval { Encode::decode('UTF-8', $raw, Encode::FB_CROAK) };
	if (!defined $key || $@) {
		$key = $raw;
	}

	$key =~ s/^\s+|\s+$//g;

	return $key ne '' ? $key : undef;
}

sub _to_chars {
	my ($class, $value) = @_;

	return $value unless defined $value && !ref $value;
	return $value if utf8::is_utf8($value);

	my $decoded = $value;
	utf8::decode($decoded);

	return utf8::is_utf8($decoded) ? $decoded : $value;
}

sub _parse_extra_headers {
	my $raw = shift;

	my %headers;

	return \%headers unless defined $raw && !ref $raw;

	foreach my $line (split /\r?\n/, $raw) {
		next unless $line =~ /\S/;
		next unless $line =~ /^\s*([A-Za-z0-9-]+)\s*:\s*(.*?)\s*$/;
		next if lc($1) eq 'content-type';
		$headers{$1} = $2;
	}

	return \%headers;
}

1;
