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
