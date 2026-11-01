package Plugins::MusicArtistInfo::Lyrics::Translator;

# Queue for LLM based lyrics translation.  A job is a local .lrc file which is
# re-written as a bilingual file: a marker line, the verbatim original block
# and the translated block.
#
# Everything which talks to LMS or does I/O is either injectable or loaded
# lazily:
#
#   my $translator = Plugins::MusicArtistInfo::Lyrics::Translator->new(
#       config => \%config,     # TranslateSettings->config() structure
#       llm    => $llm_object,  # Translate::LLM compatible object
#       cache  => $cache_object,# Slim::Utils::Cache compatible object
#       logger => $log_object,  # optional
#   );
#
# The class level API (Translator->enqueue(...), ->status(...)) uses a lazily
# created singleton with the real defaults; tests use an instance.  Jobs are
# queued and processed one at a time; enqueue() itself never blocks.

use strict;

use Digest::MD5 qw(md5_hex);
use JSON::PP ();

use Plugins::MusicArtistInfo::Lyrics::Sidecar;
use Plugins::MusicArtistInfo::Lyrics::Translate::Detect;
use Plugins::MusicArtistInfo::Lyrics::Translate::LRC qw(
	build_detect_text
	count_timestamps
	first_nonempty_line
	parse_lrc
	rebuild_lrc
	unique_lines
);

my $STATUS_TTL    = 7 * 24 * 60 * 60;
my $STATUS_PREFIX = 'mai_lyrics_translate_status_';
my $COOLDOWN_PREFIX = 'mai_lyrics_translate_cooldown_';

my $singleton;

sub instance {
	my ($class) = @_;

	$singleton ||= $class->new;

	return $singleton;
}

sub new {
	my ($class, %opts) = @_;

	my $self = bless {
		queue        => [],
		inflight     => {},
		attempts     => {},
		status_keys  => [],
		timer_token  => {},
		pump_pending => 0,
		llm          => $opts{llm},
		cache        => $opts{cache},
		config       => $opts{config},
		logger       => $opts{logger},
	}, $class;

	if ( exists $opts{api_key} ) {
		$self->{api_key}          = $opts{api_key};
		$self->{api_key_injected} = 1;
	}

	return $self;
}

# Public methods accept both $class->method(...) and $instance->method(...).
sub _ctx {
	my ($invocant) = @_;

	return ref $invocant ? $invocant : $invocant->instance;
}

# ---------------------------------------------------------------------------
# public API
# ---------------------------------------------------------------------------

sub enabled {
	my ($invocant) = @_;

	my $self   = _ctx($invocant);
	my $config = $self->_config;

	return $config->{enabled} ? 1 : 0;
}

# Cheap, synchronous gates.  Returns { ok => 1, ... } with the parsed data or
# { skip => reason } where reason is one of the error codes used by enqueue().
sub check {
	my ($invocant, $lyrics, $path, $opts) = @_;

	my $self = _ctx($invocant);
	$opts ||= {};

	my $config = ref $opts->{config} eq 'HASH' ? $opts->{config} : $self->_config;

	return { skip => 'disabled' } unless $config->{enabled};

	$lyrics = '' unless defined $lyrics && !ref $lyrics;

	# an already translated file starts with the marker line
	my $marker = defined $config->{marker} && !ref $config->{marker} ? $config->{marker} : '';
	$marker =~ s/^\s+//;
	$marker =~ s/\s+$//;
	if ( $marker ne '' ) {
		my $first = first_nonempty_line($lyrics);
		return { skip => 'already-translated' } if $first eq $marker;
	}

	my ( $stamps, $repeated ) = count_timestamps($lyrics);
	my $minStamps = defined $config->{min_timestamps} ? $config->{min_timestamps} : 3;
	return { skip => 'no-timestamps' } if $stamps < $minStamps;

	my $maxRepeated = defined $config->{max_repeated_timestamps} ? $config->{max_repeated_timestamps} : 3;
	return { skip => 'already-bilingual' } if $repeated >= $maxRepeated;

	my $detectText = build_detect_text($lyrics);
	return { skip => 'no-translatable-text' } unless $detectText =~ /\S/;

	my $parsed = parse_lrc($lyrics);
	my $lines  = unique_lines($parsed->{texts});
	return { skip => 'no-lines' } unless @$lines;

	my $key = $self->_api_key($config);
	return { skip => 'missing-api-key' } unless defined $key && $key ne '';

	return {
		ok          => 1,
		config      => $config,
		detect_text => $detectText,
		parsed      => $parsed,
		lines       => $lines,
	};
}

# Queue a translation job.  Returns { queued => 1, key => $statusKey } or
# { error => $code }.  This is deliberately fast: only the synchronous checks
# (and a local rules based target check) run here.
sub enqueue {
	my ($invocant, $job) = @_;

	my $self = _ctx($invocant);

	return { error => 'invalid-job' } unless ref $job eq 'HASH';

	my $config = ref $job->{config} eq 'HASH' ? $job->{config} : $self->_config;

	my $path = defined $job->{path} && !ref $job->{path} ? $job->{path} : '';
	return { error => 'no-file' } if $path eq '';

	my $raw = _read_file_raw($path);
	return { error => 'no-file' } unless defined $raw;

	my $lyrics = defined $job->{lyrics} && !ref $job->{lyrics} ? $job->{lyrics} : '';
	if ( $lyrics !~ /\S/ ) {
		my $decoded = $raw;
		utf8::decode($decoded);
		$lyrics = $decoded;
	}

	my $check = $self->check($lyrics, $path, { config => $config });
	return { error => $check->{skip} } if $check->{skip};

	my $contentMd5 = md5_hex($raw);
	my $statusKey  = md5_hex($path);
	my $dedupeKey  = md5_hex($path . "\0" . $contentMd5);

	# the very same file content is already queued or being translated
	return { queued => 1, key => $statusKey, duplicate => 1 }
		if $self->{inflight}{$dedupeKey};

	my $cooldownKey = $COOLDOWN_PREFIX . md5_hex($path);
	if ( ( $config->{fail_cooldown} || 0 ) > 0 && $self->_cache->get($cooldownKey) ) {
		return { error => 'failed' };
	}

	my $limit = defined $config->{queue_limit} ? $config->{queue_limit} : 20;
	$limit = 1 if $limit < 1;
	return { error => 'queue-full' } if scalar @{ $self->{queue} } >= $limit;

	# A quick target check which may finish synchronously (local script rules)
	# lets the UI offer the "translate anyway" confirmation.  Anything which
	# needs the network is re-done by the queue.
	if ( !$job->{force} ) {
		my $mode = defined $config->{detect} ? $config->{detect} : 'auto';
		if ( $mode eq 'auto' ) {
			my $decision = $self->_sync_detect($check->{detect_text}, $config);
			if ( $decision && !$decision->{needs_translation} ) {
				return { error => 'already-target' };
			}
		}
	}

	my $fullJob = {
		path            => $path,
		lyrics          => $lyrics,
		args            => ref $job->{args} eq 'HASH' ? $job->{args} : {},
		source          => defined $job->{source} && !ref $job->{source} ? $job->{source} : 'manual',
		force           => $job->{force} ? 1 : 0,
		source_md5      => $contentMd5,
		source_encoding => _detect_encoding($raw),
		config          => $config,
		key             => $statusKey,
		dedupe_key      => $dedupeKey,
		detect_text     => $check->{detect_text},
		parsed          => $check->{parsed},
		lines           => $check->{lines},
	};

	# a newly accepted job always starts with a fresh attempt counter
	delete $self->{attempts}{$path};

	$self->{inflight}{$dedupeKey} = $fullJob;
	push @{ $self->{queue} }, $fullJob;

	$self->_set_status($statusKey, {
		state  => 'queued',
		target => $config->{target},
	});

	$self->_log('info', 'Queued lyrics translation for ' . $path . ' (' . $fullJob->{source} . ')');

	$self->_schedule_pump;

	return { queued => 1, key => $statusKey };
}

# Return the stored job status for a status key (md5 of the file path).
sub status {
	my ($invocant, $key) = @_;

	my $self = _ctx($invocant);

	return { state => 'unknown' } unless defined $key && !ref $key && $key ne '';

	my $raw = eval { $self->_cache->get($STATUS_PREFIX . $key) };
	return { state => 'unknown' } unless defined $raw && !ref $raw;

	my $status = eval { JSON::PP->new->utf8->decode($raw) };
	return { state => 'unknown' } unless ref $status eq 'HASH';

	return $status;
}

# Test helper: forget queued jobs, retry counters, in-flight marks and status.
sub clear_state {
	my ($invocant) = @_;

	my $self = _ctx($invocant);

	if ( eval { require Slim::Utils::Timers; 1 } ) {
		eval { Slim::Utils::Timers::killTimers($self->{timer_token}) };
	}

	$self->{queue}        = [];
	$self->{inflight}     = {};
	$self->{attempts}     = {};
	$self->{pump_pending} = 0;
	$self->{active}       = undef;

	my $cache = $self->_cache;
	foreach my $key ( @{ $self->{status_keys} || [] } ) {
		eval { $cache->remove($STATUS_PREFIX . $key) };
	}
	$self->{status_keys} = [];

	return 1;
}

# ---------------------------------------------------------------------------
# queue
# ---------------------------------------------------------------------------

sub _schedule_pump {
	my ($self) = @_;

	return if $self->{pump_pending};

	$self->{pump_pending} = 1;

	my $run = sub {
		$self->{pump_pending} = 0;
		$self->_pump;
		return;
	};

	if ( eval { require Slim::Utils::Timers; 1 } ) {
		Slim::Utils::Timers::setTimer($self->{timer_token}, time(), $run);
	}
	else {
		$run->();
	}

	return;
}

sub _pump {
	my ($self) = @_;

	return if $self->{active};
	return unless @{ $self->{queue} };

	my $job = shift @{ $self->{queue} };
	$self->{active} = $job;

	my $finished = 0;
	my $done = sub {
		return if $finished++;
		$self->{active} = undef;
		$self->_schedule_pump;
		return;
	};

	my $ok = eval { $self->_process($job, $done); 1 };

	unless ($ok) {
		$self->_fail($job, 'internal-error: ' . $self->_clean_error($@), $done);
	}

	return;
}

sub _schedule_retry {
	my ($self, $job, $delay) = @_;

	$delay = 0 unless defined $delay && $delay =~ /^\d+(?:\.\d+)?$/ && $delay > 0;

	if ( eval { require Slim::Utils::Timers; 1 } ) {
		Slim::Utils::Timers::setTimer($self->{timer_token}, time() + $delay, sub {
			push @{ $self->{queue} }, $job;
			$self->_schedule_pump;
			return;
		});
	}
	else {
		push @{ $self->{queue} }, $job;
		$self->_schedule_pump;
	}

	return;
}

# ---------------------------------------------------------------------------
# job processing
# ---------------------------------------------------------------------------

sub _process {
	my ($self, $job, $done) = @_;

	my $config = ref $job->{config} eq 'HASH' ? $job->{config} : $self->_config;

	# one LLM object for both the detection stage and the translation stage
	my $llm = $self->_llm($job);

	$self->_set_status($job->{key}, {
		state  => 'running',
		target => $config->{target},
	});

	my $translate = sub {
		my $parsed = $job->{parsed};
		my $lines  = $job->{lines};

		unless ( ref $lines eq 'ARRAY' && @$lines ) {
			return $self->_skip($job, 'no-lines', $done);
		}

		my $llmDone = 0;

		my $ok = eval {
			$llm->translate_lines($lines, $job->{detect_text}, sub {
				my ( $translations, $stats, $error ) = @_;
				return if $llmDone++;

				if ( defined $error && !ref $error && $error ne '' ) {
					return $self->_fail($job, $self->_clean_error($error), $done);
				}

				my %stats = %{ ref $stats eq 'HASH' ? $stats : {} };

				my ( $body, $rebuild ) = rebuild_lrc(
					$parsed,
					ref $translations eq 'HASH' ? $translations : {},
					# Bilingual files are written without a marker line.  The
					# configured marker is only used to recognise files
					# translated by older versions (see check()).
					marker      => '',
					multiline   => defined $config->{multiline} ? $config->{multiline} : 'drop',
					failed_line => defined $config->{failed_line} ? $config->{failed_line} : 'original',
				);

				unless ( ref $rebuild eq 'HASH' && $rebuild->{translated} ) {
					return $self->_skip($job, 'no-lines-translated', $done);
				}

				$stats{$_} = $rebuild->{$_} for keys %$rebuild;

				# never overwrite a file which changed while we were working
				my $current = _read_file_raw($job->{path});
				return $self->_fail($job, 'no-file', $done) unless defined $current;

				if ( md5_hex($current) ne $job->{source_md5} ) {
					return $self->_skip($job, 'stale', $done);
				}

				Plugins::MusicArtistInfo::Lyrics::Sidecar->backup(
					$job->{path},
					defined $config->{backup} ? $config->{backup} : 'none',
				);

				my $write = Plugins::MusicArtistInfo::Lyrics::Sidecar->save_path(
					$job->{path},
					$body,
					{
						overwrite => 1,
						normalize => 0,
						encoding  => $job->{source_encoding},
					},
				);

				if ( $write->{error} ) {
					return $self->_fail($job, $self->_clean_error($write->{error}), $done);
				}

				return $self->_succeed($job, \%stats, $done);
			});
			1;
		};

		unless ($ok) {
			return $self->_fail($job, 'internal-error: ' . $self->_clean_error($@), $done);
		}

		return;
	};

	# force bypasses target detection only
	return $translate->() if $job->{force};

	my $mode = defined $config->{detect} ? $config->{detect} : 'auto';

	# 'always' means: translate without asking about the target language
	return $translate->() if $mode eq 'always';

	my $detectSettled = 0;

	my $onDetect = sub {
		my ($result) = @_;
		return if $detectSettled++;

		my $needs = ref $result eq 'HASH' ? $result->{needs_translation} : 1;

		return $self->_skip($job, 'already-target', $done) unless $needs;

		return $translate->();
	};

	# A detector may fail to answer (broken plugin, hanging LLM request, ...).
	# A short watchdog makes sure the job cannot get stuck in this stage.
	my $timeout = defined $config->{detect_timeout} ? $config->{detect_timeout} : 30;
	$timeout = 30 if !$timeout || $timeout < 1;
	$timeout = 120 if $timeout > 120;

	my $watchdog = sub {
		return if $detectSettled++;

		$self->_log('warn', 'Lyrics language detection timed out for ' . $job->{path});

		return $translate->();
	};

	if ( eval { require Slim::Utils::Timers; 1 } ) {
		Slim::Utils::Timers::setTimer($self->{timer_token}, time() + $timeout, $watchdog);
	}

	my $ok = eval {
		Plugins::MusicArtistInfo::Lyrics::Translate::Detect->detect_target(
			$job->{detect_text},
			$config->{target},
			{
				mode         => $mode,
				threshold    => defined $config->{detect_threshold} ? $config->{detect_threshold} : 0.5,
				model_weight => defined $config->{detect_model_weight} ? $config->{detect_model_weight} : 0.2,
				llm_detect   => sub {
					my ( $text, $cb ) = @_;
					return $llm->detect($text, $cb);
				},
			},
			$onDetect,
		);
		1;
	};

	unless ($ok) {
		# a dying detector must not block the translation
		$self->_log('warn', 'Lyrics language detection failed for ' . $job->{path} . ': ' . $self->_clean_error($@));

		$onDetect->({ needs_translation => 1 });
	}

	return;
}

sub _skip {
	my ($self, $job, $reason, $done) = @_;

	$self->_set_status($job->{key}, {
		state  => 'skipped',
		reason => $reason,
		target => $job->{config}{target},
	});

	$self->_release($job);
	$done->() if $done;

	return;
}

sub _succeed {
	my ($self, $job, $stats, $done) = @_;

	delete $self->{attempts}{ $job->{path} };

	$self->_set_status($job->{key}, {
		state  => 'done',
		stats  => $stats,
		target => $job->{config}{target},
	});

	$self->_log('info', 'Translated lyrics for ' . $job->{path});

	$self->_release($job);
	$done->() if $done;

	return;
}

sub _fail {
	my ($self, $job, $error, $done) = @_;

	my $config = ref $job->{config} eq 'HASH' ? $job->{config} : {};
	my $path   = $job->{path};

	$error = $self->_clean_error($error);

	my $attempt = ( $self->{attempts}{$path} || 0 ) + 1;
	$self->{attempts}{$path} = $attempt;

	my $maxAttempts = defined $config->{max_attempts} ? $config->{max_attempts} : 1;
	my $retryDelay  = defined $config->{retry_delay} ? $config->{retry_delay} : 0;

	if ( $attempt < $maxAttempts ) {
		$self->_set_status($job->{key}, {
			state   => 'queued',
			reason  => 'retry',
			error   => $error,
			attempt => $attempt,
			target  => $config->{target},
		});

		$self->_schedule_retry($job, $retryDelay);
		$done->() if $done;

		return;
	}

	delete $self->{attempts}{$path};

	if ( ( $config->{fail_cooldown} || 0 ) > 0 ) {
		my $cooldownKey = $COOLDOWN_PREFIX . md5_hex($path);
		eval { $self->_cache->set($cooldownKey, 1, $config->{fail_cooldown}) };
	}

	$self->_set_status($job->{key}, {
		state  => 'failed',
		reason => 'failed',
		error  => $error,
		target => $config->{target},
	});

	$self->_log('warn', 'Lyrics translation failed for ' . $path . ': ' . $error);

	$self->_release($job);
	$done->() if $done;

	return;
}

sub _release {
	my ($self, $job) = @_;

	delete $self->{inflight}{ $job->{dedupe_key} } if $job->{dedupe_key};

	return;
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# Synchronous (local rules only) target check.  Returns the decision hash when
# Detect answered without waiting for the network, undef otherwise.
sub _sync_detect {
	my ($self, $text, $config) = @_;

	return undef unless defined $text && $text =~ /\S/;

	my $answered = 0;
	my $result;

	my $ok = eval {
		Plugins::MusicArtistInfo::Lyrics::Translate::Detect->detect_target(
			$text,
			$config->{target},
			{
				mode        => 'auto',
				threshold   => defined $config->{detect_threshold} ? $config->{detect_threshold} : 0.5,
				no_external => 1,
			},
			sub {
				$result   = shift;
				$answered = 1;
				return;
			},
		);
		1;
	};

	return undef unless $ok && $answered && ref $result eq 'HASH';

	return $result;
}

sub _set_status {
	my ($self, $key, $status) = @_;

	return unless defined $key && $key ne '';

	my %copy = %{ ref $status eq 'HASH' ? $status : {} };
	$copy{updated} = time() unless defined $copy{updated};

	my $json = eval { JSON::PP->new->utf8->canonical(1)->encode(\%copy) };
	return unless defined $json;

	eval { $self->_cache->set($STATUS_PREFIX . $key, $json, $STATUS_TTL) };

	my %seen = map { $_ => 1 } @{ $self->{status_keys} || [] };
	push @{ $self->{status_keys} }, $key unless $seen{$key};

	return;
}

sub _config {
	my ($self) = @_;

	return $self->{config} if ref $self->{config} eq 'HASH';

	my $config = eval {
		require Plugins::MusicArtistInfo::Lyrics::TranslateSettings;
		Plugins::MusicArtistInfo::Lyrics::TranslateSettings->config;
	};

	return ref $config eq 'HASH' ? $config : {};
}

sub _api_key {
	my ($self, $config) = @_;

	return $self->{api_key} if $self->{api_key_injected};

	$config ||= $self->_config;
	return $config->{api_key} if ref $config eq 'HASH' && exists $config->{api_key};

	my $key = eval {
		require Plugins::MusicArtistInfo::Lyrics::TranslateSettings;
		Plugins::MusicArtistInfo::Lyrics::TranslateSettings->api_key;
	};

	return $key;
}

sub _llm {
	my ($self, $job) = @_;

	return $self->{llm} if $self->{llm};

	my $config = ref $job->{config} eq 'HASH' ? $job->{config} : $self->_config;

	my %llmConfig = %$config;
	if ( defined $job->{path} && $job->{path} ne '' ) {
		$llmConfig{path} = $job->{path};
	}
	$llmConfig{api_key} = $self->_api_key($config);

	require Plugins::MusicArtistInfo::Lyrics::Translate::LLM;

	return Plugins::MusicArtistInfo::Lyrics::Translate::LLM->new(
		config => \%llmConfig,
		cache  => $self->_cache,
		logger => $self->_logger,
	);
}

sub _cache {
	my ($self) = @_;

	return $self->{cache} if $self->{cache};

	$self->{cache} = eval {
		require Slim::Utils::Cache;
		Slim::Utils::Cache->new;
	};

	return $self->{cache} ||= Plugins::MusicArtistInfo::Lyrics::Translator::MemoryCache->new;
}

sub _logger {
	my ($self) = @_;

	return $self->{logger} if $self->{logger};

	$self->{logger} = eval {
		require Slim::Utils::Log;
		Slim::Utils::Log::logger('plugin.musicartistinfo');
	};

	return $self->{logger};
}

sub _log {
	my ($self, $level, $message) = @_;

	my $logger = $self->_logger;
	return unless $logger && $logger->can($level);

	eval { $logger->$level($message) };

	return;
}

sub _clean_error {
	my ($self, $error) = @_;

	return 'failed' unless defined $error && !ref $error && $error ne '';

	$error =~ s/[\r\n\t]+/ /g;
	$error =~ s/\s+/ /g;
	$error =~ s/^\s+//;
	$error =~ s/\s+$//;

	if ( length($error) > 200 ) {
		$error = substr($error, 0, 200) . '...';
	}

	return $error;
}

sub _read_file_raw {
	my $path = shift;

	return undef unless defined $path && !ref $path && $path ne '' && -f $path;

	open(my $fh, '<:raw', $path) or return undef;

	local $/;
	my $raw = <$fh>;
	close $fh;

	return defined $raw ? $raw : '';
}

# Keep the encoding of the file we are about to rewrite: BOM, then UTF-8, then
# the configured save encoding.
sub _detect_encoding {
	my ($raw) = @_;

	$raw = '' unless defined $raw;

	return 'utf16le' if length($raw) >= 2 && substr($raw, 0, 2) eq "\xFF\xFE";
	return 'utf16be' if length($raw) >= 2 && substr($raw, 0, 2) eq "\xFE\xFF";
	return 'utf8bom' if length($raw) >= 3 && substr($raw, 0, 3) eq "\xEF\xBB\xBF";

	my $copy  = $raw;
	my $valid = eval { utf8::decode($copy) ? 1 : 0 };
	return 'utf8' if $valid;

	my $fallback = eval {
		require Slim::Utils::Prefs;
		Slim::Utils::Prefs::preferences('plugin.musicartistinfo')->get('lyricsSaveEncoding');
	};

	return defined $fallback && !ref $fallback && $fallback ne '' ? $fallback : 'utf8';
}

1;

# In-memory cache used when neither an injected cache nor Slim::Utils::Cache is
# available (mostly unit tests running outside of LMS).
package Plugins::MusicArtistInfo::Lyrics::Translator::MemoryCache;

sub new {
	my ($class) = @_;

	return bless { values => {} }, $class;
}

sub get {
	my ( $self, $key ) = @_;

	return $self->{values}{$key};
}

sub set {
	my ( $self, $key, $value, $ttl ) = @_;

	$self->{values}{$key} = $value;

	return 1;
}

sub remove {
	my ( $self, $key ) = @_;

	delete $self->{values}{$key};

	return 1;
}

1;
