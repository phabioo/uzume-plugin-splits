# Roadmap

Status: v0.1.3 (API namespace `uz`, falls back to `fb` on older apps); v0.1.2 (actions that make no sense right now are disabled in the panel and run screen through the uz.ui `disabled` prop of Uzume 0.22, dropped automatically on older apps); v0.1.1 (badge rule through the soullink-core event `badges.changed`); v0.1.0 (timer on game time and real time, HUD widget, panel, split editor with import and export, hotkeys, memory and Pokémon autosplit rules, `splits.pb` run event with recap block). Builds on Uzume plugin API v1; see the [Uzume roadmap](https://github.com/phabioo/uzume/blob/main/docs/roadmap.md) and [`docs/guides/plugin-api.md`](https://github.com/phabioo/uzume/blob/main/docs/guides/plugin-api.md). Design and open points: [architecture.md](architecture.md).

## Done in 0.1.0

- Timer on frames (game time) and `uz.clock` (real time), manual pause, discontinuity handling.
- Split lists per game in `uz.store` with personal best and best segments (separately per timing method).
- HUD widget (time, split, delta to PB green/red, previous split with gold marker), panel tab, editor screen.
- Hotkeys: start/split, undo, skip, reset, pause, open editor.
- Autosplit rules: memory condition, location changed (soullink-core event), badge (soullink-core event `badges.changed`, since 0.1.1).
- Run event `splits.pb` and manifest `recap`.

## Next

- Verify against the live app (HUD layout, hotkeys, store sync) and tune the defaults.
- Optional start and reset rules (autostart on a memory condition).
- Compare against best segments ("sum of best" delta), per-split comparison choice.
- Share lists between people (export is text today).
