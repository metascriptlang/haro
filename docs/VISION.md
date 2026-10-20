# Haro — vision

A terminal emulator written in MetaScript, named after the robot that rides beside the pilot in
Gundam 00. It was called Terminator until 2026-10-15; a Linux terminal emulator already owns that
name. It gets its VT from **libghostty-vt**, draws its pixels
with **void2d**, and runs in an **Ion** window, on Windows, macOS and Linux with the same pixels
everywhere.

It is a **Neon app whose only child is one `<Void>` filling the window**, the shape
Neon's `docs/VISION.md` gives a game: Ion → Neon → Void. The chrome (tabs, splits,
settings, command palette) is Neon `Text`/`View` inside that Void area, so it is void2d too. The
grid is Neon JSX as well: `<TerminalGrid>` is a component whose rows are a `<ForList>` over a
`createList` of row slots, each row one `<Text>` on the cell grid. There is no webview.

## Why it exists

Two goals, and the second is as important as the first.

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

Decided by the person, 2026-10-15. Rejected: a self-managed `<TerminalGrid>` that writes void2d
nodes directly with no reconcile. It is the lower bound for the same work, but it proves nothing
about Neon, and every optimisation it needs (scroll as a move, skipping unchanged rows, coalescing
PTY bursts into one write per frame) would be terminal-only code instead of Neon's.

## Principle: fix upstream, never work around

When Haro hits a defect in void2d, Ion or the MetaScript compiler, the fix goes into that
project, and Haro waits for it. It never works around the defect in its own code. A workaround
here would hide exactly what this project exists to exercise. Haro builds against released
dependencies only.

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

## What unblocks the first window

Measured 2026-09-23 against ion `32bb557`, void `0167080` and neon `6dd27ac`:

1. ~~**Void: a Windows embed driver.**~~ Landed at void `d003ce8`: host views (`voidViewCreate` /
   `voidViewResize` / `voidViewFrame`, `voidViewSwapChain` for Ion's `renderSurfaceAttachSwapChain`).
   One device is shared per process and each view has its own surface, on Windows, iOS and Android.
   `void/docs/EMBED.md` holds the model and its proofs, and `void/examples/ionViews.ms` drives two
   views in one Ion window.
2. ~~**Neon: a desktop entry.**~~ Landed at neon `8f85cb3`: `runWindow` in
   `neon/src/platform/ion/window.ms`, example `neon/examples/voidWindow.ms`.
3. ~~**Ion: a frame clock.**~~ Landed at ion `44001f8`..`3f90df1`: a frame policy per surface,
   measured in `ion/docs/RENDER-SURFACE.md`.

Haro's own core landed without them: ConPTY, libghostty-vt, query replies and a cell reader,
with its measurements in `docs/CORE.md`.

## libghostty-vt — only the parts we need

libghostty-vt exposes a C API (`include/ghostty/vt.h`) and is built with `zig build`
(Zig 0.16). It is vendored as a git submodule pinned to a commit. Upstream marks the API as
unstable, so moving the pin is its own commit, with the build and tests re-run.

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
- When output scrolls the screen by N lines, the list takes `remove` of the top N slots and `push`
  of N new ones (Neon's op path, `neon/docs/RENDER-MODEL.md` "op"), so the other rows keep their
  shaped glyphs and only move. The render state marks every row dirty on a scroll, so N comes from
  the scrollbar offset and a tracked grid ref on the top row; an alternate-screen switch or a ref
  pruned from scrollback repaints every row (`docs/CORE.md` "How far output scrolled").
- Glyphs sit on an **integer cell grid**: monospace cells with whole-pixel origins. The font is
  JetBrains Mono NL (`assets/`, SIL OFL 1.1, picked by the person 2026-10-15): the NL cut has no
  ligatures, which a terminal must never apply across cells.
- Cell backgrounds, underline (straight and wavy), strikethrough, selection and cursor are
  instances of void2d's UI pipeline. The cursor and the selection are their own instances, so a
  blink touches no text.
- Box drawing, blocks, braille and powerline glyphs are drawn procedurally rather than taken from
  the font.
- When nothing changed, a frame draws nothing.

## Platforms

- **Windows first**, then **Linux** and **macOS**.
- Every platform draws the same pixels, since void2d has no OS text system and no per-platform
  text path.
- A platform that has not been run is reported as not tested, never as passing.

## Open

- **A web build.** void2d already builds for WebGPU and WebGL2, and libghostty-vt has a wasm
  target. Not a goal yet.
