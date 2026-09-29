# Terminator core — what the code does not say

The headless core is `src/pty` (ConPTY), `src/vt` (libghostty-vt) and `src/session` (the two
joined). Types, signatures and the API are in those files; this page holds what they cannot say:
measured numbers, platform behaviour found by probing, and paths that were rejected.

## libghostty-vt

- Pinned as the submodule `vendor/ghostty` (`git submodule status`), built by
  `scripts/buildVt.sh` with Zig 0.16 into `ghostty-vt-static.lib`, linked with `GHOSTTY_STATIC`.
  Moving the pin is its own commit, with the build and the gate re-run: upstream marks the C API
  unstable.
- Getters that write through `void* out` are bound as typed externs in `src/vt/vt.ms`
  (`stateCols`, `cellColor`, `cellStyle`…) rather than called through the header import. Through
  the import a `void*` out takes any variable, so a `uint32` handed to a key that writes a
  `uint16` compiles and corrupts memory. The typed extern pins each key to its type. A getter that
  writes a handle has to be an extern anyway: since msc `1718d72c` the import refuses a handle out.
- `write_pty` and every other effect run synchronously inside `vt_write` and must neither block
  nor re-enter the terminal (`terminal.h`, "Effects"). So `src/vt/effects.c` only queues the
  replies per terminal, and `Session.pump` drains them into the PTY after each write.
- A write that moves the cursor dirties more than the row it writes. In `probe/frameRead.ms`,
  homing the cursor from row 59 and writing one cell on row 0 dirtied 2 rows; the same write
  with the cursor already on row 0 dirtied 1. Which second row it was was not checked.
- Rejected: `ghostty_render_state_row_cells_get_multi` for a whole cell. It stops at the first
  key that fails, and `FG_COLOR`/`BG_COLOR` fail with `INVALID_VALUE` whenever a cell uses the
  default colour, so a single multi call cannot read a default-coloured cell.

## Key encoder

- `ghostty_key_event_set_utf8(ptr, 0)` and `set_utf8(null, 0)` both leave the text empty
  (`src/terminal/c/key_event.zig`), so `Keys.encode` always resets the reused event's text with
  `""` before encoding; a reused event otherwise keeps the previous key's text (the header
  sanctions reuse). Text with C0/DEL bytes or macOS PUA U+F700–U+F8FF must not be passed
  (`key/event.h`), so `textSafe` filters it and the encoder derives the key from the logical key.
- The legacy encoder emits fixterms `CSI <codepoint>;<mods>u` whenever Ctrl is held with
  printable text, regardless of consumed mods (`src/input/key_encode.zig`, `legacy()`, the
  `event.mods.ctrl` block). Consumed mods only remove a modifier from *binding*: a consumed Alt
  with text sends the text raw, an unconsumed Alt prefixes `ESC`.
- ion marks Ctrl+Alt consumed exactly when AltGr produced text ≥ 0x20
  (`ion/src/platform/windows/input/input.c`, `ionWinKeyFlush`). An AltGr key fed to
  `Keys.encode` unchanged therefore leaves as `CSI 123;7u`-style fixterms bytes, which conhost
  shells do not parse. Whether the phase-B wiring strips consumed Ctrl+Alt first is open
  (card step 7).
- ion's `ION_MOD_*` bits and ghostty's `GHOSTTY_MODS_*` bits are the same order, including the
  side bits (`src/keys/keys.ms` `modsMask` passes the mask through).
- `\xNN` inside a `.ms` string literal is the *codepoint* NN, not a raw byte: `"\xef"` is "ï"
  (UTF-8 `C3 AF`). Byte-level expectations in tests are written with `String.fromCharCode` or
  compared against `buf` bytes directly.

## ConPTY, probed on Windows 11 10.0.26200

- conhost answers a cursor position query (`ESC[6n`) and DA1 (`ESC[c`) itself: a child's query
  never reaches terminator. It forwards XTVERSION (`ESC[>q`), OSC 11 (`ESC]11;?`) and the colour
  scheme query (`ESC[?996n`). On POSIX every query reaches the terminal.
- A reply written to the input pipe passes through conhost's input parser. A DCS reply
  (XTVERSION's `ESC P >| … ESC \`) reaches a child reading with `[Console]::ReadKey` as the
  trailing `\` only (`src/session/xtversion.ps1`, test "a program's terminal query gets an answer
  back through the pty").
- At startup ConPTY emits `ESC[?9001h` (win32-input-mode) and `ESC[?1004h` (focus events), and
  resets both when the child exits.

## Measured

Ryzen 9 9950X, Windows 11 10.0.26200, msc `3f6873ee`, tree `07cec781ff808899b343bb1c595281a4d4ccffe1`.

| what | number | how |
|---|---|---|
| full read of a 200x60 screen, every cell styled | 0.555–0.580 ms | `msc build probe/frameRead.ms --release`, median of 50, three runs |
| `dirtyRows()` after one write | 9.4–9.8 µs | same probe |
| `update()` after one write | 0.4–1.0 µs | same probe |
| CPU while a child is silent for 3 s, reading with `pty.wait` | 16–31 ms, 3 wakes | a loop of `wait(10000)` then `read` over `cmd.exe /c ping -n 4 127.0.0.1 > nul`, release, `TotalProcessorTime`, two runs |
| the same child, reading in a spin loop | 3,016–3,078 ms | the same loop without `wait` |

What the numbers decided: per-key getters stay. A full redraw costs about 3.5% of a 60 Hz frame,
so neither `get_multi` nor a C row reader is needed until a measurement says otherwise.
