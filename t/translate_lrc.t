#!/usr/bin/perl

use strict;
use utf8;

use Test::More;

use Plugins::MusicArtistInfo::Lyrics::Translate::LRC qw(
	normalize_newlines
	first_nonempty_line
	count_timestamps
	strip_inline_angle_time
	build_detect_text
	split_prefix
	parse_lrc
	is_pure_punctuation
	unique_lines
	clean_translation
	parse_llm_json
	norm_key
	match_translations
	rebuild_lrc
);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

my $MARKER = '[re:Deepseek翻译]';
my $KARAOKE =
	'[00:08.41]<00:08.41>機<00:08.83>械<00:09.44>の<00:09.79>花<00:10.87>園'
	. '<00:11.54>ま<00:11.85>で<00:12.26>';

# ---------------------------------------------------------------------------
# module loads / exports
# ---------------------------------------------------------------------------

can_ok('Plugins::MusicArtistInfo::Lyrics::Translate::LRC', qw(
	normalize_newlines first_nonempty_line count_timestamps
	strip_inline_angle_time build_detect_text split_prefix parse_lrc
	is_pure_punctuation unique_lines clean_translation parse_llm_json
	norm_key match_translations rebuild_lrc
));
ok(defined &rebuild_lrc, 'functions imported into the test package');

# ---------------------------------------------------------------------------
# normalize_newlines / first_nonempty_line
# ---------------------------------------------------------------------------

is_deeply([normalize_newlines("a\r\nb\r\n")], ["a\nb\n", "\r\n", 1],
	'CRLF normalized, trailing newline kept');
is_deeply([normalize_newlines("a\rb")], ["a\nb", "\r", 0],
	'lone CR normalized');
is_deeply([normalize_newlines("a\nb")], ["a\nb", "\n", 0],
	'plain LF untouched');
is_deeply([normalize_newlines("a\r\nb\rc")], ["a\nb\nc", "\r\n", 0],
	'mixed line ends use CRLF as dominant EOL');
is_deeply([normalize_newlines('')], ['', "\n", 0], 'empty text');

is(first_nonempty_line("\n\n  hi \nbye"), 'hi', 'first non-empty line trimmed');
is(first_nonempty_line("\n \n"), '', 'all blank lines -> empty string');
is(first_nonempty_line("\r\n  x\r\n"), 'x', 'CRLF line is trimmed of CR');

# ---------------------------------------------------------------------------
# count_timestamps: [00:00.00] exclusion, repeated count, digit shapes
# ---------------------------------------------------------------------------

is_deeply(
	[count_timestamps("[00:00.00]a\n[00:01.00]b\n[00:01.00]c\n[00:02.00]d")],
	[3, 1],
	'[00:00.00] is not counted; duplicate timestamps reported',
);
is_deeply([count_timestamps('[00:00.00]title only')], [0, 0],
	'only the title timestamp -> zero counted');
is_deeply([count_timestamps("[0:01]a\n[100:02.30]b\n[00:03:12]c")], [3, 0],
	'1-3 minute digits and optional . or : fraction accepted');
is_deeply([count_timestamps('[00:01.00]a')], [1, 0], 'single timestamp');
is_deeply([count_timestamps('no timestamps here')], [0, 0], 'no timestamps');

# ---------------------------------------------------------------------------
# strip_inline_angle_time / plain angle bracket survival
# ---------------------------------------------------------------------------

is(strip_inline_angle_time('<1:02.3>ab'), 'ab', 'short minute + . fraction stripped');
is(strip_inline_angle_time('<100:02.30>ab'), 'ab', '3-digit minutes stripped');
is(strip_inline_angle_time('<00:02>ab'), 'ab', 'fractionless karaoke stamp stripped');
is(strip_inline_angle_time('<00:02:30>ab'), 'ab', 'colon fraction stripped');
is(strip_inline_angle_time('機械の花園まで'), '機械の花園まで', 'plain text untouched');

foreach my $plain ('<Chorus> hello', 'I <3 you', '[00:01.00]<Chorus>Song', 'a<b>c') {
	like(strip_inline_angle_time($plain), qr/</, "plain angle text survives: $plain");
}

# ---------------------------------------------------------------------------
# build_detect_text
# ---------------------------------------------------------------------------

is(build_detect_text("[00:00.00]Hello\n[00:01.00]World ] x\n\n|tail"),
	'Hello,World ] x,|tail',
	'detect text: per-line [] removal, blank lines dropped, comma joined');
is(build_detect_text($KARAOKE), '機械の花園まで',
	'detect text strips per-character karaoke timestamps');
is(build_detect_text("<Chorus> hello"), '<Chorus> hello',
	'plain angle text is not stripped from detect text');

# ---------------------------------------------------------------------------
# split_prefix
# ---------------------------------------------------------------------------

is_deeply([split_prefix('[00:01.00][00:05.00]Song  text')],
	['[00:01.00][00:05.00]', 'Song text'],
	'all consecutive leading [] groups form the prefix; whitespace collapsed');
is_deeply([split_prefix('[ar:Some Artist]')], ['[ar:Some Artist]', ''],
	'metadata line has empty text');
is_deeply([split_prefix('[00:01.00]Hello ] world')],
	['[00:01.00]', 'Hello ] world'],
	']] inside lyrics does not truncate the text');
is_deeply([split_prefix('plain   line')], ['', 'plain line'],
	'no prefix; whitespace collapsed');
is_deeply([split_prefix('[00:08.41]<00:08.41>機<00:08.83>械')],
	['[00:08.41]', '機械'],
	'karaoke timestamps stripped from the body but not the prefix');

# ---------------------------------------------------------------------------
# parse_lrc
# ---------------------------------------------------------------------------

my $parsed_meta = parse_lrc("[ar:Artist]\n\n[00:01.00]line\n[00:02.00]   \n");
is_deeply($parsed_meta->{raw_lines},
	['[ar:Artist]', '[00:01.00]line', '[00:02.00]   '],
	'raw lines kept verbatim (trailing whitespace preserved), blank line dropped');
is_deeply($parsed_meta->{prefixes},
	['[ar:Artist]', '[00:01.00]', '[00:02.00]'],
	'prefixes parsed');
is_deeply($parsed_meta->{texts}, ['', 'line', ''],
	'metadata and whitespace-only bodies have empty text');
is($parsed_meta->{eol}, "\n", 'LF eol detected');
ok($parsed_meta->{trailing_newline}, 'trailing newline detected');

my $parsed_crlf = parse_lrc("[00:01.00]a\r\n[00:02.00]b\r\n");
is($parsed_crlf->{eol}, "\r\n", 'CRLF eol detected');
is_deeply($parsed_crlf->{texts}, ['a', 'b'], 'CRLF texts parsed');

my $parsed_karaoke = parse_lrc($KARAOKE);
is($parsed_karaoke->{raw_lines}[0], $KARAOKE, 'karaoke raw line kept verbatim');
is($parsed_karaoke->{prefixes}[0], '[00:08.41]', 'karaoke prefix parsed');
is($parsed_karaoke->{texts}[0], '機械の花園まで', 'karaoke body without timestamps');

# ---------------------------------------------------------------------------
# is_pure_punctuation / unique_lines
# ---------------------------------------------------------------------------

ok(is_pure_punctuation('！？…'), 'CJK punctuation is pure punctuation');
ok(!is_pure_punctuation('♪'), 'music note (symbol, not punctuation) is kept');
ok(!is_pure_punctuation('a。'), 'mixed letters/punctuation is not pure');
ok(is_pure_punctuation(''), 'empty string counts as pure punctuation');
ok(!is_pure_punctuation('♪♪'), 'symbol-only run is not punctuation');

is_deeply(unique_lines(['a', 'b', 'a', '  ', '♪♪', 'c']),
	['a', 'b', '♪♪', 'c'],
	'dedupe keeps first-occurrence order, drops blanks and punctuation-only lines');
is_deeply(unique_lines(['！？', 'a', 'a']), ['a'],
	'punctuation-only line consumed from the seen-set but not emitted');
is_deeply(unique_lines([]), [], 'empty input -> empty list');
is_deeply(unique_lines(['同じ歌詞', '同じ歌詞']), ['同じ歌詞'],
	'identical lyric lines dedupe');

# ---------------------------------------------------------------------------
# clean_translation: the three prefixes, greedy behaviour
# ---------------------------------------------------------------------------

is(clean_translation('译文：你好'), '你好', 'fullwidth colon prefix stripped');
is(clean_translation('译文: 你好'), '你好', 'colon+space prefix stripped');
is(clean_translation('译文:你好'), '你好', 'plain colon prefix stripped');
is(clean_translation('  你好  '), '你好', 'plain text just trimmed');
is(clean_translation('译文：甲 译文：乙'), '乙', 'greedy: keep text after the last prefix');
is(clean_translation('译文：甲 译文: 乙'), '乙',
	'mixed prefix kinds still keep the last payload');
is(clean_translation(''), '', 'empty translation');
is(clean_translation(undef), '', 'undef translation');

# ---------------------------------------------------------------------------
# norm_key
# ---------------------------------------------------------------------------

is(norm_key('  hello   world  '), 'hello world', 'whitespace collapsed and trimmed');
is(norm_key(" a\t b\n c "), 'a b c', 'tabs/newlines collapsed');
is(norm_key('ＡＢＣ'), 'ABC', 'NFKC folds fullwidth latin to ASCII');
is(norm_key('①'), '1', 'NFKC folds enclosed digits');
is(norm_key(''), '', 'empty key');

# ---------------------------------------------------------------------------
# parse_llm_json: plain, fenced, prose, braces in strings, garbage
# ---------------------------------------------------------------------------

is_deeply(parse_llm_json('{"a": 1}'), { a => 1 }, 'plain JSON object');
is_deeply(parse_llm_json('```json' . "\n" . '{"a": 1}' . "\n" . '```'),
	{ a => 1 }, 'fenced JSON with language tag');
is_deeply(parse_llm_json('```' . "\n" . '{"a": "乙"}' . "\n" . '```'),
	{ a => '乙' }, 'fenced JSON without language tag');
is_deeply(parse_llm_json('好的，结果如下：{"a": "甲"} 希望有帮助'),
	{ a => '甲' }, 'JSON surrounded by prose is extracted');
is_deeply(parse_llm_json('前缀 {"a": "含 } 字符"} 后缀'),
	{ a => '含 } 字符' },
	'balanced-brace extraction is string/escape aware');
is_deeply(parse_llm_json('{"a": {"b": 1}}'), { a => { b => 1 } },
	'nested objects decode');
is_deeply(parse_llm_json('{}'), {}, 'empty object decodes');
is_deeply(parse_llm_json('["甲", "乙"]'), ['甲', '乙'],
	'plain JSON array decodes (used for positional matching)');
is(parse_llm_json('完全不是 json'), undef, 'garbage -> undef');
is(parse_llm_json('abc{def'), undef, 'unterminated brace -> undef');
is(parse_llm_json(''), undef, 'empty reply -> undef');
is(parse_llm_json('   '), undef, 'whitespace reply -> undef');

# ---------------------------------------------------------------------------
# match_translations
# ---------------------------------------------------------------------------

is_deeply(match_translations(['hello', 'world'], { hello => '你好', world => '世界' }),
	{ hello => '你好', world => '世界' }, 'exact key match');
is_deeply(match_translations(['hello  world'], { 'hello world' => '你好世界' }),
	{ 'hello  world' => '你好世界' },
	'NFKC/whitespace-normalized fuzzy match');
is_deeply(match_translations(['ＡＢＣ'], { ABC => '甲乙丙' }),
	{ 'ＡＢＣ' => '甲乙丙' }, 'fullwidth line matched against ASCII key');
is_deeply(match_translations(['Hello'], { HELLO => '你好' }),
	{ Hello => '你好' }, 'case-insensitive fallback match');
is_deeply(match_translations(['a b'], { 'a b' => '精确', 'a  b' => '模糊' }),
	{ 'a b' => '精确' }, 'exact key wins over normalized key');
is_deeply(match_translations(['a', 'b'], ['甲', '乙']),
	{ a => '甲', b => '乙' }, 'equal-length array payload matched positionally');
is_deeply(match_translations(['a', 'b'], ['甲']),
	{ a => undef, b => undef }, 'wrong-length array payload is ignored');
is_deeply(match_translations(['a', 'b'], { a => '甲' }),
	{ a => '甲', b => undef }, 'missing key stays undef');
is_deeply(match_translations(['a'], undef), { a => undef }, 'undef payload');
is_deeply(match_translations(['a'], 'junk'), { a => undef }, 'non-collection payload ignored');
is_deeply(match_translations(['same', 'same'], { same => '同' }),
	{ same => '同' }, 'duplicate input lines collapse into one key');
is_deeply(match_translations([], { a => '甲' }), {}, 'empty line list');

# LLM reply -> parse -> match, the way the caller composes them.
my $parsed_reply = parse_llm_json('```json' . "\n" . '{"a": "甲"}' . "\n" . '```');
is_deeply(match_translations(['a', 'b'], $parsed_reply), { a => '甲', b => undef },
	'fenced reply parses then matches');

# ---------------------------------------------------------------------------
# rebuild_lrc: marker + verbatim original + translated block
# ---------------------------------------------------------------------------

my $parsed = parse_lrc("[ar:Artist]\n[00:01.00]Hello   world\n[00:02.00]Bye\n");
my ($body, $stats) = rebuild_lrc(
	$parsed,
	{ 'Hello world' => '你好世界', Bye => '再见' },
	marker => '[M]',
);
is($body, "[M]\n[ar:Artist]\n[00:01.00]Hello   world\n[00:02.00]Bye\n"
	. "[00:01.00]你好世界\n[00:02.00]再见\n",
	'exact rebuild: marker + verbatim original block + translated block');
is($stats->{translated}, 2, 'stats translated counts non-empty translations');
is($stats->{missing}, 0, 'stats missing');
is($stats->{dropped}, 0, 'stats dropped');
like($body, qr/^\[M\]\n\[ar:Artist\]/, 'metadata line only in the original block');
unlike($body, qr/\[ar:Artist\]你好/, 'metadata line not duplicated in translated block');

my ($marked_body) = rebuild_lrc($parsed, { 'Hello world' => '你好世界' }, marker => $MARKER);
like($marked_body, qr/^\[re:Deepseek翻译\]\n/, 'default marker text is emitted verbatim');

my ($unmarked_body) = rebuild_lrc(
	$parsed,
	{ 'Hello world' => '你好世界', Bye => '再见' },
	marker => '',
);
is($unmarked_body, "[ar:Artist]\n[00:01.00]Hello   world\n[00:02.00]Bye\n"
	. "[00:01.00]你好世界\n[00:02.00]再见\n",
	'no marker line when the marker is empty');
unlike($unmarked_body, qr/^\[M\]/, 'no marker line is prepended');

# multiline: drop (default) and space
my $parsed_two = parse_lrc("[00:01.00]a\n[00:02.00]b\n");
my ($drop_body, $drop_stats) = rebuild_lrc($parsed_two,
	{ a => "甲\n乙", b => '丙' }, marker => 'M');
is($drop_stats->{dropped}, 1, 'multiline translation dropped by default');
unlike($drop_body, qr/甲/, 'dropped line absent from translated block');
like($drop_body, qr/\[00:02\.00\]丙/, 'other lines still emitted');

my ($space_body, $space_stats) = rebuild_lrc($parsed_two,
	{ a => "甲\n乙", b => '丙' }, marker => 'M', multiline => 'space');
is($space_stats->{dropped}, 0, 'multiline=space keeps the line');
like($space_body, qr/\[00:01\.00\]甲 乙/, 'newline collapsed into a single space');

# failed_line: original (default) and omit
my ($orig_body, $orig_stats) = rebuild_lrc($parsed_two,
	{ a => '甲', b => undef }, marker => 'M');
is($orig_stats->{missing}, 1, 'missing translation counted');
my @orig_lines = split /\n/, $orig_body;
is_deeply([@orig_lines[3 .. 4]], ['[00:01.00]甲', '[00:02.00]b'],
	'failed_line=original repeats the original line in the translated block');

my ($omit_body, $omit_stats) = rebuild_lrc($parsed_two,
	{ a => '甲', b => undef }, marker => 'M', failed_line => 'omit');
is($omit_stats->{missing}, 1, 'omit still counts the missing line');
my @omit_lines = split /\n/, $omit_body;
is_deeply([@omit_lines[3 .. 3]], ['[00:01.00]甲'],
	'failed_line=omit leaves the line out of the translated block');

# empty translated string is dropped, not emitted
my (undef, $empty_stats) = rebuild_lrc($parsed_two,
	{ a => '甲', b => '' }, marker => 'M');
is($empty_stats->{dropped}, 1, 'empty translation counted as dropped');

# all lines failed: nothing translated; failed_line still decides the block
my $parsed_one = parse_lrc("[00:01.00]a\n");
my ($all_failed_body, $all_failed_stats) = rebuild_lrc($parsed_one,
	{ a => undef }, marker => 'M');
is($all_failed_stats->{translated}, 0, 'all lines failed -> translated 0');
is($all_failed_body, "M\n[00:01.00]a\n[00:01.00]a\n",
	'failed_line=original repeats the original even when everything failed');

my ($all_omitted_body, $all_omitted_stats) = rebuild_lrc($parsed_one,
	{ a => undef }, marker => 'M', failed_line => 'omit');
is($all_omitted_stats->{translated}, 0, 'all lines omitted -> translated 0');
is($all_omitted_body, "M\n[00:01.00]a\n\n",
	'reference layout when the translated block is empty');

# EOL + trailing newline preservation
my $parsed_crlf_full = parse_lrc("[00:01.00]a\r\n[00:02.00]b\r\n");
my ($crlf_body, $crlf_stats) = rebuild_lrc($parsed_crlf_full,
	{ a => '甲', b => '乙' }, marker => 'M');
is($crlf_body, "M\r\n[00:01.00]a\r\n[00:02.00]b\r\n[00:01.00]甲\r\n[00:02.00]乙\r\n",
	'CRLF file rebuilt with CRLF line endings everywhere');
is($crlf_stats->{translated}, 2, 'CRLF rebuild stats');
my $bare_lf = $crlf_body;
$bare_lf =~ s/\r\n//g;
unlike($bare_lf, qr/\n/, 'no bare LF left in a CRLF rebuild');

my $parsed_cr = parse_lrc("[00:01.00]a\r[00:02.00]b\r");
my ($cr_body) = rebuild_lrc($parsed_cr, { a => '甲', b => '乙' }, marker => 'M');
like($cr_body, qr/^M\r\[00:01\.00\]a\r/, 'lone-CR file rebuilt with CR line endings');
unlike($cr_body, qr/\n/, 'no LF in a CR rebuild');

my $parsed_no_eol = parse_lrc('[00:01.00]a');
my ($no_eol_body) = rebuild_lrc($parsed_no_eol, { a => '甲' }, marker => 'M');
is($no_eol_body, "M\n[00:01.00]a\n[00:01.00]甲",
	'file without trailing newline stays without one');

# karaoke: original block verbatim, translated block without <> tags
my ($karaoke_body) = rebuild_lrc(
	parse_lrc($KARAOKE),
	{ '機械の花園まで' => '直到机械的花园' },
	marker => '[M]',
);
my @karaoke_lines = split /\n/, $karaoke_body;
is($karaoke_lines[0], '[M]', 'karaoke rebuild marker line');
is($karaoke_lines[1], $KARAOKE, 'karaoke original block kept verbatim');
is($karaoke_lines[2], '[00:08.41]直到机械的花园',
	'karaoke translated line has the prefix but no per-character timestamps');

# duplicate lyric lines: translated once, emitted for every timestamp
my $parsed_dupe = parse_lrc("[00:01.00]same\n[00:09.00]same\n");
is_deeply(unique_lines($parsed_dupe->{texts}), ['same'],
	'duplicate lyric lines are deduped for translation');
my ($dupe_body, $dupe_stats) = rebuild_lrc($parsed_dupe, { same => '同' }, marker => 'M');
my @dupe_lines = split /\n/, $dupe_body;
is_deeply([@dupe_lines[3 .. 4]], ['[00:01.00]同', '[00:09.00]同'],
	'each timed occurrence gets its own translated line');
is($dupe_stats->{translated}, 1,
	'stats translated counts unique translation values, not emitted lines');

# empty translations hash
my ($none_body, $none_stats) = rebuild_lrc($parsed_one, {}, marker => 'M');
is($none_stats->{translated}, 0, 'empty translations hash -> translated 0');
is($none_stats->{missing}, 1, 'empty translations hash -> every line missing');

# full mini pipeline: detect text, dedupe, rebuild with the reference marker
my $pipeline_input = "[00:00.00]Title - Artist\n[00:01.00]Hello\n[00:02.00]Hello\n";
my $pipeline_parsed = parse_lrc($pipeline_input);
my $pipeline_unique = unique_lines($pipeline_parsed->{texts});
is_deeply($pipeline_unique, ['Title - Artist', 'Hello'], 'pipeline dedupe');
my %pipeline_translations = map { $_ => "译:$_" } @$pipeline_unique;
my ($pipeline_body, $pipeline_stats) = rebuild_lrc(
	$pipeline_parsed, \%pipeline_translations, marker => $MARKER);
like($pipeline_body, qr/^\[re:Deepseek翻译\]\n/, 'pipeline marker line');
like($pipeline_body, qr/\[00:02\.00\]Hello/, 'pipeline original block');
like($pipeline_body, qr/\[00:02\.00\]译:Hello/, 'pipeline translated block');
is($pipeline_stats->{translated}, 2, 'pipeline stats');
is(build_detect_text($pipeline_input), 'Title - Artist,Hello,Hello',
	'pipeline detect text keeps duplicate lines (dedupe happens later)');

done_testing();
