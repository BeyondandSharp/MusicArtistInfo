# Converted lyric sources

These Perl scripts are ports of the two bundled ESLyric sources:

- `netease.pl` — NetEase Cloud Music (网易云音乐), based on Robotxm's
  `netease_ex.js` (GPL-3.0), which is based on ohyeah's original source.
- `musixmatch.pl` — Musixmatch, based on ohyeah's source.

They use only modules shipped with Lyrion Music Server and MAI's asynchronous
HTTP helper. Copy them to the **Custom Perl lyrics scripts** folder. The
scripts are trusted code and run inside LMS.

The ports use the public web APIs rather than the ESLyric JavaScript runtime.
NetEase uses the classic `/api/search/get` and `/api/song/lyric` endpoints;
Musixmatch uses the desktop API token/search/subtitle flow.

Source repositories:

- https://github.com/Robotxm/ESLyric-LyricsSource (GPL-3.0)
- https://github.com/xmcp/eslyric-scripts (Musixmatch)
