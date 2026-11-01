Music And Artist Information plugin for the Squeezebox ecosystem
====

This plugin for Logitech Media Server and the Squeezebox ecosystem provides additional information for your music collection: biographies, album reviews, credits, related artists etc.

The information presented by this plugin are sourced from:
* [Wikipedia](https://wikipedia.org)
* [Last.fm](https://last.fm)
* [Discogs](https://discogs.com)
* [MusicBrainz](https://musicbrainz.org)

## Lyrics

### Save lyrics next to the song file

In *Settings > Plugins > Music and Artist Information* you can enable
**Save lyrics next to songs**. Downloaded lyrics are then written as an LRC
file next to the local audio file. Existing files are left alone unless you
enable **Overwrite existing lyrics files**.

The lyrics **filename format** uses the Lyrion Music Server title format. The
default `FILE` keeps the song's filename (`Song.lrc`). Examples:

| Format | Result |
| --- | --- |
| `FILE` | `Song.lrc` |
| `ARTIST - TITLE` | `Artist - Title.lrc` |
| `TRACKNUM - TITLE` | `01 - Title.lrc` |

Available tokens include `ARTIST`, `TITLE`, `ALBUM`, `TRACKNUM`, `DISC`,
`YEAR`, `GENRE`, `FILE` and `EXT`. The resulting filename is sanitized for
the operating system of the server; the format only controls the basename,
lyrics are always stored in the song's folder.

Files written using a custom format are also picked up by the plugin on
subsequent lookups.

### Choose lyrics in the web UI

The lyrics view of the LMS web UI contains a **Choose lyrics** button. It
opens a search window showing all candidates found by the built-in providers
and by custom Perl lyric scripts. You can edit the title and artist used for the
search, preview the candidates and apply the one you like. The selected lyrics
are shown immediately, remembered for that track, and cached/saved according
to the settings above.

Candidate searches are bounded to about ten seconds; slow online sources are
skipped so the dialog does not remain in the "Searching" state forever.

The same chooser is available in **Material Skin** without a separate
dialog. Open the now-playing settings menu (the gear at the top right of the
lyrics) and choose **Choose lyrics**, or use the lyrics icon in the queue
toolbar next to the actions button. The queue panel then switches to a lyrics
search / candidate list. Results appear as soon as each source returns, with a
progress bar and a cancel button. The search is allowed to run for up to 30
seconds; selecting a candidate happens in the queue panel, and Material
Skin's lyrics refresh immediately afterward.

This is controlled by **Add lyrics chooser to Material Skin's now-playing
settings and queue panel** and requires Material Skin. The plugin manages a
marked loader block in Material Skin's `custom.js`; existing user code is
preserved and the block is removed when the setting is disabled or the plugin
is shut down.

### Translate lyrics

MusicArtistInfo can translate lyrics with an OpenAI-compatible LLM and write
bilingual LRC files (original block plus translated block).  Enable it in
**Settings > Plugins > Music and Artist Information > Lyrics options >
Translation**.

- **API key**: stored in a separate file with permissions `0600` below the LMS
  preferences folder (`musicartistinfo/lyricsTranslate.key`).  The key is never
  sent back to the browser after saving; leave the field empty to keep the
  current key, or tick the clear box to remove it.  The `DEEPSEEK_API_KEY`
  environment variable is used as a read-only fallback.
- **Endpoint**: base URL, chat-completions path, model, authentication header
  and prefix, extra headers and the JSON response format are configurable.
  Defaults target DeepSeek (`https://api.deepseek.com`, `deepseek-flash`).
- **Prompts** default to English and support `{{target}}`, `{{json}}`,
  `{{source}}`, `{{count}}`, `{{path}}`, `{{line}}`, `{{index}}` and
  `{{total}}` placeholders.  The line-by-line prompt is the batch prompt plus
  a "The following is for context reference: `{{source}}`" sentence.
- **When it runs**: translation is queued when a local `.lrc` file is loaded,
  after lyrics are saved next to the song, and when a candidate is confirmed
  in the lyrics chooser.  The lyrics page and the Material Skin now-playing
  menu also have a **Translate lyrics** button.  Lyrics that were never written
  to a local LRC file (online lyrics with saving disabled) are not translated.
- **Result**: the file is rewritten as the verbatim original block followed by
  the translated block.  No translation marker line is written.  The original
  file is backed up as `<file>.orig` by default.  Bilingual files are detected
  by their repeated timestamps; files translated by older versions which start
  with `[re:Deepseek翻译]` are still recognised and skipped.
- **Language detection**: the optional `LangID` plugin from
  `/root/lms-plugin-LangID` provides two detectors for the target language:
  **lingua** (lingua-rs) and **fastlang** (fastText `lid.176.ftz`).  Their
  confidence values are mixed with the configurable **Lingua weight** and
  **Fastlang weight** (0-1 each, default 0.5/0.5); a mixed result between 0.1
  and 0.9 falls back to the LLM detection request, and a missing/unsupported
  detector falls back to the LLM as well.  The old script-rule detection was
  removed.
- **Queue**: translations run serially in the background; failed jobs are
  retried a limited number of times and are not re-queued while cooling down.

The target language is configurable and defaults to Simplified Chinese;
Chinese/Hant still share the same detection rules.  Changing the target on an
already translated file requires removing the generated translation block
first (a v1 limitation).

### Custom Perl lyrics scripts

The plugin can load custom lyrics sources from ordinary Perl scripts.  Enable
**Custom Perl lyrics scripts** in the plugin settings and point the scripts
folder to a directory containing `*.pl` files.  Scripts are loaded inside the
LMS process; **Node.js is not required**.

See [script-examples/README.md](script-examples/README.md) for the contract and
examples.  A script returns a coderef, or a hash with `name` and `getLyrics`:

```perl
return {
    name => 'My source',
    getLyrics => sub {
        my ($args, $cb) = @_;
        $cb->({ lyrics => "[00:01.00]First line\n", source => 'My source' });
    },
};
```

Scripts are tried before or after the built-in providers according to the
**Before/after built-in sources** setting, and are also included in the lyrics
chooser.  They run with the permissions of the LMS user, so only install
trusted scripts.  A script must use asynchronous callbacks and must not block
LMS.

## Local text files

Local lyrics (`.lrc`/`.txt`) and text documents (`.txt`, `.nfo`, `.md`, `.html`) are decoded automatically. UTF-8 (with or without BOM), UTF-16/UTF-32 with BOM, and common legacy encodings are supported; invalid or ambiguous input falls back to a best-effort Windows-1252/ISO-8859-1 decode. Files written by the plugin remain UTF-8 without a BOM.

## Foobar2000 title formatting and lyrics options

The optional **FB2KFormat** plugin provides a safe subset of the foobar2000
title-formatting language for save paths, filenames and custom search fields.
When it is installed and enabled, MusicArtistInfo's lyrics options expose a
**Use foobar2000 title formatting** switch; otherwise the existing Lyrion
Music Server filename format is used.

A dedicated **Lyrics options** page groups the automatic search, source order,
search filters/fields/processing, lyrics processing and save settings. It
supports save locations such as `$directory_path(%path%)`, UTF-8 BOM output,
and the example filename template:

```text
[$num(%discnumber%,1)-][%tracknumber%. ][%artist% - ]$meta(title,0)[ '('cover %origartist%')']
```
