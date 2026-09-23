# Terminator — vision

A terminal emulator written in MetaScript. It gets its VT from **libghostty-vt**, draws its pixels
with **void2d**, and runs in an **Ion** window, on Windows, macOS and Linux with the same pixels
everywhere.

It is a **Neon app whose only child is one `<Void>` filling the window**, the shape
`~/metascript/neon/docs/VISION.md` gives a game: Ion → Neon → Void. The chrome (tabs, splits,
settings, command palette) is Neon `Text`/`View` inside that Void area, so it is void2d too. The
grid is void2d nodes that terminator updates directly from dirty rows, with no reconcile pass.
There is no webview.

## Why it exists

Two goals, and the second is as important as the first.

1. **A real terminal**, the kind someone uses all day: correct VT, fast output, good text,
   IME, selection, scrollback, links.
2. **The first production client of void2d.** void2d aims to render application UI at the level of
   a modern code editor: a 13 px code font at 1× and 1.5× DPI that is crisp and scrolls smoothly.
   A terminal presses hard on exactly what that takes: glyph atlas pressure, font fallback (CJK,
   emoji, box drawing), thousands of coloured cells per frame, dirty-only redraw, scroll, and a
   truly idle frame.

## Principle: fix upstream, never work around

When Terminator hits a defect in void2d, Ion or the MetaScript compiler, the fix goes into that
project, and Terminator waits for it. It never works around the defect in its own code. A workaround
here would hide exactly what this project exists to exercise. Terminator builds against released
dependencies only.

## The stack

| project | role |
|---|---|
| **MetaScript** (`msc`) | the language and compiler Terminator is written in |
| **Void / void2d** | the renderer: a retained 2D node tree over sokol_gfx, one GLSL source for Metal, D3D11, GL/GLES3, WebGPU and WebGL2 |
| **Ion** | the desktop runtime: window, event loop, a native render surface, input |
| **libghostty-vt** | the VT emulation library extracted from Ghostty |
| **Neon** | the app: components, fine-grained reactive state, the chrome; the grid sits inside its `<Void>` |

Ion hands out a surface and input events and never draws. The glue between them is not
terminator's. Void drives a surface that its host hands it, and Neon binds an Ion window to a
`<Void>` root. Terminator is their first consumer on the desktop.

## What unblocks the first window

Measured 2026-09-23 against ion `32bb557`, void `0167080` and neon `6dd27ac`:

1. ~~**Void: a Windows embed driver.**~~ Landed at void `d003ce8`: host views (`voidViewCreate` /
   `voidViewResize` / `voidViewFrame`, `voidViewSwapChain` for Ion's `renderSurfaceAttachSwapChain`).
   One device is shared per process and each view has its own surface, on Windows, iOS and Android.
   `void/docs/EMBED.md` holds the model and its proofs, and `void/examples/ionViews.ms` drives two
   views in one Ion window.
2. **Neon: a desktop entry.** It binds an Ion window and its surface to one full-window `<Void>`
   root, and forwards key, text, IME, focus and resize into the void host. None of this exists yet.
3. **Ion: a frame clock.** Ion has none; the MS loop polls (`ion/docs/RENDER-SURFACE.md` "Driving
   the renderer"). A truly idle frame needs a vsync source, such as a DXGI waitable object or
   `DwmFlush`. A surface with its own frame, and input per surface, are not needed by a
   full-window app.

Terminator's own core does not wait on any of them: ConPTY, libghostty-vt and a headless snapshot
of the render state.

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

**libghostty-vt has no PTY.** Terminator owns ConPTY on Windows and `forkpty` on POSIX.

## How a frame is drawn

- One node per visible row, owning that row's cells. Only the rows the render state marks dirty
  are re-emitted.
- Glyphs sit on an **integer cell grid**: monospace cells with whole-pixel origins.
- Cell backgrounds, underline (straight and wavy), strikethrough, selection and cursor are
  instances of void2d's UI pipeline. The cursor and the selection are their own instances, so a
  blink touches no text.
- Box drawing, blocks, braille and powerline glyphs are drawn procedurally rather than taken from
  the font.
- Scroll is a snapped translation of the grid rather than a rebuild. When nothing changed, a frame
  draws nothing.

## References

- **Ghostty**: the VT, used as a library, and its renderer as a reference for the font stack,
  glyph atlas and frame discipline.
- **WezTerm**: Windows ConPTY handling, font fallback configuration and multiplexing.

## Platforms

- **Windows first**, then **Linux** and **macOS**.
- Every platform draws the same pixels, since void2d has no OS text system and no per-platform
  text path.
- A platform that has not been run is reported as not tested, never as passing.

## Open

- **A web build.** void2d already builds for WebGPU and WebGL2, and libghostty-vt has a wasm
  target. Not a goal yet.
