#!/usr/bin/perl

use strict;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/lib";

use Test::More;

require Plugins::MusicArtistInfo::Lyrics::Translate::Detect;

my $class = 'Plugins::MusicArtistInfo::Lyrics::Translate::Detect';

# A package based detector mirroring the Plugins::LangID::API layout.
{
	package FakeLangID;

	our @CALLS;
	our $RESULT;

	sub detect {
		my ($class, $text, $cb) = @_;
		push @CALLS, $text;
		$cb->($RESULT);
		return;
	}
}

# Run a detection with synchronous fakes; returns the reply and the number of
# callback invocations.
sub run_detect {
	my ($text, $target, $opts) = @_;

	my $reply;
	my $calls = 0;

	$class->detect_target($text, $target, $opts || {}, sub {
		$calls++;
		$reply = shift;
	});

	return ($reply, $calls);
}

# ---------------------------------------------------------------------------
# target_label
# ---------------------------------------------------------------------------
is($class->target_label('zh-Hans'), '简体中文', 'label for zh-Hans');
is($class->target_label('zh-Hant'), '繁體中文', 'label for zh-Hant');
is($class->target_label('zh_CN'), '简体中文', 'zh_CN alias label');
is($class->target_label('zh-TW'), '繁體中文', 'zh-TW alias label');
is($class->target_label('en'), 'English', 'label for en');
is($class->target_label('en-US'), 'English', 'en-US alias label');
is($class->target_label('ja'), '日本語', 'label for ja');
is($class->target_label('ko'), '한국어', 'label for ko');
is($class->target_label('custom', '  文言  '), '文言', 'custom label is trimmed');
is($class->target_label('custom'), '', 'custom label without text');
is($class->target_label(undef), '', 'missing target label');
is($class->target_label('fr'), 'fr', 'unknown target label falls back to identifier');

# ---------------------------------------------------------------------------
# script_counts
# ---------------------------------------------------------------------------
my $counts = $class->script_counts("Hello, world! 123");
is($counts->{latin}, 10, 'latin letters counted');
is($counts->{total}, 10, 'punctuation and digits are ignored');

$counts = $class->script_counts("你好，世界！");
is($counts->{han}, 4, 'han letters counted');
is($counts->{total}, 4, 'CJK punctuation is ignored');

$counts = $class->script_counts("こんにちは");
is($counts->{kana}, 5, 'hiragana counted');
$counts = $class->script_counts("コンニチハ");
is($counts->{kana}, 5, 'katakana counted');
$counts = $class->script_counts("안녕하세요");
is($counts->{hangul}, 5, 'hangul counted');
$counts = $class->script_counts("Привет");
is($counts->{cyrillic}, 6, 'cyrillic counted');
$counts = $class->script_counts("Γειά σου");
is($counts->{greek}, 7, 'greek counted');
$counts = $class->script_counts("مرحبا");
is($counts->{arabic}, 5, 'arabic counted');
$counts = $class->script_counts("שלום");
is($counts->{hebrew}, 4, 'hebrew counted');

$counts = $class->script_counts("Hello 世界");
is($counts->{latin}, 5, 'mixed text: latin part');
is($counts->{han}, 2, 'mixed text: han part');
is($counts->{total}, 7, 'mixed text: total');

$counts = $class->script_counts("٣");
is($counts->{arabic}, 0, 'arabic-indic digit ignored');
is($counts->{total}, 0, 'digit only text has no letters');

$counts = $class->script_counts('!!!');
is($counts->{total}, 0, 'punctuation only text has no letters');

$counts = $class->script_counts('');
is($counts->{total}, 0, 'empty text has no letters');

$counts = $class->script_counts(undef);
is($counts->{total}, 0, 'undef text has no letters');

# ---------------------------------------------------------------------------
# CJK targets use the LangID plugin first
# ---------------------------------------------------------------------------
$class->reset;

my @calls;
my $detector_result = { language => 'Chinese', iso => 'zh', confidence => 0.97 };

$class->set_external_detector(sub {
	my ($text, $cb) = @_;
	push @calls, $text;
	$cb->($detector_result);
	return;
});

my ($reply, $count) = run_detect('你好世界', 'zh-Hans');
is($reply->{needs_translation}, 0, 'langid: text already in target language');
is($reply->{source}, 'langid', 'langid: source reported');
is($reply->{language}, 'zh', 'langid: detected language normalized');
is($reply->{confidence}, 0.97, 'langid: confidence passed through');
is($count, 1, 'langid: callback invoked once');
is(scalar @calls, 1, 'langid: detector used for CJK target');
is($calls[0], '你好世界', 'langid: detector received the text');

$detector_result = { language => 'Japanese', iso => 'ja', confidence => 0.99 };
($reply) = run_detect('こんにちは', 'zh-Hans');
is($reply->{needs_translation}, 1, 'langid: other language needs translation');
is($reply->{source}, 'langid', 'langid: detected answer is authoritative');
is($reply->{language}, 'ja', 'langid: detected language reported');

# no_external forces the synchronous local rules (used by Translator enqueue)
@calls = ();
($reply) = run_detect('你好世界', 'zh-Hans', { no_external => 1 });
is($reply->{needs_translation}, 0, 'no_external: local rules decide');
is($reply->{source}, 'rules', 'no_external: source is rules');
is(scalar @calls, 0, 'no_external: detector is not called');

($reply) = run_detect('こんにちは', 'ja', { no_external => 1 });
is($reply->{needs_translation}, 0, 'no_external: kana is already Japanese');

# package name detector, Plugins::LangID::API method layout
$class->reset;
@FakeLangID::CALLS = ();
$FakeLangID::RESULT = { language => 'Japanese', iso => 'ja', confidence => 0.9 };
$class->set_external_detector('FakeLangID');

($reply) = run_detect('こんにちは', 'ja');
is($reply->{needs_translation}, 0, 'package detector: text already target');
is($reply->{source}, 'langid', 'package detector: source');
is($reply->{language}, 'ja', 'package detector: language');
is(scalar @FakeLangID::CALLS, 1, 'package detector: detect() called');

# a detector answering synchronously by returning a hash
$class->reset;
$class->set_external_detector(sub {
	return { iso => 'ja', confidence => 0.9 };
});
($reply) = run_detect('こんにちは', 'ja');
is($reply->{needs_translation}, 0, 'synchronous detector return accepted');
is($reply->{source}, 'langid', 'synchronous detector return: source');

# ---------------------------------------------------------------------------
# LangID fallbacks: low confidence, timeout/error, missing confidence
# ---------------------------------------------------------------------------
$class->reset;
$class->set_external_detector(sub {
	$_[1]->({ iso => 'ja', confidence => 0.2 });
	return;
});
($reply) = run_detect('你好世界', 'zh-Hans');
is($reply->{needs_translation}, 0, 'low confidence: rules decide');
is($reply->{source}, 'rules', 'low confidence: rules source');
is($reply->{language}, 'zh-Hans', 'low confidence: target reported');
cmp_ok($reply->{confidence}, '>=', 0.99, 'low confidence: han ratio as rule confidence');

$class->reset;
$class->set_external_detector(sub {
	$_[1]->({ error => 'timeout' });
	return;
});
($reply) = run_detect('こんにちは世界', 'ja');
is($reply->{needs_translation}, 0, 'detector timeout: rules decide');
is($reply->{source}, 'rules', 'detector timeout: rules source');

$class->set_external_detector(sub {
	die "detector exploded\n";
});
($reply) = run_detect('こんにちは', 'ja');
is($reply->{needs_translation}, 0, 'dying detector: rules decide');
is($reply->{source}, 'rules', 'dying detector: rules source');

$class->reset;
$class->set_external_detector(sub {
	$_[1]->({ language => 'Chinese' });
	return;
});
($reply) = run_detect('你好世界', 'zh-Hans');
is($reply->{source}, 'rules', 'detector without confidence falls back to rules');
is($reply->{needs_translation}, 0, 'detector without confidence: rules decide');

$class->reset;
$class->set_external_detector(sub {
	my ($text, $cb) = @_;
	$cb->({ iso => 'ja', confidence => 0.9 });
	$cb->({ iso => 'zh', confidence => 0.9 });
	return;
});
($reply, $count) = run_detect('こんにちは', 'ja');
is($count, 1, 'detector answering twice: callback still invoked once');
is($reply->{language}, 'ja', 'detector answering twice: first answer wins');

# ---------------------------------------------------------------------------
# no detector: local rules only
# ---------------------------------------------------------------------------
$class->reset;
($reply) = run_detect('你好世界', 'zh-Hans');
is($reply->{needs_translation}, 0, 'no detector: rules detect Chinese');
is($reply->{source}, 'rules', 'no detector: rules source');
is($reply->{language}, 'zh-Hans', 'no detector: target reported');

# ---------------------------------------------------------------------------
# non-CJK targets skip the LangID plugin
# ---------------------------------------------------------------------------
$class->reset;
@calls = ();
$class->set_external_detector(sub {
	push @calls, 'called';
	$_[1]->({ iso => 'zh', confidence => 0.99 });
	return;
});

($reply) = run_detect('hello world', 'en');
is($reply->{needs_translation}, 1, 'en target: translate without a local rule');
is($reply->{source}, 'rules', 'en target: rules path');
is(scalar @calls, 0, 'en target: LangID skipped');

($reply) = run_detect('hello world', 'custom', { custom => '文言' });
is($reply->{needs_translation}, 1, 'custom target: translate without a local rule');
is($reply->{source}, 'rules', 'custom target: rules path');
is(scalar @calls, 0, 'custom target: LangID skipped');

# ---------------------------------------------------------------------------
# plain Han vs kana / hangul text
# ---------------------------------------------------------------------------
$class->reset;
($reply) = run_detect('你好世界', 'zh-Hans');
is($reply->{needs_translation}, 0, 'plain han: Chinese');

($reply) = run_detect('こんにちは世界', 'zh-Hans');
is($reply->{needs_translation}, 1, 'kana text: not Chinese');

($reply) = run_detect('こんにちは世界', 'ja');
is($reply->{needs_translation}, 0, 'kana text: Japanese');

($reply) = run_detect('你好世界', 'ja');
is($reply->{needs_translation}, 1, 'plain han: not confidently Japanese');

($reply) = run_detect('你好世界안', 'zh-Hans');
is($reply->{needs_translation}, 1, 'hangul mixed in: not Chinese');

($reply) = run_detect('안녕하세요', 'ko');
is($reply->{needs_translation}, 0, 'hangul text: Korean');

($reply) = run_detect('안녕하세요', 'ja');
is($reply->{needs_translation}, 1, 'hangul text: not Japanese');

# kanji heavy text with a single kana is still Japanese
my $kanji_heavy = ('世' x 100) . 'の';
$counts = $class->script_counts($kanji_heavy);
is($counts->{han}, 100, 'kanji heavy: han counted');
is($counts->{kana}, 1, 'kanji heavy: single kana counted');
($reply) = run_detect($kanji_heavy, 'ja');
is($reply->{needs_translation}, 0, 'kanji heavy with kana: Japanese');

# ---------------------------------------------------------------------------
# mode 'always' forces a translation without any detection
# ---------------------------------------------------------------------------
$class->reset;
@calls = ();
my $llm_calls = 0;
$class->set_external_detector(sub {
	push @calls, 'detector';
	$_[1]->({ iso => 'zh', confidence => 0.99 });
	return;
});

($reply) = run_detect('你好世界', 'zh-Hans', {
	mode       => 'always',
	llm_detect => sub { $llm_calls++; $_[1]->(0.9); return },
});
is($reply->{needs_translation}, 1, 'always: forces translation');
is($reply->{source}, 'forced', 'always: forced source');
is($reply->{language}, 'zh-Hans', 'always: target reported');
is(scalar @calls, 0, 'always: LangID not called');
is($llm_calls, 0, 'always: LLM not called');

# ---------------------------------------------------------------------------
# mode 'llm' skips LangID and rules
# ---------------------------------------------------------------------------
$class->reset;
@calls = ();
$class->set_external_detector(sub {
	push @calls, 'detector';
	$_[1]->({ iso => 'zh', confidence => 0.99 });
	return;
});

($reply) = run_detect('你好世界', 'zh-Hans', {
	mode       => 'llm',
	llm_detect => sub { $_[1]->(0.1, undef); return },
});
is($reply->{needs_translation}, 1, 'llm mode: low confidence translates');
is($reply->{source}, 'llm', 'llm mode: source');
is($reply->{confidence}, 0.1, 'llm mode: confidence');
is($reply->{language}, 'zh-Hans', 'llm mode: target reported');
is(scalar @calls, 0, 'llm mode: LangID skipped');

($reply) = run_detect('你好世界', 'zh-Hans', {
	mode       => 'llm',
	llm_detect => sub { $_[1]->(0.9); return },
});
is($reply->{needs_translation}, 0, 'llm mode: high confidence is already target');
is($reply->{source}, 'llm', 'llm mode: high confidence source');

($reply) = run_detect('你好世界', 'zh-Hans', {
	mode       => 'llm',
	llm_detect => sub { $_[1]->(undef, 'timeout'); return },
});
is($reply->{needs_translation}, 1, 'llm mode: error translates');
is($reply->{source}, 'llm', 'llm mode: error source');

($reply) = run_detect('你好世界', 'zh-Hans', { mode => 'llm' });
is($reply->{needs_translation}, 1, 'llm mode: missing detector translates');
is($reply->{source}, 'llm', 'llm mode: missing detector source');

($reply) = run_detect('你好世界', 'zh-Hans', {
	mode       => 'llm',
	llm_detect => sub { die "llm exploded\n" },
});
is($reply->{needs_translation}, 1, 'llm mode: dying detector translates');
is($reply->{source}, 'llm', 'llm mode: dying detector source');

# ---------------------------------------------------------------------------
# model confidence weight blends the local score with the model confidence
# ---------------------------------------------------------------------------
$class->reset;

($reply) = run_detect('Hello 你好', 'zh-Hans', {
	model_weight => 0,
	llm_detect   => sub { $_[1]->(0.9); return },
});
is($reply->{needs_translation}, 1, 'weight 0: the local score decides');
ok(defined $reply->{local_score}, 'weight 0: local score reported');
is($reply->{model_weight}, 0, 'weight 0: weight reported');

($reply) = run_detect('Hello 你好', 'zh-Hans', {
	model_weight => 1,
	llm_detect   => sub { $_[1]->(0.9); return },
});
is($reply->{needs_translation}, 0, 'weight 1: the model confidence is authoritative');
is($reply->{confidence}, 0.9, 'weight 1: raw model confidence reported');

($reply) = run_detect('Hello 你好', 'zh-Hans', {
	model_weight => 0.5,
	llm_detect   => sub { $_[1]->(0.9); return },
});
is($reply->{needs_translation}, 0, 'weight 0.5: blended score is already target');
ok($reply->{score} > $reply->{local_score}, 'weight 0.5: blended score is between local and model');

# ---------------------------------------------------------------------------
# mode 'auto' with an injected LLM detector
# ---------------------------------------------------------------------------
$class->reset;
@calls = ();
$class->set_external_detector(sub {
	push @calls, 'detector';
	$_[1]->({ iso => 'en', confidence => 0.99 });
	return;
});

($reply) = run_detect('hello world', 'en', {
	llm_detect => sub { $_[1]->(0.85); return },
});
is($reply->{needs_translation}, 0, 'auto + LLM: already target');
is($reply->{source}, 'llm', 'auto + LLM: source');
is($reply->{confidence}, 0.85, 'auto + LLM: confidence');
is(scalar @calls, 0, 'auto + LLM: LangID still skipped for en');

($reply) = run_detect('hello world', 'en', {
	llm_detect => sub { $_[1]->(0.2); return },
});
is($reply->{needs_translation}, 1, 'auto + LLM: low confidence translates');

($reply) = run_detect('hello world', 'en', {
	llm_detect => sub { die "llm exploded\n" },
});
is($reply->{needs_translation}, 1, 'auto + LLM: dying LLM translates');
is($reply->{source}, 'llm', 'auto + LLM: dying LLM source');

# ---------------------------------------------------------------------------
# ISO normalization of targets and detector results
# ---------------------------------------------------------------------------
$class->reset;
($reply) = run_detect('你好世界', 'zh_CN');
is($reply->{language}, 'zh-Hans', 'target zh_CN normalized to zh-Hans');

($reply) = run_detect('你好世界', 'zh-TW');
is($reply->{language}, 'zh-Hant', 'target zh-TW normalized to zh-Hant');

($reply) = run_detect('日本語のテキスト', 'ja-JP');
is($reply->{needs_translation}, 0, 'target ja-JP detects Japanese');
is($reply->{language}, 'ja', 'target ja-JP normalized to ja');

$class->set_external_detector(sub {
	$_[1]->({ language => 'Chinese', iso => 'zh-CN', confidence => 0.95 });
	return;
});
($reply) = run_detect('你好世界', 'zh-Hant');
is($reply->{needs_translation}, 0, 'zh variety matches either Chinese target');
is($reply->{language}, 'zh', 'detected iso zh-CN normalized to zh');

$class->set_external_detector(sub {
	$_[1]->({ language => 'Japanese', iso => 'ja-JP', confidence => 0.95 });
	return;
});
($reply) = run_detect('こんにちは', 'zh-Hans');
is($reply->{needs_translation}, 1, 'detected Japanese does not match Chinese target');
is($reply->{language}, 'ja', 'detected iso ja-JP normalized to ja');

# ---------------------------------------------------------------------------
# threshold handling
# ---------------------------------------------------------------------------
$class->reset;
$class->set_external_detector(sub {
	$_[1]->({ iso => 'ja', confidence => 0.3 });
	return;
});

($reply) = run_detect('ありがとう', 'zh-Hans', { threshold => 0.2 });
is($reply->{source}, 'langid', 'threshold 0.2: detector trusted');
is($reply->{needs_translation}, 1, 'threshold 0.2: Japanese needs Chinese translation');

($reply) = run_detect('ありがとう', 'zh-Hans', { threshold => 0.5 });
is($reply->{source}, 'rules', 'threshold 0.5: falls back to rules');
is($reply->{needs_translation}, 1, 'threshold 0.5: kana text is not Chinese');

# the default threshold is 0.5
$class->reset;
$class->set_external_detector(sub {
	$_[1]->({ iso => 'zh', confidence => 0.4 });
	return;
});
($reply) = run_detect('你好世界', 'zh-Hans');
is($reply->{source}, 'rules', 'confidence below the default threshold falls back');

# ---------------------------------------------------------------------------
# option validation and reset
# ---------------------------------------------------------------------------
$class->reset;
($reply) = run_detect('你好世界', 'zh-Hans', { mode => 'bogus' });
is($reply->{needs_translation}, 0, 'unknown mode falls back to auto');
is($reply->{source}, 'rules', 'unknown mode: rules source');

$class->set_external_detector(sub {
	$_[1]->({ iso => 'ja', confidence => 0.99 });
	return;
});
$class->reset;
($reply) = run_detect('你好世界', 'zh-Hans');
is($reply->{source}, 'rules', 'reset clears the injected detector');

$class->set_external_detector(sub {
	$_[1]->({ iso => 'ja', confidence => 0.99 });
	return;
});
$class->set_external_detector(undef);
($reply) = run_detect('你好世界', 'zh-Hans');
is($reply->{source}, 'rules', 'set_external_detector(undef) clears the detector');

# ---------------------------------------------------------------------------
# plain function call style also works
# ---------------------------------------------------------------------------
my $direct = Plugins::MusicArtistInfo::Lyrics::Translate::Detect::script_counts('abc');
is($direct->{latin}, 3, 'plain function script_counts');

my $direct_reply;
Plugins::MusicArtistInfo::Lyrics::Translate::Detect::detect_target('你好世界', 'zh-Hans', {}, sub {
	$direct_reply = shift;
});
is($direct_reply->{needs_translation}, 0, 'plain function detect_target');

done_testing();
