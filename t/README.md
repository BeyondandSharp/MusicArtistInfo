# Tests

## Perl unit tests (no LMS required)

Run from the repository root:

```sh
prove -Ilib -It/lib t/filename.t t/sidecar.t t/chosen_cache.t t/candidates.t t/webui.t t/material_skin.t t/perl_scripts.t t/match.t t/processor.t t/search_settings.t t/translate_lrc.t t/translate_detect.t t/translate_llm.t t/translate_settings.t t/translator.t
```

These tests use the small LMS stubs in `t/lib`; they do not need a running
server or network access.  `t/material_skin.t` stubs
`Slim::Utils::PluginManager` and verifies that the Material Skin `custom.js`
loader is added and removed without touching user code.  `t/perl_scripts.t`
covers the custom Perl lyrics provider.  The `t/translate_*.t` tests cover the
LLM translation modules with injected HTTP senders and caches; they never call
a real API.

## FB2KFormat plugin test

The optional plugin in `/root/lms-plugin-fb2kFormat` has its own test:

```sh
prove -Ilib -It/lib t/format.t
```

## Live LMS test

`t/albums.t` is the upstream test which talks to a running LMS on
`http://localhost:9000`. It is not used by the unit tests above.
