package Plugins::MusicArtistInfo::Lyrics::Translate::LLM;

# OpenAI-compatible chat-completions client used by the lyrics translator.
#
# Everything which touches the network or the LMS cache is injectable so the
# module can be tested without LMS:
#
#   my $llm = Plugins::MusicArtistInfo::Lyrics::Translate::LLM->new(
#       config => \%config,
#       sender => sub { my ($request, $cb) = @_; ... },   # optional
#       cache  => $cache_object,                          # optional
#       logger => $logger_object,                         # optional
#   );
#
# sender contract:
#   $sender->({ url => ..., headers => {...}, body => $bytes, timeout => $sec }, $cb)
#   $cb->($parsed_json_hashref_or_undef, $http_status_or_undef, $error_or_undef)
#
# The default sender lazily requires Plugins::MusicArtistInfo::Common->post_json;
# the default cache is Slim::Utils::Cache.

use strict;

use Digest::MD5 qw(md5_hex);
use JSON::PP ();

use Plugins::MusicArtistInfo::Lyrics::Translate::LRC qw(clean_translation match_translations parse_llm_json);

# Allowed {{placeholder}} names per prompt stage.  Anything else is a config
# error (TranslateSettings validates and rewrites stored prompts).
my %PLACEHOLDERS = (
	batch  => [qw(target json source count path)],
	line   => [qw(target line source index total path)],
	detect => [qw(target text path lines)],
);

# Every error returned by this module is a plain string.  Callers (Translator)
# map these to status codes; failures never throw.

sub new {
	my ($class, %args) = @_;

	my $config = $args{config} || {};

	return bless {
		config   => { %$config },
		sender   => $args{sender},
		cache    => $args{cache},
		logger   => $args{logger},
		inflight => {},
	}, $class;
}

# Renders a prompt template.  Only placeholders from the stage allow-list are
# substituted; missing (but allowed) values stay as literal placeholders so a
# prompt can be rendered in more than one step (eg. {{target}} in config(),
# {{source}} per request).  Unknown placeholders are an error.
sub render {
	my ($class, $template, $values, $stage) = @_;

	$values ||= {};

	my $allowed = $PLACEHOLDERS{$stage};
	return (undef, 'invalid-stage') unless $allowed;

	my %allowed = map { $_ => 1 } @$allowed;
	my $text = defined $template ? $template : '';
	my $error;

	$text =~ s{
		\{\{(\w+)\}\}
	}{
		my $name = $1;
		if (!$allowed{$name}) {
			$error ||= "unknown-placeholder:$name";
			"{{$name}}";
		}
		elsif (exists $values->{$name} && defined $values->{$name} && !ref $values->{$name}) {
			$values->{$name};
		}
		else {
			"{{$name}}";
		}
	}gex;

	return ($text, $error);
}

sub cache_key {
	my ($self, $kind, $system, $user) = @_;

	my $config = $self->{config} || {};
	my $temperature;
	if ($kind eq 'batch') {
		$temperature = defined $config->{batch_temperature} ? $config->{batch_temperature} : 1.3;
	}
	elsif ($kind eq 'line') {
		$temperature = defined $config->{line_temperature} ? $config->{line_temperature} : 1.3;
	}
	else {
		$temperature = 0;
	}

	my $raw = join("\0",
		defined $kind ? $kind : '',
		defined $config->{model} ? $config->{model} : '',
		$temperature,
		$config->{thinking} ? 1 : 0,
		defined $config->{reasoning_effort} ? $config->{reasoning_effort} : '',
		defined $system ? $system : '',
		defined $user ? $user : '',
	);

	utf8::encode($raw);

	return md5_hex($raw);
}

# Translate a list of unique lines.  Callback: ($translations, \%stats, $error).
#   $translations : hashref line => translation (may be partial when $error)
#   $stats        : { llm_calls => N, cache_hits => N }
sub translate_lines {
	my ($self, $lines, $source, $cb) = @_;

	$cb ||= sub {};

	my $stats = { llm_calls => 0, cache_hits => 0 };

	return $cb->({}, $stats, 'invalid-lines') unless ref $lines eq 'ARRAY';

	# The line stage gets the whole lyrics as context ({{source}}).
	$source = $source->{text} if ref $source eq 'HASH';
	$source = '' unless defined $source;

	return $cb->({}, $stats, undef) unless scalar @$lines;

	my $mode = defined $self->{config}{mode} ? $self->{config}{mode} : 'batch';

	if ($mode eq 'line') {
		return $self->_translate_line_mode($lines, $source, $stats, $cb);
	}

	return $self->_translate_batch_mode($lines, $source, $stats, $cb);
}

# Ask the model whether $text already is in the target language.  Callback:
# ($confidence_0_to_1_or_undef, $error).  Detection results are not cached.
sub detect {
	my ($self, $text, $cb) = @_;

	$cb ||= sub {};

	$text = '' unless defined $text;

	my $values = {
		target => $self->_target_label,
		text   => $text,
		path   => $self->_config_path,
		lines  => 1,
	};

	my ($system, $serr) = $self->render($self->_system_prompt('detect'), $values, 'detect');
	my ($user,   $uerr) = $self->render('{{text}}', $values, 'detect');

	return $cb->(undef, $serr || $uerr) if $serr || $uerr;

	$self->_chat('detect', $system, $user, undef, sub {
		my ($content, $error) = @_;

		return $cb->(undef, $error) if defined $error;

		my $number;
		if (defined $content && $content =~ /(-?\d+(?:\.\d+)?)/) {
			$number = $1;
		}

		return $cb->(undef, 'no-confidence') unless defined $number;

		$number += 0;
		$number = 0 if $number < 0;
		$number = 1 if $number > 1;

		return $cb->($number, undef);
	});
}

# Low-level chat request.  Callback: ($content, $error).  Never dies.
sub chat {
	my ($self, $stage, $system, $user, $cb) = @_;

	$self->_chat($stage, $system, $user, undef, $cb);
}

sub _chat {
	my ($self, $stage, $system, $user, $stats, $cb) = @_;

	$cb ||= sub {};

	return $cb->(undef, 'invalid-stage') unless $PLACEHOLDERS{$stage};

	$system = '' unless defined $system;
	$user   = '' unless defined $user;

	my $key = $self->cache_key($stage, $system, $user);

	# Coalesce identical in-flight requests (same key): one HTTP call, all
	# waiting callbacks are served with the same result.
	if (my $waiting = $self->{inflight}{$key}) {
		push @$waiting, $cb;
		return;
	}

	$self->{inflight}{$key} = [ $cb ];

	my $finish = sub {
		my ($content, $error) = @_;

		my $waiting = delete $self->{inflight}{$key} || [];

		foreach my $waiter (@$waiting) {
			eval { $waiter->($content, $error) };
			$self->_log('warn', "callback failed: $@") if $@;
		}
	};

	my $ok = eval {
		$self->_send($stage, $system, $user, { stats => $stats, key => $key }, $finish, 1);
		1;
	};

	$finish->(undef, "internal-error: $@") unless $ok;
}

sub _send {
	my ($self, $stage, $system, $user, $context, $cb, $include_response_format) = @_;

	my $key = $self->_api_key;

	return $cb->(undef, 'missing-api-key') unless defined $key && $key ne '';

	my ($temperature, $timeout, $max_tokens) = $self->_stage_params($stage);

	my $body = $self->_request_body($stage, $system, $user, $include_response_format);
	my $url  = $self->_url;

	my $request = {
		url     => $url,
		headers => $self->_request_headers($key),
		body    => $body,
		timeout => $timeout,
		stage   => $stage,
	};

	$context->{stats}->{llm_calls}++ if $context->{stats};

	# never log the body or headers: they carry lyrics and credentials
	$self->_log('debug', sprintf('chat stage=%s url=%s bytes=%d', $stage, $url, length($body)));

	my $done = 0;

	my $handle = sub {
		my ($data, $status, $error) = @_;

		return if $done++;

		# Some OpenAI-compatible endpoints reject response_format with a 400.
		# Retry once without it before giving up.
		if ($include_response_format
			&& $self->{config}{response_format}
			&& _looks_like_400($status, $error, $data))
		{
			$self->_log('warn', 'retrying request without response_format after HTTP 400');
			return $self->_send($stage, $system, $user, $context, $cb, 0);
		}

		if (defined $error && $error ne '') {
			return $cb->(undef, _error_string($status, $error));
		}

		return $cb->(undef, _status_error($status, 'invalid-response'))
			unless ref $data eq 'HASH';

		if ($data->{error}) {
			return $cb->(undef, _status_error($status, _api_error_message($data)));
		}

		my $choice = ref $data->{choices} eq 'ARRAY' ? $data->{choices}->[0] : undef;
		my $content = ref $choice eq 'HASH' && ref $choice->{message} eq 'HASH'
			? $choice->{message}->{content}
			: undef;

		if (!defined $content || ref $content || $content !~ /\S/) {
			return $cb->(undef, _status_error($status, 'empty-response'));
		}

		return $cb->($content, undef);
	};

	my $ok = eval {
		$self->_sender->($request, $handle);
		1;
	};

	$handle->(undef, undef, "sender-error: $@") unless $ok;
}

sub _translate_batch_mode {
	my ($self, $lines, $source, $stats, $cb) = @_;

	my $size = defined $self->{config}{batch_size} ? $self->{config}{batch_size} : 0;

	my @chunks;
	if (!$size || $size >= scalar @$lines) {
		push @chunks, [ @$lines ];
	}
	else {
		for (my $i = 0; $i < scalar @$lines; $i += $size) {
			my $end = $i + $size - 1;
			$end = $#$lines if $end > $#$lines;
			push @chunks, [ @$lines[ $i .. $end ] ];
		}
	}

	my %translations;
	my ($error, $batch_failed, $probed, $finished);

	my $finish = sub {
		return if $finished++;

		if (defined $error && $error eq 'batch-failed') {
			# The probe line failed too: give up on all lines.
			return $cb->({}, $stats, $error);
		}

		my @missing = grep { !defined $translations{$_} || $translations{$_} eq '' } @$lines;
		$error = 'line-failed' if !defined $error && @missing;

		return $cb->(\%translations, $stats, $error);
	};

	my $fallback;
	my $next;

	$fallback = sub {
		my ($missing, $done) = @_;

		$self->_line_fallback($missing, $source, $stats, sub {
			my ($map, $fallback_error) = @_;

			foreach my $line (keys %$map) {
				$translations{$line} = $map->{$line}
					if defined $map->{$line} && $map->{$line} ne '';
			}

			$error ||= $fallback_error if defined $fallback_error;

			$done->();
		});
	};

	$next = sub {
		return $finish->() unless @chunks;

		my $chunk = shift @chunks;

		$self->_translate_chunk($chunk, $source, $stats, sub {
			my ($map, $chunk_error, $failed) = @_;

			foreach my $line (keys %$map) {
				$translations{$line} = $map->{$line}
					if defined $map->{$line} && $map->{$line} ne '';
			}

			my @missing = grep { !defined $translations{$_} || $translations{$_} eq '' } @$chunk;

			if (!$failed) {
				if (@missing) {
					$fallback->(\@missing, sub { $next->() });
					return;
				}
				return $next->();
			}

			# The batch call itself failed.  Probe a single line first: if the
			# endpoint cannot translate one line, do not burn more requests.
			if (!$batch_failed && !$probed) {
				$batch_failed = 1;
				$probed       = 1;

				my $probe = $chunk->[0];

				return $self->_translate_one($probe, $source, $stats, sub {
					my ($translation, $probe_error) = @_;

					if (!defined $translation || $translation eq '') {
						$error = $probe_error || 'batch-failed';
						return $finish->();
					}

					$translations{$probe} = $translation;

					my @rest = grep { $_ ne $probe } @$chunk;
					return $next->() unless @rest;

					$fallback->(\@rest, sub { $next->() });
				});
			}

			if (@missing) {
				$fallback->(\@missing, sub { $next->() });
				return;
			}

			$next->();
		});
	};

	$next->();
}

sub _translate_line_mode {
	my ($self, $lines, $source, $stats, $cb) = @_;

	$self->_line_fallback($lines, $source, $stats, sub {
		my ($translations, $error) = @_;
		$cb->($translations, $stats, $error);
	});
}

# Translate lines one by one with at most line_concurrency requests in flight.
sub _line_fallback {
	my ($self, $lines, $source, $stats, $cb) = @_;

	my $concurrency = defined $self->{config}{line_concurrency}
		? $self->{config}{line_concurrency}
		: 4;
	$concurrency = 1 if !$concurrency || $concurrency < 1;

	my @queue = @{ $lines || [] };
	my (%translations, $error, $active, $complete);

	my $start;
	$start = sub {
		return if $complete;

		while (!$error && $active < $concurrency && @queue) {
			my $line = shift @queue;
			$active++;

			$self->_translate_one($line, $source, $stats, sub {
				my ($translation, $line_error) = @_;

				$active--;

				if (!defined $translation || $translation eq '') {
					$error ||= $line_error || 'line-failed';
				}
				else {
					$translations{$line} = $translation;
				}

				if ($error && $active == 0) {
					$complete = 1;
					return $cb->(\%translations, $error);
				}

				$start->();
			});
		}

		if (!$error && !@queue && $active == 0 && !$complete) {
			$complete = 1;
			return $cb->(\%translations, undef);
		}
	};

	$start->();
}

sub _translate_chunk {
	my ($self, $chunk, $source, $stats, $cb) = @_;

	my $payload = _encode_json({ map { $_ => '' } @$chunk });

	my $values = {
		target => $self->_target_label,
		json   => $payload,
		source => defined $source ? $source : '',
		count  => scalar @$chunk,
		path   => $self->_config_path,
	};

	my ($system, $serr) = $self->render($self->_system_prompt('batch'), $values, 'batch');
	my ($user,   $uerr) = $self->render('{{json}}', $values, 'batch');

	return $cb->({}, $serr || $uerr, 1) if $serr || $uerr;

	my $key = $self->cache_key('batch', $system, $user);

	if (defined(my $cached = $self->_cache_get($key))) {
		my $cached_map = eval { _decode_json($cached) };
		if (ref $cached_map eq 'HASH') {
			my %map;
			foreach my $line (@$chunk) {
				my $value = $cached_map->{$line};
				next unless defined $value && !ref $value;
				$value = clean_translation($value);
				$map{$line} = $value if $value ne '';
			}

			if (scalar(keys %map) == scalar(@$chunk)) {
				$stats->{cache_hits}++;
				return $cb->(\%map, undef, 0);
			}
		}
	}

	$self->_chat('batch', $system, $user, $stats, sub {
		my ($content, $error) = @_;

		return $cb->({}, $error, 1) if defined $error;

		my $parsed = parse_llm_json($content);
		my $raw    = match_translations($chunk, $parsed);

		my %map;
		foreach my $line (@$chunk) {
			my $value = $raw->{$line};
			next unless defined $value && !ref $value;
			$value = clean_translation($value);
			$map{$line} = $value if $value ne '';
		}

		my $failed = (!defined $parsed || scalar(keys %map) == 0) ? 1 : 0;

		if (!$failed && scalar(keys %map) == scalar(@$chunk)) {
			$self->_cache_set($key, _encode_json(\%map));
		}

		$cb->(\%map, undef, $failed);
	});
}

sub _translate_one {
	my ($self, $line, $source, $stats, $cb) = @_;

	my $values = {
		target => $self->_target_label,
		line   => $line,
		source => defined $source ? $source : '',
		index  => 0,
		total  => 0,
		path   => $self->_config_path,
	};

	my ($system, $serr) = $self->render($self->_system_prompt('line'), $values, 'line');
	my ($user,   $uerr) = $self->render('{{line}}', $values, 'line');

	return $cb->(undef, $serr || $uerr) if $serr || $uerr;

	my $key = $self->cache_key('line', $system, $user);

	if (defined(my $cached = $self->_cache_get($key))) {
		my $translation = $cached;
		utf8::decode($translation) unless utf8::is_utf8($translation);
		if ($translation =~ /\S/) {
			$stats->{cache_hits}++;
			return $cb->($translation, undef);
		}
	}

	$self->_chat('line', $system, $user, $stats, sub {
		my ($content, $error) = @_;

		return $cb->(undef, $error) if defined $error;

		my $translation = clean_translation($content);
		return $cb->(undef, 'empty-translation') unless defined $translation && $translation ne '';

		my $bytes = $translation;
		utf8::encode($bytes);

		$self->_cache_set($key, $bytes);

		$cb->($translation, undef);
	});
}

sub _stage_params {
	my ($self, $stage) = @_;

	my $config = $self->{config} || {};

	if ($stage eq 'batch') {
		return (
			defined $config->{batch_temperature} ? $config->{batch_temperature} : 1.3,
			defined $config->{batch_timeout}     ? $config->{batch_timeout}     : 60,
			defined $config->{batch_max_tokens}  ? $config->{batch_max_tokens}  : 0,
		);
	}

	if ($stage eq 'line') {
		return (
			defined $config->{line_temperature} ? $config->{line_temperature} : 1.3,
			defined $config->{line_timeout}     ? $config->{line_timeout}     : 60,
			defined $config->{line_max_tokens}  ? $config->{line_max_tokens}  : 0,
		);
	}

	return (0, defined $config->{detect_timeout} ? $config->{detect_timeout} : 30, 0);
}

sub _request_body {
	my ($self, $stage, $system, $user, $include_response_format) = @_;

	my $config = $self->{config} || {};
	my ($temperature, $timeout, $max_tokens) = $self->_stage_params($stage);

	my %body = (
		model    => defined $config->{model} ? $config->{model} : 'deepseek-flash',
		messages => [
			{ role => 'system', content => $system },
			{ role => 'user',   content => $user },
		],
		temperature => 0 + $temperature,
	);

	$body{max_tokens} = 0 + $max_tokens if $max_tokens && $max_tokens > 0;

	if ($stage eq 'batch' && $include_response_format && $config->{response_format}) {
		$body{response_format} = { type => 'json_object' };
	}

	if ($config->{thinking}) {
		my %thinking = ( type => 'enabled' );
		if (defined $config->{reasoning_effort} && $config->{reasoning_effort} ne '') {
			$thinking{reasoning_effort} = $config->{reasoning_effort};
		}
		$body{thinking} = \%thinking;
	}

	return _encode_json(\%body);
}

sub _request_headers {
	my ($self, $key) = @_;

	my $config = $self->{config} || {};

	my %headers = ( 'Content-Type' => 'application/json' );

	my $auth_header = defined $config->{auth_header} ? $config->{auth_header} : 'Authorization';
	my $auth_prefix = defined $config->{auth_prefix} ? $config->{auth_prefix} : 'Bearer ';

	if ($auth_header ne '' && defined $key && $key ne '') {
		$headers{$auth_header} = $auth_prefix . $key;
	}

	my $extra = $config->{extra_headers};
	if (defined $extra && $extra ne '') {
		$extra = _parse_extra_headers($extra) unless ref $extra eq 'HASH';

		if (ref $extra eq 'HASH') {
			foreach my $name (keys %$extra) {
				next if lc($name) eq 'content-type';
				$headers{$name} = $extra->{$name};
			}
		}
	}

	return \%headers;
}

sub _url {
	my $self = shift;

	my $config = $self->{config} || {};

	my $base = defined $config->{api_base} && $config->{api_base} ne ''
		? $config->{api_base}
		: 'https://api.deepseek.com';
	$base =~ s{/+$}{};

	my $path = defined $config->{api_path} && $config->{api_path} ne ''
		? $config->{api_path}
		: '/chat/completions';
	$path = "/$path" unless $path =~ m{^/};

	return $base . $path;
}

sub _api_key {
	my $self = shift;

	my $config = $self->{config} || {};

	# An explicitly injected key (even undef/empty) wins, so tests can force
	# the "missing key" path without touching the real settings module.
	return $config->{api_key} if exists $config->{api_key};

	my $key = eval {
		require Plugins::MusicArtistInfo::Lyrics::TranslateSettings;
		Plugins::MusicArtistInfo::Lyrics::TranslateSettings->api_key;
	};

	return $key;
}

sub _system_prompt {
	my ($self, $stage) = @_;

	my $config = $self->{config} || {};

	my $prompt = $config->{ $stage . '_system' };
	$prompt = $config->{ $stage . 'System' } unless defined $prompt;

	unless (defined $prompt) {
		my $defaults = eval {
			require Plugins::MusicArtistInfo::Lyrics::TranslateSettings;
			Plugins::MusicArtistInfo::Lyrics::TranslateSettings->defaults;
		};

		if ($defaults) {
			$prompt = $defaults->{ 'lyricsTranslate' . ucfirst($stage) . 'System' };
		}
	}

	return defined $prompt ? $prompt : '';
}

sub _target_label {
	my $self = shift;

	my $config = $self->{config} || {};

	return defined $config->{target_label} ? $config->{target_label}
		: defined $config->{target} ? $config->{target}
		: '';
}

sub _config_path {
	my $self = shift;

	my $config = $self->{config} || {};

	return defined $config->{path} ? $config->{path} : '';
}

sub _sender {
	my $self = shift;

	return $self->{sender} if $self->{sender};

	return $self->{sender} = sub {
		my ($request, $cb) = @_;

		my $available = eval {
			require Plugins::MusicArtistInfo::Common;
			Plugins::MusicArtistInfo::Common->can('post_json');
		};

		return $cb->(undef, undef, 'sender-unavailable') unless $available;

		my $json = eval { JSON::PP->new->utf8->decode($request->{body}) };
		return $cb->(undef, undef, 'sender-error: invalid request body') unless $json;

		my $done = 0;

		Plugins::MusicArtistInfo::Common->post_json(
			$request->{url},
			{
				json    => $json,
				headers => $request->{headers},
				timeout => $request->{timeout},
			},
			sub {
				my ($data, $headers) = @_;

				return if $done++;

				if (ref $data eq 'HASH' && $data->{error} && !$data->{choices}) {
					return $cb->($data, undef, $data->{error});
				}

				return $cb->($data, undef, undef);
			},
		);
	};
}

sub _cache {
	my $self = shift;

	return $self->{cache} if $self->{cache};

	my $config = $self->{config} || {};
	return undef if exists $config->{cache} && !$config->{cache};

	$self->{cache} = eval {
		require Slim::Utils::Cache;
		Slim::Utils::Cache->new;
	};

	return $self->{cache};
}

sub _cache_get {
	my ($self, $key) = @_;

	my $cache = $self->_cache or return undef;

	my $value = eval { $cache->get($key) };

	return undef unless defined $value && !ref $value && $value ne '';

	return $value;
}

sub _cache_set {
	my ($self, $key, $value) = @_;

	my $cache = $self->_cache or return;

	my $config = $self->{config} || {};
	my $ttl = defined $config->{cache_ttl} ? $config->{cache_ttl} : '30d';

	eval { $cache->set($key, $value, $ttl) };

	return;
}

sub _log {
	my ($self, $level, $message) = @_;

	my $log = $self->{logger};
	return unless $log && $log->can($level);

	eval { $log->$level($message) };

	return;
}

sub _parse_extra_headers {
	my $raw = shift;

	my %headers;

	return \%headers unless defined $raw && !ref $raw;

	foreach my $line (split /\r?\n/, $raw) {
		next unless $line =~ /\S/;
		next unless $line =~ /^\s*([A-Za-z0-9-]+)\s*:\s*(.*?)\s*$/;
		$headers{$1} = $2;
	}

	return \%headers;
}

sub _encode_json {
	my $data = shift;
	return JSON::PP->new->utf8->canonical(1)->encode($data);
}

sub _decode_json {
	my $bytes = shift;
	return JSON::PP->new->utf8->decode($bytes);
}

sub _looks_like_400 {
	my ($status, $error, $data) = @_;

	return 1 if defined $status && $status == 400;

	if (defined $error) {
		return 1 if $error =~ /\b400\b/;
		return 1 if $error =~ /response_format|unsupported.*format/i;
	}

	return 0;
}

sub _error_string {
	my ($status, $error) = @_;

	return defined $status && $status >= 400 ? "http-$status" : $error;
}

sub _status_error {
	my ($status, $message) = @_;

	return "http-$status" if defined $status && $status >= 400;

	return $message;
}

sub _api_error_message {
	my $data = shift;

	my $error = $data->{error};

	if (ref $error eq 'HASH') {
		return $error->{message}
			|| $error->{type}
			|| $error->{code}
			|| 'api-error';
	}

	return $error if defined $error && !ref $error && $error ne '';

	return 'api-error';
}

1;
