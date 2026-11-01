#!/usr/bin/perl

use strict;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/lib";

use Test::More;

require Plugins::MusicArtistInfo::Lyrics::Translate::Detect;

my $Detect = 'Plugins::MusicArtistInfo::Lyrics::Translate::Detect';

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

sub detector {
	my ($confidence, $language) = @_;

	return {
		confidence => $confidence,
		language   => defined $language ? $language : 'zh',
		name       => 'Chinese',
	};
}

# A suite detector which answers with the given detector results.
sub suite_detector {
	my ($lingua, $fastlang) = @_;

	return sub {
		my ( $text, $target, $cb ) = @_;
		$cb->({ lingua => $lingua, fastlang => $fastlang });
		return;
	};
}

sub llm_detector {
	my ($confidence, $error) = @_;

	return sub {
		my ( $text, $cb ) = @_;
		$cb->($confidence, $error);
		return;
	};
}

# Run a detection and return (reply, callback_count).
sub run_detect {
	my ($text, $target, $opts) = @_;

	my $reply;
	my $calls = 0;

	$Detect->detect_target($text, $target, $opts || {}, sub {
		$calls++;
		$reply = shift;
	});

	return ($reply, $calls);
}

# ---------------------------------------------------------------------------
# target_label()
# ---------------------------------------------------------------------------
is($Detect->target_label('zh-Hans'), '简体中文', 'label for zh-Hans');
is($Detect->target_label('zh-Hant'), '繁體中文', 'label for zh-Hant');
is($Detect->target_label('zh_CN'), '简体中文', 'zh_CN alias label');
is($Detect->target_label('zh-TW'), '繁體中文', 'zh-TW alias label');
is($Detect->target_label('en'), 'English', 'label for en');
is($Detect->target_label('en-US'), 'English', 'en-US alias label');
is($Detect->target_label('ja'), '日本語', 'label for ja');
is($Detect->target_label('ko'), '한국어', 'label for ko');
is($Detect->target_label('custom', '  文言  '), '文言', 'custom label is trimmed');
is($Detect->target_label('custom'), '', 'custom label without text');
is($Detect->target_label(undef), '', 'missing target label');
is($Detect->target_label('fr'), 'fr', 'unknown target label falls back to identifier');

# ---------------------------------------------------------------------------
# the optional LangID plugin suite (package fallback path)
# ---------------------------------------------------------------------------
{
	$INC{'Plugins/LangID/API.pm'} = 1;

	package Plugins::LangID::API;

	our @CALLS;

	sub available { 1 }

	sub detect_suite {
		my ( $class, $text, $target, $cb ) = @_;

		push @CALLS, { text => $text, target => $target };

		$cb->({
			lingua   => { confidence => 0.95, language => 'zh', name => 'Chinese' },
			fastlang => { confidence => 0.9,  language => 'zh', name => 'Chinese' },
		});

		return;
	}

	package main;

	my ($reply) = run_detect('你好世界', 'zh-Hans', {});
	is($reply->{needs_translation}, 0, 'plugin suite: already target');
	is($reply->{source}, 'suite', 'plugin suite: source suite');
	is(scalar @Plugins::LangID::API::CALLS, 1, 'plugin suite: detect_suite called');
	is($Plugins::LangID::API::CALLS[0]{target}, 'zh-Hans', 'plugin suite: canonical target');
	is($Detect->suite_detector, 'Plugins::LangID::API', 'plugin suite: package memoized');

	# simulate a host without the plugin for every later test
	delete $INC{'Plugins/LangID/API.pm'};
	$Detect->reset;
	is($Detect->suite_detector, undef, 'plugin suite: absent after reset');
}

# ---------------------------------------------------------------------------
# mode "always" and "llm"
# ---------------------------------------------------------------------------
{
	my $suiteCalls = 0;
	my $llmCalls   = 0;

	my $suite = sub {
		$suiteCalls++;
		$_[2]->({ lingua => detector(1), fastlang => detector(1) });
		return;
	};

	my $llm = sub {
		$llmCalls++;
		$_[1]->(1, undef);
		return;
	};

	my ($reply) = run_detect('anything', 'zh-Hans', {
		mode         => 'always',
		suite_detect => $suite,
		llm_detect   => $llm,
	});
	is($reply->{needs_translation}, 1, 'always: forces translation');
	is($reply->{source}, 'forced', 'always: forced source');
	is($reply->{language}, 'zh-Hans', 'always: target reported');
	is($suiteCalls, 0, 'always: suite not called');
	is($llmCalls, 0, 'always: LLM not called');

	$suiteCalls = 0;
	$llmCalls   = 0;

	($reply) = run_detect('anything', 'ja', {
		mode         => 'llm',
		suite_detect => $suite,
		llm_detect   => $llm,
	});
	is($reply->{needs_translation}, 0, 'llm mode: confidence above threshold');
	is($reply->{source}, 'llm', 'llm mode: source llm');
	is($reply->{confidence}, 1, 'llm mode: confidence reported');
	is($suiteCalls, 0, 'llm mode: suite skipped');

	($reply) = run_detect('anything', 'ja', { mode => 'llm', llm_detect => llm_detector(0.2) });
	is($reply->{needs_translation}, 1, 'llm mode: confidence below threshold');

	($reply) = run_detect('anything', 'ja', { mode => 'llm', llm_detect => llm_detector(undef, 'timeout') });
	is($reply->{needs_translation}, 1, 'llm mode: LLM failure translates');
	is($reply->{source}, 'llm', 'llm mode: failure source');

	($reply) = run_detect('anything', 'ja', { mode => 'llm' });
	is($reply->{needs_translation}, 1, 'llm mode: no LLM translates');
	is($reply->{source}, 'llm', 'llm mode: no LLM source');
}

# ---------------------------------------------------------------------------
# auto: clear suite decisions (no LLM needed)
# ---------------------------------------------------------------------------
{
	my $llmCalls = 0;
	my $llm = sub {
		$llmCalls++;
		$_[1]->(0.5, undef);
		return;
	};

	my ($reply) = run_detect('你好世界', 'zh-Hans', {
		suite_detect => suite_detector(detector(0.95), detector(0.9)),
		llm_detect   => $llm,
	});
	is($reply->{needs_translation}, 0, 'auto: high score is already target');
	is($reply->{source}, 'suite', 'auto: high score source');
	is($reply->{language}, 'zh-Hans', 'auto: target reported');
	is($reply->{lingua_confidence}, 0.95, 'auto: lingua confidence reported');
	is($reply->{fastlang_confidence}, 0.9, 'auto: fastlang confidence reported');
	is($reply->{lingua_language}, 'zh', 'auto: lingua language reported');
	is($reply->{fastlang_language}, 'zh', 'auto: fastlang language reported');
	ok(defined $reply->{score}, 'auto: score reported');
	cmp_ok($reply->{score}, '>=', 0.9, 'auto: score is the weighted blend');
	is($llmCalls, 0, 'auto: high score does not call the LLM');

	($reply) = run_detect('hello world', 'zh-Hans', {
		suite_detect => suite_detector(detector(0.02), detector(0.05)),
		llm_detect   => $llm,
	});
	is($reply->{needs_translation}, 1, 'auto: low score translates');
	is($reply->{source}, 'suite', 'auto: low score source');
	is($llmCalls, 0, 'auto: low score does not call the LLM');
}

# ---------------------------------------------------------------------------
# auto: weighted blend
# ---------------------------------------------------------------------------
{
	my $suite = suite_detector(detector(1.0), detector(0.0));

	my ($reply) = run_detect('text', 'zh-Hans', {
		suite_detect    => $suite,
		lingua_weight   => 0.8,
		fastlang_weight => 0.2,
	});
	is($reply->{source}, 'suite', 'weights: score compared to the threshold');
	is($reply->{needs_translation}, 0, 'weights: lingua-heavy score above threshold');
	cmp_ok(abs($reply->{score} - 0.8), '<', 0.000001, 'weights: 0.8/0.2 blend is 0.8');

	($reply) = run_detect('text', 'zh-Hans', {
		suite_detect    => $suite,
		lingua_weight   => 0.2,
		fastlang_weight => 0.8,
	});
	is($reply->{needs_translation}, 1, 'weights: fastlang-heavy score below threshold');
	cmp_ok(abs($reply->{score} - 0.2), '<', 0.000001, 'weights: 0.2/0.8 blend is 0.2');

	# default weights are 0.5 / 0.5
	($reply) = run_detect('text', 'zh-Hans', {
		suite_detect => suite_detector(detector(0.6), detector(0.4)),
	});
	cmp_ok(abs($reply->{score} - 0.5), '<', 0.000001, 'weights: default weights are 0.5');
	is($reply->{needs_translation}, 0, 'weights: default blend equals the threshold');

	# only one detector defined
	($reply) = run_detect('text', 'zh-Hans', {
		suite_detect => suite_detector(detector(0.95), undef),
	});
	is($reply->{score}, 0.95, 'weights: only lingua confidence used');
	is($reply->{needs_translation}, 0, 'weights: only lingua decides');

	($reply) = run_detect('text', 'zh-Hans', {
		suite_detect => suite_detector(undef, detector(0.5)),
	});
	is($reply->{score}, 0.5, 'weights: only fastlang confidence used');

	# both detectors defined but both weights zero: no score
	($reply) = run_detect('text', 'zh-Hans', {
		suite_detect    => suite_detector(detector(0.95), detector(0.95)),
		lingua_weight   => 0,
		fastlang_weight => 0,
	});
	is($reply->{score}, undef, 'weights: zero weights give no score');
	is($reply->{needs_translation}, 1, 'weights: no score and no LLM translates');

	# invalid weights fall back to 0.5
	($reply) = run_detect('text', 'zh-Hans', {
		suite_detect    => suite_detector(detector(0.0), detector(1.0)),
		lingua_weight   => 'nonsense',
		fastlang_weight => '0.5',
	});
	is($reply->{source}, 'suite', 'weights: invalid weight falls back');
	ok(defined $reply->{score}, 'weights: invalid weight still produces a score');
}

# ---------------------------------------------------------------------------
# auto: ambiguous band - LLM fallback
# ---------------------------------------------------------------------------
{
	my $amb = suite_detector(detector(0.55), detector(0.55));
	my $llmCalls = 0;
	my $llm = sub {
		$llmCalls++;
		$_[1]->(0.9, undef);
		return;
	};

	my ($reply) = run_detect('text', 'zh-Hans', {
		suite_detect => $amb,
		llm_detect   => $llm,
	});
	is($reply->{needs_translation}, 0, 'ambiguous: LLM confidence decides (already target)');
	is($reply->{source}, 'suite+llm', 'ambiguous: source suite+llm');
	is($reply->{confidence}, 0.9, 'ambiguous: LLM confidence reported');
	cmp_ok(abs($reply->{score} - 0.55), '<', 0.000001, 'ambiguous: suite score kept');
	is($llmCalls, 1, 'ambiguous: LLM called once');

	($reply) = run_detect('text', 'zh-Hans', {
		suite_detect => $amb,
		llm_detect   => llm_detector(0.2),
	});
	is($reply->{needs_translation}, 1, 'ambiguous: low LLM confidence translates');
	is($reply->{source}, 'suite+llm', 'ambiguous: low confidence source');

	($reply) = run_detect('text', 'zh-Hans', {
		suite_detect => suite_detector(detector(0.4), detector(0.4)),
		llm_detect   => llm_detector(undef, 'timeout'),
	});
	is($reply->{needs_translation}, 1, 'ambiguous: LLM failure uses score below threshold');
	is($reply->{source}, 'suite', 'ambiguous: LLM failure source suite');

	# LLM failure with a score above the threshold
	($reply) = run_detect('text', 'zh-Hans', {
		suite_detect => suite_detector(detector(0.8), detector(0.8)),
		llm_detect   => llm_detector(undef, 'timeout'),
	});
	is($reply->{needs_translation}, 0, 'ambiguous: LLM failure keeps a high score');
	is($reply->{source}, 'suite', 'ambiguous: LLM failure high score source');
}

# ---------------------------------------------------------------------------
# auto: threshold handling
# ---------------------------------------------------------------------------
{
	my $amb = suite_detector(detector(0.55), detector(0.55));

	my ($reply) = run_detect('text', 'zh-Hans', { suite_detect => $amb, threshold => 0.6 });
	is($reply->{needs_translation}, 1, 'threshold: score below cut-off translates');

	($reply) = run_detect('text', 'zh-Hans', { suite_detect => $amb, threshold => 0.5 });
	is($reply->{needs_translation}, 0, 'threshold: score above cut-off is target');

	($reply) = run_detect('text', 'zh-Hans', {
		suite_detect => $amb,
		llm_detect   => llm_detector(0.55),
		threshold    => 0.6,
	});
	is($reply->{needs_translation}, 1, 'threshold: LLM confidence below cut-off translates');

	($reply) = run_detect('text', 'zh-Hans', {
		suite_detect => $amb,
		llm_detect   => llm_detector(0.55),
		threshold    => 0.5,
	});
	is($reply->{needs_translation}, 0, 'threshold: LLM confidence above cut-off is target');
}

# ---------------------------------------------------------------------------
# auto: suite errors, missing suite, no score
# ---------------------------------------------------------------------------
{
	my ($reply) = run_detect('text', 'zh-Hans', {
		suite_detect => sub {
			$_[2]->({ error => 'suite-failed' });
			return;
		},
		llm_detect => llm_detector(0.9),
	});
	is($reply->{needs_translation}, 0, 'suite error: LLM decides');
	is($reply->{source}, 'llm', 'suite error: source llm');
	is($reply->{score}, undef, 'suite error: no score');

	($reply) = run_detect('text', 'zh-Hans', {
		suite_detect => sub {
			die "detector exploded\n";
		},
		llm_detect => llm_detector(0.9),
	});
	is($reply->{needs_translation}, 0, 'dying suite: LLM decides');
	is($reply->{source}, 'llm', 'dying suite: source llm');

	($reply) = run_detect('text', 'zh-Hans', {
		suite_detect => sub {
			die "detector exploded\n";
		},
	});
	is($reply->{needs_translation}, 1, 'dying suite: no LLM translates');
	is($reply->{source}, 'llm', 'dying suite: no LLM source');

	# no injected suite and no plugin: LLM fallback
	($reply) = run_detect('text', 'zh-Hans', { llm_detect => llm_detector(0.9) });
	is($reply->{needs_translation}, 0, 'no suite: LLM decides');
	is($reply->{source}, 'llm', 'no suite: source llm');
	is($reply->{score}, undef, 'no suite: no score');

	($reply) = run_detect('text', 'zh-Hans', {});
	is($reply->{needs_translation}, 1, 'no suite, no LLM: translates');

	# a suite detector which never calls back and never returns
	my $never = sub { return; };
	my ($silentReply, $silentCalls) = run_detect('text', 'zh-Hans', { suite_detect => $never });
	is($silentReply, undef, 'silent suite: callback not invoked');
	is($silentCalls, 0, 'silent suite: caller not called');
}

# ---------------------------------------------------------------------------
# auto: callback and synchronous-return handling
# ---------------------------------------------------------------------------
{
	my $suite = sub {
		$_[2]->({ lingua => detector(0.95), fastlang => detector(0.95) });
		$_[2]->({ lingua => detector(0.0), fastlang => detector(0.0) });
		return;
	};

	my ($reply, $calls) = run_detect('text', 'zh-Hans', { suite_detect => $suite });
	is($calls, 1, 'suite answering twice: callback invoked once');
	is($reply->{needs_translation}, 0, 'suite answering twice: first answer wins');

	# suite detector answering synchronously by returning a hash
	my $sync = sub {
		return { lingua => detector(0.95), fastlang => detector(0.95) };
	};
	($reply) = run_detect('text', 'zh-Hans', { suite_detect => $sync });
	is($reply->{needs_translation}, 0, 'synchronous suite return accepted');
	is($reply->{source}, 'suite', 'synchronous suite return: source');

	# synchronous LLM return
	my $syncLlm = sub {
		return { confidence => 0.9 };
	};
	($reply) = run_detect('text', 'zh-Hans', {
		suite_detect => suite_detector(detector(0.55), detector(0.55)),
		llm_detect   => $syncLlm,
	});
	is($reply->{needs_translation}, 0, 'synchronous LLM return accepted');
	is($reply->{source}, 'suite+llm', 'synchronous LLM return: source');
}

# ---------------------------------------------------------------------------
# target canonicalization and detector language metadata
# ---------------------------------------------------------------------------
{
	my $seen;
	my $suite = sub {
		my ( $text, $target, $cb ) = @_;
		$seen = $target;
		$cb->({
			lingua   => { confidence => 0.95, language => 'Chinese', name => 'Chinese' },
			fastlang => { confidence => 0.9,  language => 'zh',      name => 'Chinese' },
		});
		return;
	};

	my ($reply) = run_detect('text', 'zh_CN', { suite_detect => $suite });
	is($seen, 'zh-Hans', 'canonicalization: zh_CN becomes zh-Hans for the suite');
	is($reply->{language}, 'zh-Hans', 'canonicalization: reply language');
	is($reply->{lingua_language}, 'Chinese', 'language metadata: lingua');
	is($reply->{fastlang_language}, 'zh', 'language metadata: fastlang');

	($reply) = run_detect('text', 'en-US', { suite_detect => $suite });
	is($seen, 'en', 'canonicalization: en-US becomes en');

	($reply) = run_detect('text', 'custom', { suite_detect => $suite });
	is($seen, 'custom', 'canonicalization: custom stays custom');
}

# ---------------------------------------------------------------------------
# plain function call style also works
# ---------------------------------------------------------------------------
{
	my $reply;
	Plugins::MusicArtistInfo::Lyrics::Translate::Detect::detect_target('text', 'zh-Hans', {
		suite_detect => suite_detector(detector(0.95), detector(0.95)),
	}, sub {
		$reply = shift;
	});
	is($reply->{needs_translation}, 0, 'plain function detect_target');
	is(Plugins::MusicArtistInfo::Lyrics::Translate::Detect::target_label('ja'), '日本語',
		'plain function target_label');
}

done_testing();
