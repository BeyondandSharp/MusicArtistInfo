Music And Artist Information plugin for the Squeezebox ecosystem
====

This plugin for Logitech Media Server and the Squeezebox ecosystem provides additional information for your music collection: biographies, album reviews, credits, related artists etc.

The information presented by this plugin are sourced from:
* [Wikipedia](https://wikipedia.org)
* [Last.fm](https://last.fm)
* [Discogs](https://discogs.com)
* [MusicBrainz](https://musicbrainz.org)

## Local text files

Local lyrics (`.lrc`/`.txt`) and text documents (`.txt`, `.nfo`, `.md`, `.html`) are decoded automatically. UTF-8 (with or without BOM), UTF-16/UTF-32 with BOM, and common legacy encodings are supported; invalid or ambiguous input falls back to a best-effort Windows-1252/ISO-8859-1 decode. Files written by the plugin remain UTF-8 without a BOM.
