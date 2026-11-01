#!/usr/bin/perl

use strict;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/lib";

use Digest::MD5 qw(md5_hex);
use Encode ();
use File::Spec::Functions qw(catfile);
use File::Temp qw(tempdir);
use Test::More;

use Slim::Utils::Prefs;
use Slim::Utils::Timers;

require Plugins::MusicArtistInfo::Lyrics::Translator;

my $Translator = 'Plugins::MusicArtistInfo::Lyrics::Translator';

my $dir = tempdir(CLEANUP => 1);

# ---------------------------------------------------------------------------
# fakes
# ---------------------------------------------------------------------------

package FakeCache;

sub new {
	my ($class) = @_;
	return bless { values => {}, ttl => {} }, $class;
}

sub get {
	my ($self, $key) = @_;
	return $self->{values}{$key};
}

sub set {
	my ($self, $key, $value, $ttl) = @_;
	$self->{values}{$key} = $value;
	$self->{ttl}{$key}    = $ttl;
	return 1;
}

sub remove {
	my ($self, $key) = @_;
	delete $self->{values}{$key};
	return 1;
}

package FakeLLM;

sub new {
	my ($class, %opts) = @_;
	return bless {
		script        => $opts{script} || [],
		translations  => $opts{translations} || {},
		detect        => defined $opts{detect} ? $opts{detect} : 0,
		detect_silent => $opts{detect_silent} ? 1 : 0,
		calls         => [],
		detect_calls  => [],
	}, $class;
}

sub translate_lines {
	my ($self, $lines, $source, $cb) = @_;

	push @{ $self->{calls} }, { lines => [@$lines], source => $source };

	my $next = @{ $self->{script} } ? shift @{ $self->{script} } : undef;

	if (ref $next eq 'CODE') {
		return $next->($self, $lines, $cb);
	}

	if (ref $next eq 'HASH') {
		return $cb->(
			$next->{translations} || {},
			$next->{stats} || { llm_calls => 1, cache_hits => 0 },
			$next->{error},
		);
	}

	my %map;
	foreach my $line (@$lines) {
		$map{$line} = exists $self->{translations}{$line} ? $self->{translations}{$line} : "T:$line";
	}

	return $cb->(\%map, { llm_calls => 1, cache_hits => 0 }, undef);
}

sub detect {
	my ($self, $text, $cb) = @_;

	push @{ $self->{detect_calls} }, $text;

	# a detector which never answers (to exercise the watchdog fallback)
	return if $self->{detect_silent};

	return $cb->($self->{detect}, undef);
}

package main;

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

my $counter = 0;

sub temp_path {
	my ($name) = @_;

	$counter++;

	return catfile($dir, ( $name || 'song' ) . "-$counter.lrc");
}

sub write_bytes {
	my ($path, $bytes) = @_;

	open(my $fh, '>:raw', $path) or die "write $path: $!";
	print {$fh} $bytes;
	close $fh or die "close $path: $!";

	return $path;
}

sub write_text {
	my ($path, $text) = @_;

	return write_bytes($path, Encode::encode('UTF-8', $text));
}

sub read_bytes {
	my ($path) = @_;

	open(my $fh, '<:raw', $path) or die "read $path: $!";
	local $/;
	my $bytes = <$fh>;
	close $fh;

	return defined $bytes ? $bytes : '';
}

sub read_text {
	my ($path) = @_;

	my $copy = read_bytes($path);
	utf8::decode($copy);

	return $copy;
}

sub test_config {
	my ($over) = @_;

	my %config = (
		enabled                 => 1,
		target                  => 'zh-Hans',
		target_label            => "\x{7b80}\x{4f53}\x{4e2d}\x{6587}",
		target_custom           => '',
		marker                  => '[re:test]',
		min_timestamps          => 3,
		max_repeated_timestamps => 3,
		multiline               => 'drop',
		failed_line             => 'original',
		detect                  => 'always',
		detect_threshold        => 0.5,
		lingua_weight           => 0.5,
		fastlang_weight         => 0.5,
		detect_timeout          => 30,
		backup                  => 'none',
		queue_limit             => 20,
		max_attempts            => 1,
		retry_delay             => 0,
		fail_cooldown           => 0,
		api_key                 => 'test-key',
		mode                    => 'batch',
		batch_size              => 0,
		cache                   => 1,
		cache_ttl               => '30d',
	);

	%config = ( %config, %$over ) if ref $over eq 'HASH';

	return \%config;
}

sub new_translator {
	my ($over) = @_;

	return $Translator->new(
		config => test_config($over),
		cache  => FakeCache->new,
	);
}

sub reset_timers {
	Slim::Utils::Timers::clear();
	return;
}

sub run_jobs {
	Slim::Utils::Timers::run_pending();
	return;
}

my $SAMPLE = "[00:01.00]Hello\n[00:02.00]World\n[00:03.00]Again\n[00:04.00]Last line\n";

my $CHINESE = "[00:01.00]你好世界\n[00:02.00]第二行\n[00:03.00]第三行\n[00:04.00]最后一行\n";

# ---------------------------------------------------------------------------
# enabled()
# ---------------------------------------------------------------------------
{
	my $tr = new_translator();
	is($tr->enabled, 1, 'enabled() with enabled config');

	$tr = new_translator({ enabled => 0 });
	is($tr->enabled, 0, 'enabled() with disabled config');
}

# ---------------------------------------------------------------------------
# check(): synchronous gates
# ---------------------------------------------------------------------------
{
	reset_timers();

	my $tr   = new_translator();
	my $path = write_text(temp_path('check'), $SAMPLE);

	my $result = $tr->check($SAMPLE, $path, {});
	ok($result->{ok}, 'check: plain LRC passes');
	is($result->{skip}, undef, 'check: no skip reason');
	is_deeply($result->{lines}, ['Hello', 'World', 'Again', 'Last line'], 'check: unique lines');
	like($result->{detect_text}, qr/Hello/, 'check: detect text');

	my $translated = "[re:test]\n" . $SAMPLE . "[00:01.00]T:Hello\n";
	is($tr->check($translated, $path, {})->{skip}, 'already-translated', 'check: marker detected');

	my $leading = "\n\n  [re:test]  \n" . $SAMPLE;
	is($tr->check($leading, $path, {})->{skip}, 'already-translated', 'check: marker after blank lines');

	is($tr->check("Hello\nWorld\n", $path, {})->{skip}, 'no-timestamps', 'check: too few timestamps');

	my $bilingual = "[00:01.00]one\n[00:01.00]one\n[00:01.00]one\n[00:01.00]one\n";
	is($tr->check($bilingual, $path, {})->{skip}, 'already-bilingual', 'check: repeated timestamps (>= limit)');

	my $empty = "[00:01.00]\n[00:02.00]\n[00:03.00]\n";
	is($tr->check($empty, $path, {})->{skip}, 'no-translatable-text', 'check: no text');

	my $punctuation = "[00:01.00]!!!\n[00:02.00]???\n[00:03.00]...\n";
	is($tr->check($punctuation, $path, {})->{skip}, 'no-lines', 'check: only punctuation');

	$tr = new_translator({ api_key => undef });
	is($tr->check($SAMPLE, $path, {})->{skip}, 'missing-api-key', 'check: no API key');

	$tr = new_translator({ enabled => 0 });
	is($tr->check($SAMPLE, $path, {})->{skip}, 'disabled', 'check: disabled');

	reset_timers();
}

# ---------------------------------------------------------------------------
# enqueue(): error codes and dedupe
# ---------------------------------------------------------------------------
{
	reset_timers();

	my $tr = new_translator({ enabled => 0 });
	my $path = write_text(temp_path('disabled'), $SAMPLE);
	is($tr->enqueue({ path => $path, lyrics => $SAMPLE })->{error}, 'disabled', 'enqueue: disabled');

	$tr = new_translator();
	is($tr->enqueue({ path => catfile($dir, 'missing.lrc'), lyrics => $SAMPLE })->{error},
		'no-file', 'enqueue: missing file');
	is($tr->enqueue({ path => '', lyrics => $SAMPLE })->{error}, 'no-file', 'enqueue: empty path');

	my $translated = "[re:test]\n" . $SAMPLE;
	$path = write_text(temp_path('translated'), $translated);
	is($tr->enqueue({ path => $path, lyrics => $translated })->{error},
		'already-translated', 'enqueue: already translated');

	$path = write_text(temp_path('short'), "[00:01.00]Hello\n[00:02.00]World\n");
	is($tr->enqueue({ path => $path, lyrics => "[00:01.00]Hello\n[00:02.00]World\n" })->{error},
		'no-timestamps', 'enqueue: no timestamps');

	$tr = new_translator({ api_key => undef });
	$path = write_text(temp_path('nokey'), $SAMPLE);
	is($tr->enqueue({ path => $path, lyrics => $SAMPLE })->{error},
		'missing-api-key', 'enqueue: missing API key');

	# enqueue never decides about the target language itself: the worker does
	my $targetLlm = FakeLLM->new(detect => 0.95);
	$tr = $Translator->new(
		config => test_config({ detect => 'auto' }),
		llm    => $targetLlm,
		cache  => FakeCache->new,
	);
	$path = write_text(temp_path('target'), $CHINESE);
	my $targetResult = $tr->enqueue({ path => $path, lyrics => $CHINESE });
	ok($targetResult->{queued}, 'enqueue: target check deferred to the worker');
	is($targetResult->{error}, undef, 'enqueue: no immediate already-target error');
	run_jobs();
	my $targetStatus = $tr->status($targetResult->{key});
	is($targetStatus->{state}, 'skipped', 'enqueue: worker skipped already-target lyrics');
	is($targetStatus->{reason}, 'already-target', 'enqueue: worker skip reason');
	is(scalar @{ $targetLlm->{calls} }, 0, 'enqueue: already-target lyrics not translated');
	is(read_text($path), $CHINESE, 'enqueue: already-target file untouched');

	# force bypasses the worker target detection
	my $llm = FakeLLM->new(detect => 0.95);
	$tr = $Translator->new(
		config => test_config({ detect => 'auto', backup => 'none' }),
		llm    => $llm,
		cache  => FakeCache->new,
	);
	my $forced = $tr->enqueue({ path => $path, lyrics => $CHINESE, force => 1 });
	ok($forced->{queued}, 'enqueue: force queues already-target content');
	run_jobs();
	is($tr->status($forced->{key})->{state}, 'done', 'enqueue: forced job translated');
	is(scalar @{ $llm->{calls} }, 1, 'enqueue: forced job used the LLM');
	is(scalar @{ $llm->{detect_calls} }, 0, 'enqueue: forced job skipped detection');

	# queue limit (nothing is pumped between the two calls)
	$tr = new_translator({ queue_limit => 1 });
	my $limitA = write_text(temp_path('limit-a'), $SAMPLE);
	my $limitB = write_text(temp_path('limit-b'), $SAMPLE);
	ok($tr->enqueue({ path => $limitA, lyrics => $SAMPLE })->{queued}, 'enqueue: first job queued');
	is($tr->enqueue({ path => $limitB, lyrics => $SAMPLE })->{error}, 'queue-full', 'enqueue: queue limit');
	$tr->clear_state;

	# dedupe by path + content
	$llm = FakeLLM->new;
	$tr = $Translator->new(
		config => test_config({ backup => 'none' }),
		llm    => $llm,
		cache  => FakeCache->new,
	);
	$path = write_text(temp_path('dedupe'), $SAMPLE);
	my $first  = $tr->enqueue({ path => $path, lyrics => $SAMPLE });
	my $second = $tr->enqueue({ path => $path, lyrics => $SAMPLE });
	ok($first->{queued}, 'enqueue: first job queued');
	ok($second->{queued}, 'enqueue: duplicate acknowledged');
	ok($second->{duplicate}, 'enqueue: duplicate flagged');
	is($second->{key}, $first->{key}, 'enqueue: duplicate shares the status key');
	run_jobs();
	is(scalar @{ $llm->{calls} }, 1, 'enqueue: duplicate translated once');
	is($tr->status($first->{key})->{state}, 'done', 'enqueue: duplicate job done');

	reset_timers();
}

# ---------------------------------------------------------------------------
# happy path: write-back, marker, backup, status
# ---------------------------------------------------------------------------
{
	reset_timers();

	my $path  = write_text(temp_path('happy'), $SAMPLE);
	my $llm   = FakeLLM->new;
	my $cache = FakeCache->new;
	my $tr    = $Translator->new(
		config => test_config({ backup => 'once' }),
		llm    => $llm,
		cache  => $cache,
	);

	my $result = $tr->enqueue({ path => $path, lyrics => $SAMPLE, source => 'manual' });
	ok($result->{queued}, 'happy: job queued');
	is($result->{key}, md5_hex($path), 'happy: status key is md5 of the path');
	is($tr->status($result->{key})->{state}, 'queued', 'happy: status queued before processing');

	run_jobs();

	my $status = $tr->status($result->{key});
	is($status->{state}, 'done', 'happy: status done');
	is($status->{target}, 'zh-Hans', 'happy: status target');
	is($status->{reason}, undef, 'happy: no skip reason');
	is($status->{error}, undef, 'happy: no error');
	is($status->{stats}{translated}, 4, 'happy: stats translated');
	is($status->{stats}{missing}, 0, 'happy: stats missing');
	is($status->{stats}{llm_calls}, 1, 'happy: stats llm_calls');
	like($status->{updated}, qr/^\d+$/, 'happy: status timestamp');

	my $output = read_text($path);
	unlike($output, qr/^\[re:test\]/, 'happy: no marker line is written');
	like($output, qr/^\[00:01\.00\]Hello/, 'happy: the original block starts the file');
	like($output, qr/\[00:01\.00\]Hello/, 'happy: original lines kept');
	like($output, qr/\[00:01\.00\]T:Hello/, 'happy: translated lines added');
	like($output, qr/\[00:04\.00\]T:Last line/, 'happy: last line translated');
	like($output, qr/\n\z/, 'happy: trailing newline kept');

	my $originalAt    = index($output, '[00:01.00]Hello');
	my $translatedAt  = index($output, '[00:01.00]T:Hello');
	ok($originalAt >= 0 && $translatedAt > $originalAt, 'happy: original block comes first');

	is(scalar @{ $llm->{calls} }, 1, 'happy: LLM called once');
	is_deeply($llm->{calls}[0]{lines}, ['Hello', 'World', 'Again', 'Last line'],
		'happy: unique lines handed to the LLM');
	like($llm->{calls}[0]{source}, qr/Hello/, 'happy: lyrics context handed to the LLM');

	my $stored = $cache->get('mai_lyrics_translate_status_' . md5_hex($path));
	ok(defined $stored, 'happy: status stored under the documented cache key');
	my $decoded = JSON::PP->new->utf8->decode($stored);
	is($decoded->{state}, 'done', 'happy: stored status JSON');

	ok(-f $path . '.orig', 'happy: .orig backup created');
	is(read_text($path . '.orig'), $SAMPLE, 'happy: .orig content');
	is(scalar @{ $llm->{detect_calls} }, 0, 'happy: no extra detection call in always mode');

	reset_timers();
}

# ---------------------------------------------------------------------------
# line endings and encodings are preserved
# ---------------------------------------------------------------------------
{
	reset_timers();

	my $crlf = "[00:01.00]Hello\r\n[00:02.00]World\r\n[00:03.00]Again\r\n";
	my $path = write_text(temp_path('crlf'), $crlf);
	my $tr   = $Translator->new(
		config => test_config(),
		llm    => FakeLLM->new,
		cache  => FakeCache->new,
	);
	$tr->enqueue({ path => $path, lyrics => $crlf });
	run_jobs();

	my $output = read_text($path);
	like($output, qr/\r\n/, 'encoding: CRLF preserved');
	unlike($output, qr/(?<!\r)\n/, 'encoding: no bare LF introduced');

	reset_timers();

	# UTF-8 BOM
	my $bomPath = write_bytes(temp_path('bom'), "\xEF\xBB\xBF" . Encode::encode('UTF-8', $SAMPLE));
	$tr = $Translator->new(
		config => test_config(),
		llm    => FakeLLM->new,
		cache  => FakeCache->new,
	);
	$tr->enqueue({ path => $bomPath, lyrics => $SAMPLE });
	run_jobs();

	my $bomOutput = read_bytes($bomPath);
	is(substr($bomOutput, 0, 3), "\xEF\xBB\xBF", 'encoding: UTF-8 BOM preserved');
	utf8::decode($bomOutput);
	like($bomOutput, qr/T:/, 'encoding: BOM file translated');

	reset_timers();

	# UTF-16LE with BOM
	my $utf16Path = write_bytes(temp_path('utf16'), "\xFF\xFE" . Encode::encode('UTF-16LE', $SAMPLE));
	$tr = $Translator->new(
		config => test_config(),
		llm    => FakeLLM->new,
		cache  => FakeCache->new,
	);
	$tr->enqueue({ path => $utf16Path, lyrics => $SAMPLE });
	run_jobs();

	my $utf16Bytes = read_bytes($utf16Path);
	is(substr($utf16Bytes, 0, 2), "\xFF\xFE", 'encoding: UTF-16LE BOM preserved');
	my $utf16Text = Encode::decode('UTF-16LE', substr($utf16Bytes, 2));
	like($utf16Text, qr/T:/, 'encoding: UTF-16LE file translated');

	reset_timers();

	# a source file which is not valid UTF-8 uses the configured save encoding
	my $gbEncoding = Encode::find_encoding('GB18030');

	SKIP: {
		skip 'GB18030 is not available on this host', 2 unless $gbEncoding;

		my $gbText = "[00:01.00]你好\n[00:02.00]世界\n[00:03.00]第三行\n";
		my $gbPath = write_bytes(temp_path('gb18030'), $gbEncoding->encode($gbText));
		Slim::Utils::Prefs::preferences('plugin.musicartistinfo')->set('lyricsSaveEncoding', 'gb18030');

		$tr = $Translator->new(
			config => test_config(),
			llm    => FakeLLM->new,
			cache  => FakeCache->new,
		);
		$tr->enqueue({ path => $gbPath, lyrics => $gbText });
		run_jobs();

		my $gbDecoded = eval { $gbEncoding->decode(read_bytes($gbPath), Encode::FB_CROAK) };
		ok(defined $gbDecoded, 'encoding: GB18030 fallback wrote GB18030 bytes');
		like($gbDecoded, qr/T:/, 'encoding: GB18030 file translated');

		Slim::Utils::Prefs::preferences('plugin.musicartistinfo')->remove('lyricsSaveEncoding');
	}

	reset_timers();
}

# ---------------------------------------------------------------------------
# no-lines-translated
# ---------------------------------------------------------------------------
{
	reset_timers();

	my $path = write_text(temp_path('nolinestrans'), $SAMPLE);
	my $llm  = FakeLLM->new(script => [ { translations => {}, error => undef } ]);
	my $tr   = $Translator->new(
		config => test_config(),
		llm    => $llm,
		cache  => FakeCache->new,
	);

	my $result = $tr->enqueue({ path => $path, lyrics => $SAMPLE });
	run_jobs();

	my $status = $tr->status($result->{key});
	is($status->{state}, 'skipped', 'no-lines-translated: skipped');
	is($status->{reason}, 'no-lines-translated', 'no-lines-translated: reason');
	is(read_text($path), $SAMPLE, 'no-lines-translated: file untouched');

	reset_timers();
}

# ---------------------------------------------------------------------------
# failure: no write, cooldown
# ---------------------------------------------------------------------------
{
	reset_timers();

	my $path  = write_text(temp_path('fail'), $SAMPLE);
	my $llm   = FakeLLM->new(script => [ { translations => {}, error => 'http-400' } ]);
	my $cache = FakeCache->new;
	my $tr    = $Translator->new(
		config => test_config({ max_attempts => 1, fail_cooldown => 600 }),
		llm    => $llm,
		cache  => $cache,
	);

	my $result = $tr->enqueue({ path => $path, lyrics => $SAMPLE });
	run_jobs();

	my $status = $tr->status($result->{key});
	is($status->{state}, 'failed', 'failure: status failed');
	is($status->{reason}, 'failed', 'failure: reason');
	is($status->{error}, 'http-400', 'failure: error code');
	is(read_text($path), $SAMPLE, 'failure: file untouched');
	is(scalar @{ $llm->{calls} }, 1, 'failure: LLM called once');

	my $again = $tr->enqueue({ path => $path, lyrics => $SAMPLE });
	is($again->{error}, 'failed', 'failure: cooldown rejects the next job');
	is(scalar @{ $llm->{calls} }, 1, 'failure: cooldown prevented another LLM call');

	# once the cooldown marker is gone, a new job is accepted again
	$cache->remove('mai_lyrics_translate_cooldown_' . md5_hex($path));
	$tr->clear_state;
	reset_timers();

	my $retry = $tr->enqueue({ path => $path, lyrics => $SAMPLE, force => 1 });
	ok($retry->{queued}, 'failure: job accepted after cooldown');

	reset_timers();
}

# ---------------------------------------------------------------------------
# retry: first attempt fails, second succeeds
# ---------------------------------------------------------------------------
{
	reset_timers();

	my $path = write_text(temp_path('retry'), $SAMPLE);
	my $llm  = FakeLLM->new(script => [
		{ translations => {}, error => 'line-failed' },
		sub {
			my ( $self, $lines, $cb ) = @_;
			my %map;
			$map{$_} = "T:$_" for @$lines;
			return $cb->(\%map, { llm_calls => 1, cache_hits => 0 }, undef);
		},
	]);
	my $tr = $Translator->new(
		config => test_config({ max_attempts => 2, retry_delay => 0, fail_cooldown => 0 }),
		llm    => $llm,
		cache  => FakeCache->new,
	);

	my $result = $tr->enqueue({ path => $path, lyrics => $SAMPLE });
	run_jobs();

	my $status = $tr->status($result->{key});
	is($status->{state}, 'done', 'retry: job done after retry');
	is(scalar @{ $llm->{calls} }, 2, 'retry: LLM called twice');
	like(read_text($path), qr/T:/, 'retry: file written');

	reset_timers();
}

# ---------------------------------------------------------------------------
# stale content and missing file after enqueue
# ---------------------------------------------------------------------------
{
	reset_timers();

	my $path = write_text(temp_path('stale'), $SAMPLE);
	my $llm  = FakeLLM->new;
	my $tr   = $Translator->new(
		config => test_config(),
		llm    => $llm,
		cache  => FakeCache->new,
	);

	my $result = $tr->enqueue({ path => $path, lyrics => $SAMPLE });

	my $changed = "[00:01.00]Changed\n[00:02.00]By someone\n[00:03.00]Else\n";
	write_text($path, $changed);

	run_jobs();

	my $status = $tr->status($result->{key});
	is($status->{state}, 'skipped', 'stale: skipped');
	is($status->{reason}, 'stale', 'stale: reason');
	is(read_text($path), $changed, 'stale: file not overwritten');

	reset_timers();

	$path = write_text(temp_path('vanished'), $SAMPLE);
	$tr = $Translator->new(
		config => test_config(),
		llm    => FakeLLM->new,
		cache  => FakeCache->new,
	);
	$result = $tr->enqueue({ path => $path, lyrics => $SAMPLE });
	unlink $path or die "unlink $path: $!";
	run_jobs();

	$status = $tr->status($result->{key});
	is($status->{state}, 'failed', 'missing file: failed');
	is($status->{error}, 'no-file', 'missing file: error code');

	reset_timers();
}

# ---------------------------------------------------------------------------
# queued detection stage (mode "llm")
# ---------------------------------------------------------------------------
{
	reset_timers();

	my $path = write_text(temp_path('detect-llm'), $SAMPLE);

	my $already = FakeLLM->new(detect => 0.9);
	my $tr = $Translator->new(
		config => test_config({ detect => 'llm', detect_threshold => 0.5 }),
		llm    => $already,
		cache  => FakeCache->new,
	);

	my $result = $tr->enqueue({ path => $path, lyrics => $SAMPLE });
	ok($result->{queued}, 'detect llm: queued without synchronous decision');
	run_jobs();

	my $status = $tr->status($result->{key});
	is($status->{state}, 'skipped', 'detect llm: already target skipped');
	is($status->{reason}, 'already-target', 'detect llm: skip reason');
	is(scalar @{ $already->{detect_calls} }, 1, 'detect llm: LLM detect used');
	is(scalar @{ $already->{calls} }, 0, 'detect llm: no translation call');
	is(read_text($path), $SAMPLE, 'detect llm: file untouched');

	reset_timers();

	my $needs = FakeLLM->new(detect => 0.1);
	$tr = $Translator->new(
		config => test_config({ detect => 'llm', detect_threshold => 0.5 }),
		llm    => $needs,
		cache  => FakeCache->new,
	);

	$result = $tr->enqueue({ path => $path, lyrics => $SAMPLE });
	run_jobs();

	$status = $tr->status($result->{key});
	is($status->{state}, 'done', 'detect llm: low confidence translates');
	is(scalar @{ $needs->{detect_calls} }, 1, 'detect llm: detection call');
	is(scalar @{ $needs->{calls} }, 1, 'detect llm: translation call');
	like(read_text($path), qr/T:/, 'detect llm: file written');

	reset_timers();
}

# ---------------------------------------------------------------------------
# worker-side target detection
# ---------------------------------------------------------------------------
{
	reset_timers();

	# target "en": local rules cannot decide, the worker asks the LLM
	my $path = write_text(temp_path('worker-en'), $SAMPLE);
	my $llm  = FakeLLM->new(detect => 0.95);
	my $tr   = $Translator->new(
		config => test_config({ detect => 'auto', target => 'en', target_label => 'English' }),
		llm    => $llm,
		cache  => FakeCache->new,
	);

	my $result = $tr->enqueue({ path => $path, lyrics => $SAMPLE });
	ok($result->{queued}, 'worker detect: en target queued');
	run_jobs();

	my $status = $tr->status($result->{key});
	is($status->{state}, 'skipped', 'worker detect: already target skipped');
	is($status->{reason}, 'already-target', 'worker detect: skip reason');
	is(scalar @{ $llm->{detect_calls} }, 1, 'worker detect: LLM detect used');
	is(scalar @{ $llm->{calls} }, 0, 'worker detect: no translation call');
	is(read_text($path), $SAMPLE, 'worker detect: file untouched');

	reset_timers();

	# detect => 'always' translates without asking about the target language
	$path = write_text(temp_path('worker-always'), $SAMPLE);
	$llm  = FakeLLM->new(detect => 0.99);
	$tr   = $Translator->new(
		config => test_config({ detect => 'always' }),
		llm    => $llm,
		cache  => FakeCache->new,
	);
	$result = $tr->enqueue({ path => $path, lyrics => $SAMPLE });
	run_jobs();
	is($tr->status($result->{key})->{state}, 'done', 'worker detect: always translates');
	is(scalar @{ $llm->{detect_calls} }, 0, 'worker detect: always skips detection');
	is(scalar @{ $llm->{calls} }, 1, 'worker detect: always translates without detection');

	reset_timers();

	# force skips detection as well
	$path = write_text(temp_path('worker-force'), $SAMPLE);
	$llm  = FakeLLM->new(detect => 0.99);
	$tr   = $Translator->new(
		config => test_config({ detect => 'auto', target => 'en' }),
		llm    => $llm,
		cache  => FakeCache->new,
	);
	$result = $tr->enqueue({ path => $path, lyrics => $SAMPLE, force => 1 });
	run_jobs();
	is($tr->status($result->{key})->{state}, 'done', 'worker detect: force translates');
	is(scalar @{ $llm->{detect_calls} }, 0, 'worker detect: force skips detection');
	is(scalar @{ $llm->{calls} }, 1, 'worker detect: force still translates');

	reset_timers();

	# a detector which never answers must not hang the job
	$path = write_text(temp_path('worker-silent'), $SAMPLE);
	$llm  = FakeLLM->new(detect => 0.99, detect_silent => 1);
	$tr   = $Translator->new(
		config => test_config({ detect => 'auto', target => 'en', detect_timeout => 1 }),
		llm    => $llm,
		cache  => FakeCache->new,
	);
	$result = $tr->enqueue({ path => $path, lyrics => $SAMPLE });
	run_jobs();
	$status = $tr->status($result->{key});
	is($status->{state}, 'done', 'worker detect: watchdog translates after a silent detector');
	is(scalar @{ $llm->{detect_calls} }, 1, 'worker detect: silent detector was asked');
	is(scalar @{ $llm->{calls} }, 1, 'worker detect: translation ran after the watchdog');
	like(read_text($path), qr/T:/, 'worker detect: watchdog wrote the file');

	reset_timers();
}

# ---------------------------------------------------------------------------
# clear_state and status()
# ---------------------------------------------------------------------------
{
	reset_timers();

	my $path = write_text(temp_path('clear'), $SAMPLE);
	my $llm  = FakeLLM->new;
	my $tr   = $Translator->new(
		config => test_config(),
		llm    => $llm,
		cache  => FakeCache->new,
	);

	my $result = $tr->enqueue({ path => $path, lyrics => $SAMPLE });
	ok($tr->clear_state, 'clear_state: returns true');
	run_jobs();

	is(scalar @{ $llm->{calls} }, 0, 'clear_state: queued job dropped');
	is(read_text($path), $SAMPLE, 'clear_state: file untouched');
	is($tr->status($result->{key})->{state}, 'unknown', 'clear_state: status removed');

	is($tr->status('0' x 32)->{state}, 'unknown', 'status: unknown key');
	is($tr->status(undef)->{state}, 'unknown', 'status: missing key');

	reset_timers();
}

# ---------------------------------------------------------------------------
# class level API (lazily uses the real settings)
# ---------------------------------------------------------------------------
{
	is($Translator->enabled, 0, 'class API: translation disabled by default');
	is($Translator->status('0' x 32)->{state}, 'unknown', 'class API: status unknown');

	my $classPath = write_text(temp_path('class'), $SAMPLE);
	is($Translator->enqueue({ path => $classPath, lyrics => $SAMPLE })->{error},
		'disabled', 'class API: enqueue uses the real (disabled) settings');
}

done_testing();
