# Uzume Plugin: Splits

A split timer for any game in Uzume: game time and real time, HUD widget, split lists per game with personal best and best segments, hotkeys and optional autosplit rules.

Status: **v0.1.0** (timer, HUD, panel, editor, text import and export, hotkeys, memory and Pokémon autosplit rules, `splits.pb` run event).

For Uzume with plugin API v1 (since Uzume 0.11, store since 0.20). Part of [Uzume](https://github.com/phabioo/uzume); plugin API: [`docs/guides/plugin-api.md`](https://github.com/phabioo/uzume/blob/main/docs/guides/plugin-api.md) there. Layout and design: [docs/architecture.md](docs/architecture.md). Plan: [docs/roadmap.md](docs/roadmap.md).

## Development

```
lua5.4 tools/bundle.lua           # writes plugin/main.lua from src/ (committed)
lua5.4 tools/bundle.lua --check   # fails when plugin/main.lua is stale
lua5.4 tests/run.lua              # tests against a fake fb with synthetic data
python3 -I tools/package.py       # builds dist/uzume.splits-<version>.fbplugin
```

The folder `plugin/` is what you install or link in Uzume's developer mode. Releases: run the **Release** workflow with a tag `vX.Y.Z` that equals the manifest version; it attaches the `.fbplugin` to a GitHub release.

Every PR description needs a `## Changelog` section (see `.github/pull_request_template.md`); CI checks it with `tools/changelog.py`, and releases build their notes from these sections.

License: GPL-3.0-or-later, see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md). Contributions under the [CLA](CLA.md).

Pokémon and Nintendo are trademarks of their owners. This project is not affiliated with them and contains no game content.
