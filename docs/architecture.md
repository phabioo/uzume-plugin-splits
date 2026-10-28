# Architecture

At a glance: Lua modules in `src/` are bundled into `plugin/main.lua`. A pure core (timer, model, text format, rules) is wired to the Uzume API by `controller.lua`; `views.lua` builds the declarative UI trees. Everything is keyed by game code; nothing from a game is shipped.

## Layout

- `src/`: modules, listed in `src/modules.txt`. `tools/bundle.lua` generates the committed `plugin/main.lua` (`--check` fails when stale); the Uzume sandbox has no `require`, the bundler defines one.
- `plugin/`: `manifest.json`, generated `main.lua`, `i18n/en.json` (source) and `de.json`.
- `tests/`: `lua5.4 tests/run.lua` runs every `tests/test_*.lua` against `tests/support/uz_mock.lua` (fake `uz` with store, run, ui validator, memory, events, `uz.call` providers). Synthetic data only.

## Modules

| Module | Role |
|---|---|
| `timer` | Two clocks. Game time = snapshot frames (the app copies snapshots only while a range is watched, so the plugin always watches one byte under the key `clock`) from `uz.on_tick` / `uz.memory.frame()` divided by the frame rate; real time = `uz.clock()`. Game time stops by itself while the frame number stops (game paused). A frame number that goes back (reset, loaded state) counts nothing. Manual pause stops both. |
| `model` | Split list, attempt, best segments ("gold"), personal best, rule normalization. Pure. |
| `textio` | Export and import of a list as text (below). |
| `rules` | Autosplit rule state for the current split. |
| `views` | HUD, panel and screen trees from a view model. |
| `controller` | Store, hotkeys and actions, tick loop, events, run event. |
| `fmt`, `util` | Time formatting, helpers. |

## Data

One store key per game: `splits.<game code, lower case, [a-z0-9_.-]>` (`uz.store`, permission `store`). Value: `{ v = 1, timing, fps, next_id, attempts, completed, splits = { { id, name, rule? } }, sets = { game = {...}, real = {...} } }` where a set is `{ pb = { total, times = { [split id] = cumulative ms } }, golds = { [split id] = ms } }`. Game time and real time keep separate sets. Times are keyed by split id, so renaming and reordering keep them; deleting a split removes its times. A stale write (another PC saved first) is refused by the store; the plugin tells the user and shows the stored version, the attempted one stays as a store conflict. Without a game (shell context) nothing is stored and the screen shows an empty state.

## Timing rules

- The primary timing method (`game` or `real`) decides the times that are compared and saved; the other is shown next to it in the HUD.
- Frames become milliseconds with the list's frame rate (`fps`). The API does not expose the core's frame rate, so the default is a guess per system (DS, 3DS 59.83; GB, GBA 59.73; else 60) and can be changed in the editor. Changing it does not rescale saved times.
- A split records the cumulative time. Skipping a split records none; the segment after a skip would span several splits and so gives no best segment. The last split cannot be skipped.
- Best segments of an attempt are saved on finish and on reset; the personal best only when a finished run is faster (equal is not better). Undo after the finish restores the previous personal best and run count.
- Splits can be added, moved and deleted only while the timer is idle or finished; renaming and rules can change any time.

## Hotkeys

Declared in the manifest (`ui.hotkeys`), delivered to `uz.ui.on_action(id, nil, "hotkey")`: `split` (start, then split), `undo`, `skip`, `reset`, `pause` (toggle), `open` (editor). Suggested keys are `Ctrl+Shift+Space/Z/K/X/P/E`; they avoid SoulLink's `Ctrl+H`, `Ctrl+D`, `Ctrl+R` (a test checks this). The user can rebind them in Controllers > Hotkeys. The same ids are used by the buttons in the panel and screen.

## Autosplitter

A split has an optional rule, evaluated only for the current split of a running timer.

- `memory`: address, size (`u8`, `u16`, `u32`), comparison (`=`, `!=`, `>`, `>=`, `<`, `<=`, `changed`), value. The range is watched with `uz.memory.watch("rule", ...)` and read on every tick. A condition that is already true when the split becomes current waits for the next change from false to true; `changed` fires when the value differs from the one seen at activation.
- `location`: fires on the event `location.changed` of `uzume.soullink-core` when `zone` matches. The id comes from the game; names shown in the editor are only those the event carried in this session. "Use current zone" copies the last seen zone.
- `badge`: fires on the event `badges.changed` `{ count, new }` of `uzume.soullink-core` (soullink-core 0.6.1 or later) when `new` contains N. No `uz.call`, so no `requires` is needed.

## Text format

```
# comment
@timing game            header lines: @timing (game|real), @fps, @attempts, @completed, @pb (total ms)
Name | rule | PB | best segment
```

`rule`: `-`, `mem 0x02000000 u8 = 5`, `mem 0x02000000 u16 changed`, `badge 3`, `zone 123`. `PB` is the cumulative time of the split in the personal best run, `best segment` the gold, both in ms or `-`. A line without `|` is just a name. Names cannot contain `|` (replaced by `/`). Export writes the active timing method; import replaces the whole list (after a confirm) and is refused while the timer runs.

## Run events

When a run is open in the game (`uz.run.current()`), a new personal best posts the run event `splits.pb` (`text` "New personal best: <time>", `payload` `{ total_ms, timing, splits }`, source automatic). The manifest `recap` block maps `splits.pb` to the glyph `note` (contract in the Uzume 0.22 plan, package 2). A paused run refuses the write; the plugin logs it and goes on.

## Open points

- The core's frame rate is not exposed (see above).
- There is no shutdown hook: best segments of an attempt that is neither finished nor reset are lost when the game closes.
- Memory rules need the game's addresses, which this repository does not ship; users enter them (or import a list).
