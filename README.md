Music And Artist Information plugin for the Squeezebox ecosystem
====

This plugin for Logitech Media Server and the Squeezebox ecosystem provides additional information for your music collection: biographies, album reviews, credits, related artists etc.

The information presented by this plugin are sourced from:
* [Wikipedia](https://wikipedia.org)
* [Last.fm](https://last.fm)
* [Discogs](https://discogs.com)
* [MusicBrainz](https://musicbrainz.org)

## Custom lyrics scripts

Enable **Custom lyrics scripts** in the plugin settings and select a folder
containing `*.pl` files.  Scripts are loaded and executed inside the LMS
process; they do not need Node.js or any additional runtime.  They are tried
before the built-in lyrics providers.

A script returns a coderef, or a hash with `name` and `getLyrics`:

```perl
return {
    name => 'My source',
    getLyrics => sub {
        my ($args, $cb) = @_;
        $cb->({ lyrics => "[00:01.00]First line\n", source => 'My source' });
    },
};
```

Scripts must call `$cb` asynchronously and must not block LMS.  They run with
the permissions of the LMS user, so only install trusted scripts.  See
[script-examples/README.md](script-examples/README.md) for details and
examples.
