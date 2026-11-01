#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use lib "$Bin/lib";

use JSON::PP ();
use Test::More;

binmode STDOUT, ':utf8';

require Plugins::MusicArtistInfo::Lyrics::Translate::LLM;

my $LLM = 'Plugins::MusicArtistInfo::Lyrics::Translate::LLM';

# ---------------------------------------------------------------------------
# fakes
# ---------------------------------------------------------------------------

package FakeCache;

sub new {
	my $class = shift;
	return bless { data => {}, ttl => {} }, $class;
}

sub get {
	my ($self, $key) = @_;
	return $self->{data}{$key};
}

sub set {
	my ($self, $key, $value, $ttl) = @_;
	$self->{data}{$key} = $value;
	$self->{ttl}{$key}  = $ttl;
	return 1;
}

sub remove {
	my ($self, $key) = @_;
	delete $self->{data}{$key};
	return 1;
}

sub keys {
	my $self = shift;
	return sort keys %{ $self->{data} };
}

package main;

# Returns ($sender, $calls).  Each script item is either
#   [ $parsed_json, $status, $error ]   (answered immediately), or
#   sub { my ($request, $cb, $decoded_body) = @_; ... }
# A missing script item produces an empty (invalid) response.
sub make_sender {
	my @script = @_;

	my $calls = [];

	my $sender = sub {
		my ($request, $cb) = @_;

		my $body = eval { JSON::PP->new->utf8->decode($request->{body}) } || {};

		push @$calls, { request => $request, body => $body };

		my $next = shift @script;
		$next = [ { choices => [ { message => { content => '' } } ] }, 200, undef ]
			unless defined $next;

		if (ref $next eq 'CODE') {
			$next->($request, $cb, $body);
			return;
		}

		$cb->(@$next);
	};

	return ($sender, $calls);
}

# Deferred sender: requests stay pending until the test releases them.
sub make_deferred_sender {
	my $calls   = [];
	my $pending = [];

	my $sender = sub {
		my ($request, $cb) = @_;

		my $body = eval { JSON::PP->new->utf8->decode($request->{body}) } || {};

		push @$calls, { request => $request, body => $body };
		push @$pending, { request => $request, cb => $cb, body => $body };
	};

	# release($content) answers the oldest pending request with a
	# chat-completions success payload; release(undef, $error) with a failure.
	my $release = sub {
		my ($content, $error) = @_;

		my $item = shift @$pending;
		return unless $item;

		if (defined $error) {
			$item->{cb}->(undef, undef, $error);
		}
		else {
			$item->{cb}->({ choices => [ { message => { content => $content } } ] }, 200, undef);
		}
	};

	return ($sender, $calls, $pending, $release);
}

sub json_text {
	my $data = shift;
	return JSON::PP->new->canonical(1)->encode($data);
}

sub success {
	my $payload = shift;
	return [ { choices => [ { message => { content => json_text($payload) } } ] }, 200, undef ];
}

sub content_response {
	my $content = shift;
	return [ { choices => [ { message => { content => $content } } ] }, 200, undef ];
}

sub base_config {
	return {
		api_key           => 'sk-test',
		model             => 'test-model',
		api_base          => 'https://api.example.com',
		api_path          => '/chat/completions',
		response_format   => 1,
		thinking          => 0,
		reasoning_effort  => '',
		mode              => 'batch',
		cache             => 0,
		cache_ttl         => '30d',
		target            => 'zh-Hans',
		target_label      => '简体中文',
		batch_system      => 'BATCH {{target}}',
		line_system       => 'LINE {{target}} {{source}}',
		detect_system     => 'DETECT {{target}}',
		batch_size        => 0,
		batch_temperature => 0.7,
		batch_timeout     => 42,
		batch_max_tokens  => 0,
		line_concurrency  => 4,
		line_temperature  => 0.5,
		line_timeout      => 30,
		line_max_tokens   => 0,
		detect_timeout    => 11,
	};
}

# ---------------------------------------------------------------------------
# request building
# ---------------------------------------------------------------------------

subtest 'batch request body' => sub {
	my $config = base_config();
	my ($sender, $calls) = make_sender(success({ 'Hello' => '你好' }));
	my $llm = $LLM->new(config => $config, sender => $sender);

	$llm->translate_lines([ 'Hello' ], 'CONTEXT', sub {});

	is(scalar @$calls, 1, 'one request sent');

	my $call = $calls->[0];
	is($call->{request}{url}, 'https://api.example.com/chat/completions', 'URL = base + path');
	is($call->{request}{timeout}, 42, 'batch timeout used');
	is($call->{request}{headers}{'Content-Type'}, 'application/json', 'JSON content type');
	is($call->{request}{headers}{Authorization}, 'Bearer sk-test', 'auth header from config');

	my $body = $call->{body};
	is($body->{model}, 'test-model', 'model');
	is($body->{temperature}, 0.7, 'temperature');
	is(scalar @{ $body->{messages} }, 2, 'system + user message');
	is($body->{messages}[0]{role}, 'system', 'system role');
	is($body->{messages}[0]{content}, 'BATCH 简体中文', 'system prompt rendered with target');
	is($body->{messages}[1]{role}, 'user', 'user role');
	is_deeply(JSON::PP->new->decode($body->{messages}[1]{content}), { 'Hello' => '' }, 'user message is the JSON map');
	is_deeply($body->{response_format}, { type => 'json_object' }, 'response_format for batch');
	ok(!exists $body->{max_tokens}, 'max_tokens omitted when 0');
	ok(!exists $body->{thinking}, 'thinking omitted by default');
};

subtest 'thinking and max_tokens' => sub {
	my $config = base_config();
	$config->{thinking}         = 1;
	$config->{reasoning_effort} = 'high';
	$config->{batch_max_tokens} = 100;

	my ($sender, $calls) = make_sender(content_response('ok'));
	my $llm = $LLM->new(config => $config, sender => $sender);

	$llm->chat('batch', 'SYS', 'USER', sub {});

	my $body = $calls->[0]{body};
	is_deeply($body->{thinking}, { type => 'enabled', reasoning_effort => 'high' }, 'thinking block with effort');
	is($body->{max_tokens}, 100, 'max_tokens when > 0');

	# effort is optional
	$config->{reasoning_effort} = '';
	($sender, $calls) = make_sender(content_response('ok'));
	$llm = $LLM->new(config => $config, sender => $sender);
	$llm->chat('batch', 'SYS', 'USER', sub {});
	is_deeply($calls->[0]{body}{thinking}, { type => 'enabled' }, 'thinking without effort');
};

subtest 'response_format can be disabled' => sub {
	my $config = base_config();
	$config->{response_format} = 0;

	my ($sender, $calls) = make_sender(content_response('plain'));
	my $llm = $LLM->new(config => $config, sender => $sender);
	$llm->chat('batch', 'SYS', 'USER', sub {});

	ok(!exists $calls->[0]{body}{response_format}, 'no response_format when disabled');
};

subtest 'custom auth and extra headers' => sub {
	my $config = base_config();
	$config->{auth_header}     = 'api-key';
	$config->{auth_prefix}     = '';
	$config->{api_key}         = 'secret-key';
	$config->{extra_headers}   = "X-Extra: 1\nX-More: two\nContent-Type: text/plain";

	my ($sender, $calls) = make_sender(content_response('ok'));
	my $llm = $LLM->new(config => $config, sender => $sender);
	$llm->chat('line', 'SYS', 'USER', sub {});

	my $headers = $calls->[0]{request}{headers};
	is($headers->{'api-key'}, 'secret-key', 'configurable auth header and prefix');
	ok(!exists $headers->{Authorization}, 'no default Authorization header');
	is($headers->{'X-Extra'}, '1', 'extra header 1');
	is($headers->{'X-More'}, 'two', 'extra header 2');
	is($headers->{'Content-Type'}, 'application/json', 'Content-Type cannot be overridden');
};

subtest 'api path without leading slash' => sub {
	my $config = base_config();
	$config->{api_base} = 'https://api.example.com/';
	$config->{api_path} = 'chat/completions';

	my ($sender, $calls) = make_sender(content_response('ok'));
	my $llm = $LLM->new(config => $config, sender => $sender);
	$llm->chat('line', 'SYS', 'USER', sub {});

	is($calls->[0]{request}{url}, 'https://api.example.com/chat/completions', 'slashes normalised');
};

subtest 'missing api key' => sub {
	my $config = base_config();
	$config->{api_key} = undef;

	local $ENV{DEEPSEEK_API_KEY};
	delete $ENV{DEEPSEEK_API_KEY};

	my ($sender, $calls) = make_sender(success({ 'a' => 'A' }));
	my $llm = $LLM->new(config => $config, sender => $sender);

	my ($translations, $stats, $error);
	$llm->translate_lines([ 'a' ], '', sub { ($translations, $stats, $error) = @_; });

	ok(!scalar @$calls, 'no request without a key');
	is($error, 'missing-api-key', 'missing key error');
	is_deeply($translations, {}, 'no translations');
};

# ---------------------------------------------------------------------------
# batch translation
# ---------------------------------------------------------------------------

subtest 'batch success' => sub {
	my $config = base_config();
	my ($sender, $calls) = make_sender(success({ one => '一', two => '二' }));
	my $llm = $LLM->new(config => $config, sender => $sender);

	my ($translations, $stats, $error);
	$llm->translate_lines([ 'one', 'two' ], 'CTX', sub { ($translations, $stats, $error) = @_; });

	is($error, undef, 'no error');
	is_deeply($translations, { one => '一', two => '二' }, 'translations');
	is_deeply($stats, { llm_calls => 1, cache_hits => 0 }, 'stats');
	is($calls->[0]{body}{messages}[0]{content}, 'BATCH 简体中文', 'system prompt');
};

subtest 'fenced JSON reply' => sub {
	my $config = base_config();
	my ($sender) = make_sender(content_response("```json\n" . json_text({ one => '一' }) . "\n```"));
	my $llm = $LLM->new(config => $config, sender => $sender);

	my ($translations, undef, $error);
	$llm->translate_lines([ 'one' ], '', sub { ($translations, undef, $error) = @_; });

	is($error, undef, 'no error');
	is_deeply($translations, { one => '一' }, 'fenced JSON parsed');
};

subtest 'prose JSON reply' => sub {
	my $config = base_config();
	my ($sender) = make_sender(content_response('Sure, here it is: ' . json_text({ one => '一' }) . ' done.'));
	my $llm = $LLM->new(config => $config, sender => $sender);

	my ($translations, undef, $error);
	$llm->translate_lines([ 'one' ], '', sub { ($translations, undef, $error) = @_; });

	is($error, undef, 'no error');
	is_deeply($translations, { one => '一' }, 'JSON extracted from prose');
};

subtest 'batch partial result falls back to line stage' => sub {
	my $config = base_config();
	my ($sender, $calls) = make_sender(
		success({ one => '一' }),
		content_response('二'),
	);
	my $llm = $LLM->new(config => $config, sender => $sender);

	my ($translations, $stats, $error);
	$llm->translate_lines([ 'one', 'two' ], 'CTX', sub { ($translations, $stats, $error) = @_; });

	is($error, undef, 'no error');
	is_deeply($translations, { one => '一', two => '二' }, 'missing line translated by line stage');
	is(scalar @$calls, 2, 'batch + one line request');
	is($calls->[1]{body}{messages}[0]{content}, 'LINE 简体中文 CTX', 'line system prompt rendered with target and source');
	is($calls->[1]{body}{messages}[1]{content}, 'two', 'line user message');
};

subtest 'batch failure probes one line then falls back' => sub {
	my $config = base_config();
	my ($sender, $calls) = make_sender(
		[ undef, 500, 'http-500' ],
		content_response('一'),
		content_response('二'),
	);
	my $llm = $LLM->new(config => $config, sender => $sender);

	my ($translations, $stats, $error);
	$llm->translate_lines([ 'one', 'two' ], 'CTX', sub { ($translations, $stats, $error) = @_; });

	is($error, undef, 'no error');
	is_deeply($translations, { one => '一', two => '二' }, 'probe + fallback translated all lines');
	is(scalar @$calls, 3, 'batch, probe, fallback');
	is($calls->[1]{body}{messages}[1]{content}, 'one', 'first line probed');
	is($calls->[2]{body}{messages}[1]{content}, 'two', 'remaining line translated');
};

subtest 'batch failure and probe failure gives up all' => sub {
	my $config = base_config();
	my ($sender, $calls) = make_sender(
		[ undef, 500, 'http-500' ],
		[ undef, undef, 'timeout' ],
	);
	my $llm = $LLM->new(config => $config, sender => $sender);

	my ($translations, $stats, $error);
	$llm->translate_lines([ 'one', 'two' ], '', sub { ($translations, $stats, $error) = @_; });

	isnt($error, undef, 'error reported');
	is_deeply($translations, {}, 'no partial translations after probe failure');
	is(scalar @$calls, 2, 'only batch + probe attempted');
};

subtest 'empty reply is an error' => sub {
	my $config = base_config();
	my ($sender) = make_sender([ { choices => [ { message => { content => '   ' } } ] }, 200, undef ]);
	my $llm = $LLM->new(config => $config, sender => $sender);

	my ($content, $error);
	$llm->chat('batch', 'SYS', 'USER', sub { ($content, $error) = @_; });

	is($content, undef, 'no content');
	is($error, 'empty-response', 'empty response error');
};

subtest 'invalid reply is an error' => sub {
	my $config = base_config();
	my ($sender) = make_sender([ undef, 200, undef ]);
	my $llm = $LLM->new(config => $config, sender => $sender);

	my ($content, $error);
	$llm->chat('batch', 'SYS', 'USER', sub { ($content, $error) = @_; });

	is($content, undef, 'no content');
	is($error, 'invalid-response', 'invalid response error');
};

subtest 'api error reply' => sub {
	my $config = base_config();
	my ($sender) = make_sender([ { error => { message => 'bad model' } }, 200, undef ]);
	my $llm = $LLM->new(config => $config, sender => $sender);

	my ($content, $error);
	$llm->chat('batch', 'SYS', 'USER', sub { ($content, $error) = @_; });

	is($content, undef, 'no content');
	is($error, 'bad model', 'API error message reported');
};

subtest 'batch size chunking' => sub {
	my $config = base_config();
	$config->{batch_size} = 2;
	my ($sender, $calls) = make_sender(
		success({ one => '一', two => '二' }),
		success({ three => '三' }),
	);
	my $llm = $LLM->new(config => $config, sender => $sender);

	my ($translations, $stats, $error);
	$llm->translate_lines([ 'one', 'two', 'three' ], '', sub { ($translations, $stats, $error) = @_; });

	is($error, undef, 'no error');
	is_deeply($translations, { one => '一', two => '二', three => '三' }, 'all lines translated');
	is(scalar @$calls, 2, 'two chunks');
	is_deeply(JSON::PP->new->decode($calls->[0]{body}{messages}[1]{content}), { one => '', two => '' }, 'first chunk has two lines');
	is_deeply(JSON::PP->new->decode($calls->[1]{body}{messages}[1]{content}), { three => '' }, 'second chunk has one line');
};

# ---------------------------------------------------------------------------
# line mode
# ---------------------------------------------------------------------------

subtest 'line mode cleans 译文 prefix' => sub {
	my $config = base_config();
	$config->{mode} = 'line';
	my ($sender, $calls) = make_sender(content_response('译文：一'));
	my $llm = $LLM->new(config => $config, sender => $sender);

	my ($translations, $stats, $error);
	$llm->translate_lines([ 'one' ], 'CTX', sub { ($translations, $stats, $error) = @_; });

	is($error, undef, 'no error');
	is_deeply($translations, { one => '一' }, 'reply prefix cleaned');
	my $body = $calls->[0]{body};
	is($body->{temperature}, 0.5, 'line temperature');
	ok(!exists $body->{response_format}, 'no response_format for line stage');
	is($calls->[0]{request}{timeout}, 30, 'line timeout');
};

# ---------------------------------------------------------------------------
# caching
# ---------------------------------------------------------------------------

subtest 'cache hit avoids the second call' => sub {
	my $config = base_config();
	$config->{cache} = 1;
	my $cache = FakeCache->new();
	my ($sender, $calls) = make_sender(success({ one => '一' }));
	my $llm = $LLM->new(config => $config, sender => $sender, cache => $cache);

	my ($first, $first_stats, $first_error);
	$llm->translate_lines([ 'one' ], '', sub { ($first, $first_stats, $first_error) = @_; });

	my ($second, $second_stats, $second_error);
	$llm->translate_lines([ 'one' ], '', sub { ($second, $second_stats, $second_error) = @_; });

	is($first_error, undef, 'first call ok');
	is($second_error, undef, 'second call ok');
	is_deeply($second, { one => '一' }, 'cached translation');
	is(scalar @$calls, 1, 'only one request');
	is($second_stats->{llm_calls}, 0, 'no LLM call on cache hit');
	is($second_stats->{cache_hits}, 1, 'cache hit counted');

	my @keys = $cache->keys;
	is(scalar @keys, 1, 'one cache entry');
	ok(!utf8::is_utf8($cache->get($keys[0])), 'cache stores UTF-8 bytes');
	is($cache->{ttl}{$keys[0]}, '30d', 'configured TTL used');
};

subtest 'line cache stores cleaned translation' => sub {
	my $config = base_config();
	$config->{cache} = 1;
	$config->{mode}  = 'line';
	my $cache = FakeCache->new();
	my ($sender, $calls) = make_sender(content_response('译文：一'));
	my $llm = $LLM->new(config => $config, sender => $sender, cache => $cache);

	$llm->translate_lines([ 'one' ], '', sub {});
	$llm->translate_lines([ 'one' ], '', sub {});

	is(scalar @$calls, 1, 'line result cached');
};

subtest 'partial batch results are not cached' => sub {
	my $config = base_config();
	$config->{cache} = 1;
	my $cache = FakeCache->new();
	my ($sender, $calls) = make_sender(
		success({ one => '一' }),
		content_response('二'),
	);
	my $llm = $LLM->new(config => $config, sender => $sender, cache => $cache);

	$llm->translate_lines([ 'one', 'two' ], '', sub {});

	my @keys = $cache->keys;
	is(scalar @keys, 1, 'only the line fallback result is cached');
	my $decoded = eval { JSON::PP->new->utf8->decode($cache->get($keys[0])) };
	ok(!(ref $decoded eq 'HASH'), 'no batch map cached for a partial batch');
};

# ---------------------------------------------------------------------------
# 400 / response_format fallback
# ---------------------------------------------------------------------------

subtest '400 response_format fallback' => sub {
	my $config = base_config();

	my (@seen, $calls);
	$calls = [];
	my $sender = sub {
		my ($request, $cb) = @_;
		my $body = JSON::PP->new->utf8->decode($request->{body});
		push @$calls, { request => $request, body => $body };
		push @seen, exists $body->{response_format} ? 1 : 0;
		if (exists $body->{response_format}) {
			return $cb->(undef, 400, 'http-400');
		}
		return $cb->({ choices => [ { message => { content => json_text({ one => '一' }) } } ] }, 200, undef);
	};

	my $llm = $LLM->new(config => $config, sender => $sender);

	my ($translations, $stats, $error);
	$llm->translate_lines([ 'one' ], '', sub { ($translations, $stats, $error) = @_; });

	is($error, undef, 'retry succeeded');
	is_deeply($translations, { one => '一' }, 'translation after retry');
	is(scalar @$calls, 2, 'two requests');
	is_deeply(\@seen, [ 1, 0 ], 'first with response_format, retry without');
	is($stats->{llm_calls}, 2, 'both requests counted');
};

subtest '400 without response_format is not retried' => sub {
	my $config = base_config();
	$config->{response_format} = 0;
	my ($sender, $calls) = make_sender([ undef, 400, 'http-400' ]);
	my $llm = $LLM->new(config => $config, sender => $sender);

	my ($content, $error);
	$llm->chat('batch', 'SYS', 'USER', sub { ($content, $error) = @_; });

	is(scalar @$calls, 1, 'no retry without response_format');
	is($error, 'http-400', 'error reported');
};

# ---------------------------------------------------------------------------
# in-flight coalescing
# ---------------------------------------------------------------------------

subtest 'identical in-flight requests are coalesced' => sub {
	my $config = base_config();
	my ($sender, $calls, $pending, $release) = make_deferred_sender();
	my $llm = $LLM->new(config => $config, sender => $sender);

	my (@first, @second);
	$llm->translate_lines([ 'one' ], '', sub { @first = @_; });
	$llm->translate_lines([ 'one' ], '', sub { @second = @_; });

	is(scalar @$calls, 1, 'one shared request');
	is(scalar @$pending, 1, 'one pending request');

	$release->(json_text({ one => '一' }));

	is_deeply($first[0], { one => '一' }, 'first caller got the translation');
	is_deeply($second[0], { one => '一' }, 'second caller got the same translation');
};

# ---------------------------------------------------------------------------
# concurrency queue (line mode)
# ---------------------------------------------------------------------------

subtest 'line concurrency limit' => sub {
	my $config = base_config();
	$config->{mode}             = 'line';
	$config->{line_concurrency} = 2;

	my ($sender, $calls, $pending, $release) = make_deferred_sender();
	my $llm = $LLM->new(config => $config, sender => $sender);

	my ($translations, $stats, $error, $done);
	$llm->translate_lines([ 'a', 'b', 'c' ], '', sub {
		($translations, $stats, $error) = @_;
		$done = 1;
	});

	is(scalar @$calls, 2, 'two requests in flight');
	ok(!$done, 'not finished');

	my $line = $pending->[0]{body}{messages}[1]{content};
	$release->("T-$line");

	is(scalar @$calls, 3, 'next request starts after one finished');
	is(scalar @$pending, 2, 'still at most two in flight');

	while (@$pending) {
		my $item = $pending->[0];
		my $queued_line = $item->{body}{messages}[1]{content};
		$release->("T-$queued_line");
	}

	ok($done, 'finished');
	is($error, undef, 'no error');
	is_deeply($translations, { a => 'T-a', b => 'T-b', c => 'T-c' }, 'all lines translated');
	is_deeply($stats, { llm_calls => 3, cache_hits => 0 }, 'stats');
};

# ---------------------------------------------------------------------------
# detect
# ---------------------------------------------------------------------------

subtest 'detect parses confidence' => sub {
	my %cases = (
		'0.87'                 => 0.87,
		'The answer is 0.42.'  => 0.42,
		'1.5'                  => 1,
		'-0.2'                 => 0,
	);

	while (my ($content, $expected) = each %cases) {
		my $config = base_config();
		my ($sender, $calls) = make_sender(content_response($content));
		my $llm = $LLM->new(config => $config, sender => $sender);

		my ($confidence, $error);
		$llm->detect('some text', sub { ($confidence, $error) = @_; });

		is($error, undef, "no error for '$content'");
		is($confidence, $expected, "confidence for '$content'");

		my $body = $calls->[0]{body};
		ok(!exists $body->{response_format}, 'detect never uses response_format');
		ok(!exists $body->{max_tokens}, 'detect has no max_tokens');
		is($body->{temperature}, 0, 'detect is deterministic');
		is($body->{messages}[0]{content}, 'DETECT 简体中文', 'detect system prompt');
		is($body->{messages}[1]{content}, 'some text', 'detect user prompt');
		is($calls->[0]{request}{timeout}, 11, 'detect timeout');
	}
};

subtest 'detect without a number' => sub {
	my $config = base_config();
	my ($sender) = make_sender(content_response('I cannot tell.'));
	my $llm = $LLM->new(config => $config, sender => $sender);

	my ($confidence, $error);
	$llm->detect('text', sub { ($confidence, $error) = @_; });

	is($confidence, undef, 'no confidence');
	is($error, 'no-confidence', 'no-confidence error');
};

# ---------------------------------------------------------------------------
# render / misc
# ---------------------------------------------------------------------------

subtest 'render placeholders' => sub {
	my ($text, $error) = $LLM->render('Hi {{target}} {{json}}', { target => 'X', json => 'J' }, 'batch');
	is($text, 'Hi X J', 'placeholders replaced');
	is($error, undef, 'no error');

	($text, $error) = $LLM->render('Hi {{bogus}}', {}, 'batch');
	like($error, qr/unknown-placeholder:bogus/, 'unknown placeholder error');

	($text, $error) = $LLM->render('{{json}}', { json => 'J' }, 'line');
	like($error, qr/unknown-placeholder:json/, 'placeholder not allowed for stage');

	($text, $error) = $LLM->render('{{source}}', {}, 'line');
	is($text, '{{source}}', 'missing allowed value stays literal');
	is($error, undef, 'missing value is not an error');

	($text, $error) = $LLM->render('x', {}, 'nope');
	is($error, 'invalid-stage', 'invalid stage');
};

subtest 'invalid arguments' => sub {
	my $config = base_config();
	my ($sender, $calls) = make_sender();
	my $llm = $LLM->new(config => $config, sender => $sender);

	my ($translations, $stats, $error);
	$llm->translate_lines('not-an-array', '', sub { ($translations, $stats, $error) = @_; });

	is($error, 'invalid-lines', 'invalid lines error');
	is(scalar @$calls, 0, 'no request');

	($translations, $stats, $error) = (undef, undef, undef);
	$llm->translate_lines([], '', sub { ($translations, $stats, $error) = @_; });
	is_deeply($translations, {}, 'empty input returns empty map');
	is($error, undef, 'empty input is not an error');

	my ($content, $chat_error);
	$llm->chat('nope', 'S', 'U', sub { ($content, $chat_error) = @_; });
	is($chat_error, 'invalid-stage', 'invalid chat stage');
};

subtest 'sender exception is reported' => sub {
	my $config = base_config();
	my $llm = $LLM->new(config => $config, sender => sub { die "boom\n" });

	my ($content, $error);
	$llm->chat('batch', 'S', 'U', sub { ($content, $error) = @_; });

	is($content, undef, 'no content');
	like($error, qr/sender-error/, 'sender exception reported');
};

done_testing();
