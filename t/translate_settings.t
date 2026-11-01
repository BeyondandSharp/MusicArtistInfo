#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use lib "$Bin/lib";

use Encode ();
use File::Basename qw(dirname);
use File::Path ();
use JSON::PP ();
use Test::More;

binmode STDOUT, ':utf8';

use Slim::Utils::Prefs;

use Plugins::MusicArtistInfo::Lyrics::TranslateSettings;

my $TS = 'Plugins::MusicArtistInfo::Lyrics::TranslateSettings';

my $key_file = $TS->key_file();
my $key_dir  = dirname($key_file);

File::Path::mkpath($key_dir) unless -d $key_dir;
unlink $key_file;
delete $ENV{DEEPSEEK_API_KEY};

END {
	unlink $key_file;
}

sub reset_prefs { Slim::Utils::Prefs::reset() }

# ---------------------------------------------------------------------------
# defaults / metadata
# ---------------------------------------------------------------------------

subtest 'defaults' => sub {
	my $defaults = $TS->defaults();

	is($defaults->{lyricsTranslate}, 0, 'translation off by default');
	is($defaults->{lyricsTranslateTarget}, 'zh-Hans', 'default target');
	is($defaults->{lyricsTranslateTargetCustom}, '', 'no custom target');
	is($defaults->{lyricsTranslateApiBase}, 'https://api.deepseek.com', 'API base');
	is($defaults->{lyricsTranslateApiPath}, '/chat/completions', 'API path');
	is($defaults->{lyricsTranslateModel}, 'deepseek-flash', 'model');
	is($defaults->{lyricsTranslateAuthHeader}, 'Authorization', 'auth header');
	is($defaults->{lyricsTranslateAuthPrefix}, 'Bearer ', 'auth prefix');
	is($defaults->{lyricsTranslateExtraHeaders}, '', 'no extra headers');
	is($defaults->{lyricsTranslateResponseFormat}, 1, 'response_format on');
	is($defaults->{lyricsTranslateOnFileLoad}, 1, 'translate on file load');
	is($defaults->{lyricsTranslateOnSave}, 1, 'translate on save');

	is($defaults->{lyricsTranslateMode}, 'batch', 'batch mode');
	is($defaults->{lyricsTranslateBatchSize}, 0, 'batch size 0 (all)');
	is($defaults->{lyricsTranslateBatchTemperature}, 1.3, 'batch temperature');
	is($defaults->{lyricsTranslateBatchTimeout}, 60, 'batch timeout');
	is($defaults->{lyricsTranslateBatchMaxTokens}, 0, 'batch max tokens');
	is($defaults->{lyricsTranslateLineConcurrency}, 4, 'line concurrency');
	is($defaults->{lyricsTranslateLineTemperature}, 1.3, 'line temperature');
	is($defaults->{lyricsTranslateLineTimeout}, 60, 'line timeout');
	is($defaults->{lyricsTranslateLineMaxTokens}, 0, 'line max tokens');

	is($defaults->{lyricsTranslateThinking}, 0, 'thinking off');
	is($defaults->{lyricsTranslateReasoningEffort}, '', 'no reasoning effort');
	is($defaults->{lyricsTranslateDetect}, 'auto', 'detect auto');
	is($defaults->{lyricsTranslateDetectThreshold}, 0.5, 'detect threshold');
	is($defaults->{lyricsTranslateLinguaWeight}, 0.5, 'lingua weight');
	is($defaults->{lyricsTranslateFastlangWeight}, 0.5, 'fastlang weight');
	is($defaults->{lyricsTranslateDetectTimeout}, 30, 'detect timeout');

	is($defaults->{lyricsTranslateMarker}, '[re:Deepseek翻译]', 'marker');
	is($defaults->{lyricsTranslateMinTimestamps}, 3, 'min timestamps');
	is($defaults->{lyricsTranslateMaxRepeatedTimestamps}, 3, 'max repeated timestamps');
	is($defaults->{lyricsTranslateMultiline}, 'drop', 'multiline drop');
	is($defaults->{lyricsTranslateFailedLine}, 'original', 'failed line original');

	is($defaults->{lyricsTranslateCache}, 1, 'cache on');
	is($defaults->{lyricsTranslateCacheTtl}, '30d', 'cache TTL');
	is($defaults->{lyricsTranslateBackup}, 'once', 'backup once');
	is($defaults->{lyricsTranslateQueueLimit}, 20, 'queue limit');
	is($defaults->{lyricsTranslateMaxAttempts}, 2, 'max attempts');
	is($defaults->{lyricsTranslateRetryDelay}, 60, 'retry delay');
	is($defaults->{lyricsTranslateFailCooldown}, 600, 'fail cooldown');

	like($defaults->{lyricsTranslateBatchSystem}, qr/native translator/, 'batch prompt is English');
	like($defaults->{lyricsTranslateBatchSystem}, qr/\{\{target\}\}/, 'batch prompt has {{target}}');
	like($defaults->{lyricsTranslateLineSystem}, qr/native translator/, 'line prompt is English');
	like($defaults->{lyricsTranslateLineSystem}, qr/\{\{target\}\}/, 'line prompt has {{target}}');
	like($defaults->{lyricsTranslateLineSystem}, qr/\{\{source\}\}/, 'line prompt has {{source}}');
	like($defaults->{lyricsTranslateLineSystem}, qr/The following is for context reference/, 'line prompt context sentence');
	like($defaults->{lyricsTranslateDetectSystem}, qr/language detection expert/, 'detect prompt is English');
	like($defaults->{lyricsTranslateDetectSystem}, qr/\{\{target\}\}/, 'detect prompt has {{target}}');

	my @key_like = grep { /ApiKey|api_key/ } keys %$defaults;
	is_deeply(\@key_like, [], 'the API key is not a preference');

	# callers must not be able to corrupt the defaults
	$defaults->{lyricsTranslate} = 1;
	is($TS->defaults()->{lyricsTranslate}, 0, 'defaults returns a copy');
};

subtest 'targets and placeholders' => sub {
	my @targets = $TS->targets();
	is_deeply(\@targets, [qw(zh-Hans zh-Hant en ja ko custom)], 'target list');
	my $targets = $TS->targets();
	is(ref $targets, 'ARRAY', 'targets in scalar context is an arrayref');

	is_deeply([ $TS->placeholders('batch') ], [qw(target json source count path)], 'batch placeholders');
	is_deeply([ $TS->placeholders('line') ], [qw(target line source index total path)], 'line placeholders');
	is_deeply([ $TS->placeholders('detect') ], [qw(target text path lines)], 'detect placeholders');
	is_deeply([ $TS->placeholders('nope') ], [], 'unknown stage has no placeholders');

	is($TS->target_label('zh-Hans', ''), '简体中文', 'zh-Hans label');
	is($TS->target_label('zh-Hant', ''), '繁體中文', 'zh-Hant label');
	is($TS->target_label('en', ''), 'English', 'en label');
	is($TS->target_label('ja', ''), '日本語', 'ja label');
	is($TS->target_label('ko', ''), '한국어', 'ko label');
	is($TS->target_label('custom', '  Klingon  '), 'Klingon', 'custom label trimmed');
	is($TS->target_label('custom', ''), 'custom', 'empty custom label fallback');
	is($TS->target_label('xx', ''), 'xx', 'unknown label falls back to the code');
};

subtest 'render_template' => sub {
	my ($text, $error) = $TS->render_template('Hello {{target}}', { target => '简体中文' }, 'batch');
	is($text, 'Hello 简体中文', 'target rendered');
	is($error, undef, 'no error');

	($text, $error) = $TS->render_template('{{json}}', { json => '{"a":1}' }, 'batch');
	is($text, '{"a":1}', 'json rendered');
	is($error, undef, 'no error');

	($text, $error) = $TS->render_template('{{bogus}}', {}, 'batch');
	like($error, qr/unknown-placeholder:bogus/, 'unknown placeholder error');
	is($text, '{{bogus}}', 'unknown placeholder stays literal');

	($text, $error) = $TS->render_template('{{source}}', {}, 'line');
	is($text, '{{source}}', 'allowed but missing value stays literal');
	is($error, undef, 'missing value is not an error');

	($text, $error) = $TS->render_template('{{json}}', { json => 'x' }, 'line');
	like($error, qr/unknown-placeholder:json/, 'stage allow-list enforced');

	($text, $error) = $TS->render_template('x', {}, 'nope');
	is($error, 'invalid-stage', 'invalid stage');
};

# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------

subtest 'config defaults' => sub {
	reset_prefs();
	unlink $key_file;

	my $config = $TS->config();

	is($config->{enabled}, 0, 'disabled by default');
	is($config->{mode}, 'batch', 'mode');
	is($config->{target}, 'zh-Hans', 'target');
	is($config->{target_label}, '简体中文', 'target label');
	is($config->{model}, 'deepseek-flash', 'model');
	is($config->{api_base}, 'https://api.deepseek.com', 'api base');
	is($config->{api_path}, '/chat/completions', 'api path');
	is($config->{response_format}, 1, 'response_format');
	is($config->{batch_size}, 0, 'batch size');
	is($config->{batch_temperature}, 1.3, 'batch temperature');
	is($config->{line_concurrency}, 4, 'line concurrency');
	is($config->{cache}, 1, 'cache');
	is($config->{cache_ttl}, '30d', 'cache TTL');
	is($config->{api_key_configured}, 0, 'no API key configured');
	is($config->{api_key_source}, 'none', 'no API key source');
	ok(!exists $config->{api_key}, 'config does not contain the API key');
	is_deeply($config->{extra_headers}, {}, 'no extra headers');

	like($config->{batch_system}, qr/简体中文/, 'batch prompt rendered with target');
	unlike($config->{batch_system}, qr/\{\{target\}\}/, 'no {{target}} left in batch prompt');
	like($config->{line_system}, qr/简体中文/, 'line prompt rendered with target');
	like($config->{line_system}, qr/\{\{source\}\}/, 'line prompt keeps {{source}}');
	like($config->{detect_system}, qr/简体中文/, 'detect prompt rendered with target');

	is_deeply($config->{errors}, [], 'no config errors');
};

subtest 'config overrides' => sub {
	reset_prefs();
	my $prefs = preferences('plugin.musicartistinfo');

	$prefs->set('lyricsTranslate', 1);
	$prefs->set('lyricsTranslateModel', 'other-model');
	$prefs->set('lyricsTranslateTarget', 'en');
	$prefs->set('lyricsTranslateBatchSize', 10);
	$prefs->set('lyricsTranslateThinking', 1);
	$prefs->set('lyricsTranslateExtraHeaders', "X-One: 1\nX-Two: 2\nContent-Type: text/plain");

	my $config = $TS->config();

	is($config->{enabled}, 1, 'enabled');
	is($config->{model}, 'other-model', 'model override');
	is($config->{target}, 'en', 'target override');
	is($config->{target_label}, 'English', 'target label override');
	is($config->{batch_size}, 10, 'batch size override');
	is($config->{thinking}, 1, 'thinking override');
	is_deeply($config->{extra_headers}, { 'X-One' => '1', 'X-Two' => '2' }, 'extra headers parsed');
	like($config->{batch_system}, qr/English/, 'prompt rendered for the new target');

	my $signature = $TS->cache_signature($config);
	$prefs->set('lyricsTranslateModel', 'third-model');
	my $config2 = $TS->config();
	isnt($TS->cache_signature($config2), $signature, 'signature changes with the model');

	$signature = $TS->cache_signature($config2);
	$prefs->set('lyricsTranslateBatchSystem', 'Completely different {{target}}');
	my $config3 = $TS->config();
	isnt($TS->cache_signature($config3), $signature, 'signature changes with the prompt');
};

subtest 'config rejects unknown placeholders and falls back' => sub {
	reset_prefs();
	my $prefs = preferences('plugin.musicartistinfo');

	$prefs->set('lyricsTranslateBatchSystem', 'Translate {{target}} using {{bogus}}');

	my $config = $TS->config();

	ok(scalar @{ $config->{errors} }, 'config error reported');
	like($config->{errors}[0], qr/invalid-prompt-batch/, 'prompt error mentions the stage');
	unlike($config->{batch_system}, qr/\{\{bogus\}\}/, 'invalid prompt replaced');
	like($config->{batch_system}, qr/native translator/, 'default prompt used as fallback');
	like($config->{batch_system}, qr/简体中文/, 'fallback prompt rendered with target');
};

subtest 'config never contains the plain key' => sub {
	reset_prefs();

	ok($TS->store_key('sk-config-secret'), 'key stored');

	my $config = $TS->config();
	my $json   = JSON::PP->new->canonical(1)->encode($config);

	unlike($json, qr/sk-config-secret/, 'config JSON has no plaintext key');
	ok(!exists $config->{api_key}, 'no api_key field');
	is($config->{api_key_configured}, 1, 'configured flag');
	is($config->{api_key_source}, 'file', 'key source');

	$TS->clear_key;
};

# ---------------------------------------------------------------------------
# validate
# ---------------------------------------------------------------------------

sub valid_settings {
	return {
		pref_lyricsTranslate                  => 1,
		pref_lyricsTranslateTarget            => 'zh-Hans',
		pref_lyricsTranslateTargetCustom      => '',
		pref_lyricsTranslateApiBase           => 'https://api.deepseek.com',
		pref_lyricsTranslateApiPath           => '/chat/completions',
		pref_lyricsTranslateAuthHeader        => 'Authorization',
		pref_lyricsTranslateAuthPrefix        => 'Bearer ',
		pref_lyricsTranslateExtraHeaders      => "X-One: 1\nX-Two: 2",
		pref_lyricsTranslateMode              => 'batch',
		pref_lyricsTranslateDetect            => 'auto',
		pref_lyricsTranslateDetectThreshold   => '0.5',
		pref_lyricsTranslateDetectTimeout     => '30',
		pref_lyricsTranslateMultiline         => 'drop',
		pref_lyricsTranslateFailedLine        => 'original',
		pref_lyricsTranslateBackup            => 'once',
		pref_lyricsTranslateReasoningEffort   => '',
		pref_lyricsTranslateBatchSize         => '0',
		pref_lyricsTranslateBatchTemperature  => '1.3',
		pref_lyricsTranslateBatchTimeout      => '60',
		pref_lyricsTranslateBatchMaxTokens    => '0',
		pref_lyricsTranslateLineConcurrency   => '4',
		pref_lyricsTranslateLineTemperature   => '1.3',
		pref_lyricsTranslateLineTimeout       => '60',
		pref_lyricsTranslateLineMaxTokens     => '0',
		pref_lyricsTranslateCache             => 1,
		pref_lyricsTranslateCacheTtl          => '30d',
		pref_lyricsTranslateMinTimestamps     => '3',
		pref_lyricsTranslateMaxRepeatedTimestamps => '3',
		pref_lyricsTranslateQueueLimit        => '20',
		pref_lyricsTranslateMaxAttempts       => '2',
		pref_lyricsTranslateRetryDelay        => '60',
		pref_lyricsTranslateFailCooldown      => '600',
		pref_lyricsTranslateMarker            => '[re:Deepseek翻译]',
		pref_lyricsTranslateBatchSystem       => 'Batch {{target}}',
		pref_lyricsTranslateLineSystem        => 'Line {{target}} {{source}}',
		pref_lyricsTranslateDetectSystem      => 'Detect {{target}}',
	};
}

sub subtest_validate_case {
	my ($name, $mutator, $pattern) = @_;

	my $settings = valid_settings();
	$mutator->($settings);

	my $errors = $TS->validate($settings);

	my @hits = grep { $_ =~ $pattern } @$errors;
	ok(scalar @hits, "$name rejected") or diag explain $errors;

	return;
}

subtest 'validate accepts the default settings' => sub {
	reset_prefs();
	my $errors = $TS->validate(valid_settings());
	is_deeply($errors, [], 'no errors');
};

subtest 'validate enums' => sub {
	subtest_validate_case('invalid target', sub { $_[0]{pref_lyricsTranslateTarget} = 'xx' }, qr/target language/i);
	subtest_validate_case('invalid mode', sub { $_[0]{pref_lyricsTranslateMode} = 'nope' }, qr/lyricsTranslateMode/);
	subtest_validate_case('invalid detect', sub { $_[0]{pref_lyricsTranslateDetect} = 'nope' }, qr/lyricsTranslateDetect/);
	subtest_validate_case('invalid multiline', sub { $_[0]{pref_lyricsTranslateMultiline} = 'nope' }, qr/lyricsTranslateMultiline/);
	subtest_validate_case('invalid failed line', sub { $_[0]{pref_lyricsTranslateFailedLine} = 'nope' }, qr/lyricsTranslateFailedLine/);
	subtest_validate_case('invalid backup', sub { $_[0]{pref_lyricsTranslateBackup} = 'nope' }, qr/lyricsTranslateBackup/);
	subtest_validate_case('invalid reasoning effort', sub { $_[0]{pref_lyricsTranslateReasoningEffort} = 'nope' }, qr/lyricsTranslateReasoningEffort/);
};

subtest 'validate custom target' => sub {
	subtest_validate_case('empty custom target', sub {
		$_[0]{pref_lyricsTranslateTarget} = 'custom';
		$_[0]{pref_lyricsTranslateTargetCustom} = '  ';
	}, qr/Custom target language/);

	my $settings = valid_settings();
	$settings->{pref_lyricsTranslateTarget} = 'custom';
	$settings->{pref_lyricsTranslateTargetCustom} = 'Klingon';
	is_deeply($TS->validate($settings), [], 'custom target accepted');
};

subtest 'validate URL and headers' => sub {
	subtest_validate_case('ftp base', sub { $_[0]{pref_lyricsTranslateApiBase} = 'ftp://example.com' }, qr/API base URL/);
	subtest_validate_case('base without scheme', sub { $_[0]{pref_lyricsTranslateApiBase} = 'example.com' }, qr/API base URL/);
	subtest_validate_case('path without slash', sub { $_[0]{pref_lyricsTranslateApiPath} = 'chat' }, qr/API path/);
	subtest_validate_case('bad auth header', sub { $_[0]{pref_lyricsTranslateAuthHeader} = 'Bad Header' }, qr/authentication header/);
	subtest_validate_case('bad auth prefix', sub { $_[0]{pref_lyricsTranslateAuthPrefix} = "Bearer\nX" }, qr/authentication prefix/);
	subtest_validate_case('bad extra header', sub { $_[0]{pref_lyricsTranslateExtraHeaders} = "X-One: 1\nnot a header" }, qr/extra header on line 2/);
	subtest_validate_case('content type override', sub { $_[0]{pref_lyricsTranslateExtraHeaders} = 'Content-Type: text/plain' }, qr/Content-Type/);
	subtest_validate_case('empty header value', sub { $_[0]{pref_lyricsTranslateExtraHeaders} = 'X-One: ' }, qr/Empty value/);
};

subtest 'validate numbers' => sub {
	subtest_validate_case('negative batch size', sub { $_[0]{pref_lyricsTranslateBatchSize} = '-1' }, qr/lyricsTranslateBatchSize/);
	subtest_validate_case('huge batch size', sub { $_[0]{pref_lyricsTranslateBatchSize} = '201' }, qr/lyricsTranslateBatchSize/);
	subtest_validate_case('non numeric batch size', sub { $_[0]{pref_lyricsTranslateBatchSize} = 'x' }, qr/lyricsTranslateBatchSize/);
	subtest_validate_case('hot temperature', sub { $_[0]{pref_lyricsTranslateBatchTemperature} = '3' }, qr/lyricsTranslateBatchTemperature/);
	subtest_validate_case('zero concurrency', sub { $_[0]{pref_lyricsTranslateLineConcurrency} = '0' }, qr/lyricsTranslateLineConcurrency/);
	subtest_validate_case('huge threshold', sub { $_[0]{pref_lyricsTranslateDetectThreshold} = '2' }, qr/lyricsTranslateDetectThreshold/);
	subtest_validate_case('huge lingua weight', sub { $_[0]{pref_lyricsTranslateLinguaWeight} = '1.5' }, qr/lyricsTranslateLinguaWeight/);
	subtest_validate_case('huge fastlang weight', sub { $_[0]{pref_lyricsTranslateFastlangWeight} = '1.5' }, qr/lyricsTranslateFastlangWeight/);
	subtest_validate_case('zero timeout', sub { $_[0]{pref_lyricsTranslateBatchTimeout} = '0' }, qr/lyricsTranslateBatchTimeout/);
	subtest_validate_case('huge max tokens', sub { $_[0]{pref_lyricsTranslateBatchMaxTokens} = '99999' }, qr/lyricsTranslateBatchMaxTokens/);
	subtest_validate_case('negative timestamps', sub { $_[0]{pref_lyricsTranslateMinTimestamps} = '-1' }, qr/lyricsTranslateMinTimestamps/);
	subtest_validate_case('zero repeated', sub { $_[0]{pref_lyricsTranslateMaxRepeatedTimestamps} = '0' }, qr/lyricsTranslateMaxRepeatedTimestamps/);
	subtest_validate_case('zero queue', sub { $_[0]{pref_lyricsTranslateQueueLimit} = '0' }, qr/lyricsTranslateQueueLimit/);
	subtest_validate_case('zero attempts', sub { $_[0]{pref_lyricsTranslateMaxAttempts} = '0' }, qr/lyricsTranslateMaxAttempts/);
	subtest_validate_case('bad retry delay', sub { $_[0]{pref_lyricsTranslateRetryDelay} = '-5' }, qr/lyricsTranslateRetryDelay/);
	subtest_validate_case('huge cooldown', sub { $_[0]{pref_lyricsTranslateFailCooldown} = '999999' }, qr/lyricsTranslateFailCooldown/);
};

subtest 'validate cache TTL values' => sub {
	foreach my $good ('30d', '5m', '1y', '2592000') {
		my $settings = valid_settings();
		$settings->{pref_lyricsTranslateCacheTtl} = $good;
		is_deeply($TS->validate($settings), [], "TTL $good accepted");
	}

	foreach my $bad ('abc', '9999999', '30x', '') {
		my $settings = valid_settings();
		$settings->{pref_lyricsTranslateCacheTtl} = $bad;
		my @hits = grep { /cache TTL/ } @{ $TS->validate($settings) };
		ok(scalar @hits, "TTL '$bad' rejected");
	}
};

subtest 'validate marker and prompts' => sub {
	subtest_validate_case('empty marker', sub { $_[0]{pref_lyricsTranslateMarker} = '' }, qr/Marker/);
	subtest_validate_case('long marker', sub { $_[0]{pref_lyricsTranslateMarker} = 'x' x 65 }, qr/Marker/);
	subtest_validate_case('empty prompt', sub { $_[0]{pref_lyricsTranslateBatchSystem} = '   ' }, qr/Prompt for batch/);
	subtest_validate_case('unknown prompt placeholder', sub { $_[0]{pref_lyricsTranslateLineSystem} = 'Line {{nope}}' }, qr/Prompt for line/);
	subtest_validate_case('wrong stage placeholder', sub { $_[0]{pref_lyricsTranslateDetectSystem} = 'Detect {{json}}' }, qr/Prompt for detect/);
};

subtest 'validate never echoes the submitted API key' => sub {
	my $settings = valid_settings();
	$settings->{pref_lyricsTranslateApiKey} = 'sk-SUPER-SECRET';
	$settings->{pref_lyricsTranslateMode}   = 'nope';

	my $errors = $TS->validate($settings);
	my $json   = JSON::PP->new->canonical(1)->encode($errors);

	ok(scalar @$errors, 'invalid mode reported');
	unlike($json, qr/sk-SUPER-SECRET/, 'API key not echoed in errors');
	unlike(join(' ', @$errors), qr/lyricsTranslateApiKey/, 'API key is not validated as a pref');
};

# ---------------------------------------------------------------------------
# API key file
# ---------------------------------------------------------------------------

subtest 'key status when nothing is configured' => sub {
	unlink $key_file;
	delete $ENV{DEEPSEEK_API_KEY};

	my $status = $TS->key_status();
	is_deeply($status, { configured => 0, source => 'none' }, 'not configured');
	is($TS->api_key(), undef, 'no API key');
};

subtest 'store, trim and read the key' => sub {
	unlink $key_file;

	ok($TS->store_key("  sk-secret-123  \n"), 'key stored');
	ok(-f $key_file, 'key file exists');

	my $mode = (stat($key_file))[2] & 0777;
	is(sprintf('%04o', $mode), '0600', 'key file is 0600');

	is($TS->api_key(), 'sk-secret-123', 'trimmed key returned');

	my $status = $TS->key_status();
	is_deeply($status, { configured => 1, source => 'file' }, 'file key status');
	unlike(JSON::PP->new->canonical(1)->encode($status), qr/sk-secret-123/, 'status JSON has no plaintext key');

	# the raw file content must be the trimmed key
	open(my $fh, '<:raw', $key_file) or die $!;
	local $/;
	my $raw = <$fh>;
	close($fh);
	is(Encode::decode('UTF-8', $raw), 'sk-secret-123', 'stored without surrounding whitespace');
};

subtest 'replace and clear the key' => sub {
	unlink $key_file;

	ok($TS->store_key('first-key'), 'first key stored');
	ok($TS->store_key('second-key'), 'key replaced');
	is($TS->api_key(), 'second-key', 'new key returned');
	is(scalar(($TS->key_status())->{configured}), 1, 'still configured');

	ok($TS->clear_key(), 'key cleared');
	ok(!-e $key_file, 'key file removed');
	is_deeply($TS->key_status(), { configured => 0, source => 'none' }, 'no key after clear');
};

subtest 'invalid keys are rejected' => sub {
	unlink $key_file;
	ok($TS->store_key('keep-me'), 'baseline key stored');

	ok(!$TS->store_key(''), 'empty key rejected');
	ok(!$TS->store_key('bad' . "\n" . 'key'), 'key with newline rejected');
	ok(!$TS->store_key('x' x 513), 'key longer than 512 rejected');
	is($TS->api_key(), 'keep-me', 'previous key kept');
};

subtest 'environment variable fallback' => sub {
	unlink $key_file;
	local $ENV{DEEPSEEK_API_KEY} = '  sk-env-key  ';

	is($TS->api_key(), 'sk-env-key', 'env key used when no file');
	is_deeply($TS->key_status(), { configured => 1, source => 'env' }, 'env key status');

	ok($TS->store_key('sk-file-key'), 'file key stored');
	is($TS->api_key(), 'sk-file-key', 'file key has precedence over env');
	is_deeply($TS->key_status(), { configured => 1, source => 'file' }, 'file source reported');
};

subtest 'permissions are repaired' => sub {
	unlink $key_file;

	my $fh;
	open($fh, '>:raw', $key_file) or die $!;
	print {$fh} 'sk-perm-key';
	close($fh);
	chmod(0644, $key_file);
	is(sprintf('%04o', (stat($key_file))[2] & 0777), '0644', 'test file starts at 0644');

	ok($TS->key_permissions_ok(), 'permissions repaired');
	is(sprintf('%04o', (stat($key_file))[2] & 0777), '0600', 'mode is now 0600');
	is($TS->api_key(), 'sk-perm-key', 'key still readable');
};

subtest 'config exposes only the key status' => sub {
	reset_prefs();
	unlink $key_file;
	local $ENV{DEEPSEEK_API_KEY} = 'sk-env-secret';

	my $config = $TS->config();
	my $json   = JSON::PP->new->canonical(1)->encode($config);

	unlike($json, qr/sk-env-secret/, 'env key not in config');
	is($config->{api_key_source}, 'env', 'env source');
	ok(!exists $config->{api_key}, 'no plaintext field');
};

done_testing();
