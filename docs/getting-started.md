# Getting started (planned)

Placeholder. Plugin API v1 ships with Uzume since 0.11, but this template has no runnable example yet. Until it does, follow the Uzume guide `docs/guides/plugin-api.md`.

## Planned layout of a plugin

```text
my-plugin/
  manifest.json   # id, version, api, permissions, games, entry (see manifest.example.jsonc, draft)
  main.lua        # entry point, Lua 5.4 in the Uzume sandbox
  i18n/           # UI strings: en.json (source), de.json (first translation)
  assets/         # own artwork only, never game content
```

## Open

- A runnable example with tests in this repository.

Until then, the Uzume repository documents the Lua API, the building blocks, the manifest, local install and Developer mode (`docs/guides/plugin-api.md`), and packaging and signing as `.fbplugin` (`docs/guides/plugin-publishing.md`). Interface description: Uzume `docs/architecture/12-plugins.md`.
