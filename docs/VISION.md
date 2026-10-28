# Haro — vision

A terminal emulator written in MetaScript, named after the robot that rides beside the pilot in
Gundam 00. It gets its VT from **libghostty-vt**, draws its pixels with **void2d**, and runs in an
**Ion** window, on Windows, macOS and Linux with the same pixels everywhere.

It is a **Neon app whose only child is one `<Void>` filling the window**, the shape Neon's
`docs/VISION.md` gives a game: Ion → Neon → Void. The chrome (tabs, splits, settings, command
palette) is Neon `Text`/`View` inside that Void area, so it is void2d too. The grid is Neon JSX as
well: a `ForList` (`src/app/components/features/terminal/terminalPane.ms`) over a `createList` of
row slots (`src/app/frame.ms`), each row one `CellText` on the cell grid.
There is no webview.

## Why it exists

Three goals; the second is as important as the first.

1. **A real terminal**, the kind someone uses all day: correct VT, fast output, good text,
   IME, selection, scrollback, links.
2. **The first production client of void2d.** void2d aims to render application UI at the level of
   a modern code editor: a 13 px code font at 1× and 1.5× DPI that is crisp and scrolls smoothly.
   A terminal presses hard on exactly what that takes: glyph atlas pressure, font fallback (CJK,
   emoji, box drawing), thousands of coloured cells per frame, dirty-only redraw, scroll, and a
   truly idle frame.
3. **Neon's reactive model at its hardest load.** A terminal grid is usually drawn by hand. Haro
   keeps the grid in JSX and aims to be faster than hand-drawn, because Neon's model hands it the
   optimisations a hand-drawn grid has to write and maintain itself (see "How a frame is drawn").
   It is measured against other terminals on the same workloads, not against an internal
   hand-drawn variant.

Decided by the person, 2026-10-15. Rejected: a self-managed grid component that writes void2d
nodes directly with no reconcile. It is the lower bound for the same work, but it proves nothing
about Neon, and every optimisation it needs (scroll as a move, skipping unchanged rows, coalescing
PTY bursts into one write per frame) would be terminal-only code instead of Neon's.

## Principle: fix upstream, never work around

When Haro hits a defect in void2d, Ion or the MetaScript compiler, the fix goes into that
project, and Haro waits for it. It never works around the defect in its own code. A workaround
here would hide exactly what this project exists to exercise. Haro imports void2d, Neon and Ion
from sibling checkouts by relative path, so the upstream fix reaches it when the checkout moves.

## The stack

| project | role |
|---|---|
| **MetaScript** (`msc`) | the language and compiler Haro is written in |
| **Void / void2d** | the renderer: a retained 2D node tree over sokol_gfx, one GLSL source for Metal, D3D11, GL/GLES3, WebGPU and WebGL2 |
| **Ion** | the desktop runtime: window, event loop, a native render surface, input |
| **libghostty-vt** | the VT emulation library extracted from Ghostty |
| **Neon** | the app: components, fine-grained reactive state, the chrome; the grid sits inside its `<Void>` |

Ion hands out a surface and input events and never draws. The glue between them is not
Haro's. Void drives a surface that its host hands it, and Neon binds an Ion window to a
`<Void>` root. Haro is their first consumer on the desktop.

## libghostty-vt — only the parts we need

libghostty-vt exposes a C API (`include/ghostty/vt.h`); how it is pinned and built is in
`docs/CORE.md` "libghostty-vt".

Take:
- `terminal.h`, `screen.h`: VT state, scrollback, reflow on resize.
- `render.h`: an incrementally updated render state with dirty-row iteration
  (`ghostty_render_state_row_iterator_next_dirty`). This is the seam to void2d's retained tree: a
  dirty row updates that row's node and nothing else.
- `key.h`, `mouse.h`, `focus.h`, `paste.h`: input encoding, the Kitty keyboard protocol included.
- `osc.h`, `sgr.h`, `selection.h`, `search.h`, `modes.h`, `color.h`.

Do not take: Ghostty's renderer, font stack and app runtime. Those are void2d's and Ion's jobs.
Kitty graphics is a later decision.

**libghostty-vt has no PTY.** Haro owns ConPTY on Windows and `forkpty` on POSIX.

## How a frame is drawn

- One row component per visible row slot, fed by its own signal. A row whose line did not change
  writes no node, and PTY output that arrives several times between two frames writes each row
  once.
- When output scrolls the screen by N lines, the list moves its top N slots to the bottom
  (`List.move`, a command on Neon's list handle, `neon/docs/RENDER-MODEL.md` "After mount: the
  wire graph"), so the kept rows keep their shaped glyphs and only move. The render state marks
  every row dirty on a scroll, so N comes from the scrollbar offset and a tracked grid ref on the
  top row; an alternate-screen switch or a ref pruned from scrollback repaints every row
  (`docs/CORE.md` "How far output scrolled").
- Glyphs sit on an **integer cell grid**: monospace cells with whole-pixel origins. The font is
  JetBrains Mono NL (`assets/`, SIL OFL 1.1, picked by the person 2026-10-15): the NL cut has no
  ligatures, which a terminal must never apply across cells.
- Cell backgrounds, underline (straight and wavy) and strikethrough are instances of void2d's UI
  pipeline. A selected cell and the cell under a resting block cursor are drawn in their own
  colours, so the character stays readable: a selection change rebuilds only the rows whose
  selected span changed, and a blink rebuilds only the cursor's row. The other cursor shapes and
  a block in motion are their own instances.
- Box drawing, blocks, braille and powerline glyphs are drawn procedurally rather than taken from
  the font.
- When nothing changed, a frame draws nothing.

## A programmable terminal

Decided by the person on 2026-10-20. Haro goes deep (blocks, an input editor, a
palette, panels), but Haro keeps a small core and exposes it, and those
features are written against that surface as user code and plugins rather than built into Haro.

The surface is the `haro` package (`assets/haro/index.ms`), and `~/.config/haro/config.ms` is
written against it. Only `config` exists today; the hooks, host routines and plugins below are
planned:

- `export const config: HaroConfig`: the settings, checked by msc against the type before Haro
  reads them: a config table, but typed.
- Exported hooks (`onKey`, `onPrompt`, `onCommandDone`, `onOutput`, …) receive events. Haro
  already reads the OSC 133 prompt marks a block needs.
- Host routines (`send`, `decorate`, `openFloat`, …) act on the terminal.
- Plugins draw in **cells**: floating windows, decorations over a range of
  cells, and virtual text. Haro's own blocks are written as the first plugin, so the
  surface is proven by a real consumer.

### It needs Raiser embedded in Haro

A hook needs an interpreter that lives in Haro and keeps state between calls. A subprocess
cannot give it that. So Haro links the compiler's embed API (`recompiler/src/embed/index.ms`:
`createInterpreter`, `evalModule`, `callRoutine`, `implementRoutine`).

This reverses the decision of 2026-10-19, which read config as data and did not embed. The
numbers behind that decision still stand; the hooks are what now outweigh them. Measured by the
recompiler session raiser-embed on 2026-10-19, a host and a 1000-ball loop, not Haro:

| | embedded Raiser | `msc run` subprocess | Lua 5.4 |
|---|---|---|---|
| host binary | 15,753,832 B | Haro alone 6.3 MB | — |
| cold config eval | 0.42 s, 110 MB peak RSS | 0.31 s, 104 MB | — |
| host → script call | 99–101 ns | — | 15 ns |
| `update` per frame | 0.58–0.61 ms | — | 0.068 ms |

The call cost is fine for a hook per key or per event. It is not fine for a hook per cell or
per output line during a flood.

Haro has evaluated `config.ms` in-process since 2026-10-20 (`src/config/source.ms` `evaluate`).
Measured that day on macOS, msc `8205756f8`: the release binary went from 6.3 MB to 21.2 MB, and
an evaluation takes about 0.4 s. An evaluation leaves about 66 MB live after Haro drops the
interpreter, which is a compiler card: `evalModule` keeps its heap after the host drops it.
A bundled Haro.app evaluates the config against the std it carries in
`Contents/Resources/metascript` (`scripts/buildApp.sh` copies it there), so it runs without
MetaScript installed; an unbundled build reads the std from `~/.metascript`.

### Rejected, and why

- **Plugins that build Neon components** (free-form UI). Script code would have
  to run Neon's component model inside Raiser and hand the nodes to the host to draw. That is a
  new mechanism in both Neon and the compiler, and it would grow the API into all of Neon. Cells
  first; this stays open.
- **`haro.on("key", fn)` closures** for now. No closure crosses the embed boundary yet, so hooks
  are exported functions found by name. The closure form can be added on top later.
- **Config as JSON for good.** It stays only until the embed API carries structs. Until then
  the runner module's `configJson()` returns `JSON.stringify(config)`, and `src/config/config.ms` `parse` re-checks
  what msc already checked.

### What the embed path waits on

One compiler change: structs and arrays crossing `callRoutine`.

## Platforms

- **Windows first**, then **Linux** and **macOS**.
- Every platform draws the same pixels, since void2d has no OS text system and no per-platform
  text path.
- A platform that has not been run is reported as not tested, never as passing.

## Open

- **A web build.** void2d already builds for WebGPU and WebGL2, and `probe/web` runs Haro's `Vt`
  under node on libghostty-vt built for wasm (`docs/CORE.md` "libghostty-vt"). The Haro window as
  a web app is not a goal yet.
