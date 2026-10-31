# Custom Perl lyrics scripts

Enable **Custom lyrics scripts** in the MusicArtistInfo settings and point the
script folder to a directory containing `*.pl` files.  Scripts are loaded and
executed inside the LMS process, before the built-in lyrics providers.  Only
install scripts you trust.

A script must return either a coderef, or a hash with a `name` and a
`getLyrics` coderef:

```perl
return {
    name => 'My lyrics source',
    getLyrics => sub {
        my ($args, $cb) = @_;

        # $args contains title, artist, album, duration, url, ...
        # Do asynchronous work and call $cb exactly once.
        $cb->({
            lyrics => "[00:01.00]First line\n[00:02.00]Second line\n",
            source => 'My lyrics source',
        });
    },
};
```

Call `$cb->()` when the source has no lyrics.  The provider tries the next
script, then the built-in providers.  Scripts must not block; use
`Plugins::MusicArtistInfo::Common->call` for HTTP requests or another
asynchronous mechanism.

See `static-demo.pl` and `lrclib.pl` for generic examples, and
`sources/netease.pl` / `sources/musixmatch.pl` for ports of the bundled
ESLyric sources.  Scripts run with the
permissions of the LMS user, so they can access the filesystem and network.
