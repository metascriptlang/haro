# Haro core — what the code does not say

The headless core is `src/pty` (ConPTY on Windows, `forkpty` on POSIX), `src/vt` (libghostty-vt),
`src/session` (the two joined) and `src/controller` (what a window drives them with). Types, signatures and the API are in those files; this page
holds what they cannot say: measured numbers, platform behaviour found by probing, and paths that
were rejected.

## libghostty-vt

- Pinned as the submodule `vendor/ghostty` (`git submodule status`), built by
  `scripts/buildVt.sh` with Zig 0.16 into `ghostty-vt-static.lib`, linked with `GHOSTTY_STATIC`.
  Moving the pin is its own commit, with the build and the gate re-run: upstream marks the C API
  unstable. The web build takes the same pin through `scripts/buildVtWasm.sh`, which applies
  `patches/ghostty-wasm-embedder.patch` (wasm32 takes its memory from the embedder) and builds
  for `wasm32-freestanding`.
- Getters that write through `void* out` are bound as typed externs in `src/vt/vtNative.ms`
  (`terminalGet`, `stateGet`, `cellsGet`, `rowGet`) rather than called through the header import.
  Through the import a `void*` out takes any variable, so a `uint32` handed to a key that writes a
  `uint16` compiles and corrupts memory. The typed extern gives the out the type of the variable
  passed. A getter that
  writes a handle has to be an extern anyway: since msc `1718d72c` the import refuses a handle out.
- `write_pty` and every other effect run synchronously inside `vt_write` and must neither block
  nor re-enter the terminal (`terminal.h`, "Effects"). So `src/vt/effects.c` only queues the
  replies per terminal, and `Session.pump` drains them into the PTY after each write.
- A write that moves the cursor dirties more than the row it writes. In `probe/frameRead.ms`,
  homing the cursor from row 59 and writing one cell on row 0 dirtied 2 rows; the same write
  with the cursor already on row 0 dirtied 1. Which second row it was was not checked.
- `vt.size()` reads the render-state snapshot, so it lags a `vt.resize` until the next
  `update()` — the session resize test checks the size only after `screen()`, which updates.
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
  shells do not parse, so `sendKey` first clears Ctrl and Alt, side bits included, from a key
  whose Ctrl+Alt was consumed (`withoutAltGr`).
- ion's `ION_MOD_*` bits and ghostty's `GHOSTTY_MODS_*` bits are the same order, including the
  side bits (`src/keys/keys.ms` `modsMask` passes the mask through).
- `\xNN` inside a `.ms` string literal is the *codepoint* NN, not a raw byte: `"\xef"` is "ï"
  (UTF-8 `C3 AF`). Byte-level expectations in tests are written with `String.fromCharCode` or
  compared against `buf` bytes directly.

## How far output scrolled, probed

A scroll marks every row of the render state dirty, so the dirty iterator cannot tell a scroll from
a repaint. `probe/scrollRef.ms` (80x24, msc `9cf5708c`, tree
`504771cca46c2ce2d7153a16f5c9a5cb37e58e06`) measured what can:

- A tracked grid ref placed on the top viewport row keeps its **screen** y when that row scrolls
  into history (screen coordinates count from the top of scrollback); its viewport and active
  points return `GHOSTTY_NO_VALUE` once the row leaves the viewport. So the ref alone gives no N.
- **N = `ghostty_terminal_get(…SCROLLBAR)`.offset − the ref's screen y**, then re-anchor the ref
  on viewport row 0. Exact for K = 1, 3, 7, 24 and 100 lines, with scrollback capped at 10 or 0
  lines too (the cap is page-granular: 124 rows were still kept).
- When the row is pruned from scrollback (K = 5000), `has_value` turns false: repaint everything.
- Entering or leaving the alternate screen (`ESC[?1049h`/`l`) gives N = −7 and 7, both wrong:
  the ref stays on the screen it was set on while the scrollbar is the active screen's. Watch
  `GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN` and repaint everything when it changes.
- A clear (`ESC[2J`) gives N = 0 with all 24 rows dirty; overwriting one row gives N = 0 with two
  rows dirty: that row and the old cursor row. Moving the cursor to another row dirties both rows;
  moving it within a row, or hiding or showing it, dirties nothing, so the cursor is read every
  frame.
- After any scroll the render state is FULL and every row's dirty flag is set, so the VT cannot say
  which kept rows changed. A pure scroll leaves each kept row identical to its old position at
  `y + N`; a kept row edited in the same frame shows only by comparing cells. That is why
  `src/screen/plan.ms` keeps the rows it last planned (`Vt.painted`) and diffs on a scroll frame.
- Reverse index at the top, and any scroll inside the alternate screen, gives N = 0 with all rows
  dirty: a rows frame, never a scroll. These probes ran on the library's default cap, 10 000 bytes
  (`Terminal.zig`), under which 5000 lines prune the ref at 80 columns but not at 10; `Vt.create`
  now sets a line cap and a byte cap instead.

## ConPTY, probed on Windows 11 10.0.26200

- After a resize, pump before reading rows: ConPTY repaints and reflows, and the fresh content
  lands through the normal output path (test "a resize reaches a live child as its console size",
  which also shows `[Console]::WindowWidth/Height` inside the child tracking the new grid).

- conhost takes input only as fast as the child reads it: one 1 MiB `WriteFile` to `ping`, which
  never reads, blocked 1060 ms (`probe/writeBlock.ms`, 2026-10-19). So `ptyWrite` queues and a
  writer thread writes; a failed write surfaces on the next `ptyWrite`. The reader parks at 4 MiB
  unread so a flood pushes back on the child; closing while it is parked took 5 ms
  (`probe/closeParked.ms`).
- conhost may send `ESC[1C` for a space inside a line (`line ESC[1C3971`) and puts its exit-time
  mode resets between CR and LF. Under 90 % machine load a check that took LF as the end of each
  line stopped at line 23, the first scroll of an 80x24 screen, with every byte present (two gate
  runs, 2026-10-19). So the flood check in `src/pty/ptyTest.ms` reads each number between `L` and `.`
  and skips CSI, wherever conhost ends the line.

- conhost answers a cursor position query (`ESC[6n`) and DA1 (`ESC[c`) itself: a child's query
  never reaches Haro. It forwards XTVERSION (`ESC[>q`), OSC 11 (`ESC]11;?`) and the colour
  scheme query (`ESC[?996n`). On POSIX every query reaches the terminal.
- A reply written to the input pipe passes through conhost's input parser. A DCS reply
  (XTVERSION's `ESC P >| … ESC \`) reaches a child reading with `[Console]::ReadKey` as the
  trailing `\` only (`src/session/xtversion.ps1`, test "a program's terminal query gets an answer
  back through the pty").
- At startup ConPTY emits `ESC[?9001h` (win32-input-mode) and `ESC[?1004h` (focus events), and
  resets both when the child exits.
- conhost re-encodes SGR. `58;2;255;80;80` (underline colour) comes out as `ESC[2m`, faint,
  with the colour dropped, so an underline colour never reaches Haro through ConPTY; libghostty-vt
  parses all three SGR 58 forms when it gets them. Bytes a child writes with `WriteFile` (`cmd /c
  type`) are decoded with the console code page, 437 by default, then re-encoded as UTF-8: the
  UTF-8 for `中` arrives as `Σ╕¡`. Measured 2026-10-16 by capturing ConPTY output for
  `fixtures/styles.ansi`.
- conhost drops OSC 111 (reset the default background), and holds back a child's `ESC[?25l`: a
  pwsh script that hides the cursor and keeps running shows `?25l` only when it exits, beside
  conhost's own `?9001l`/`?1004l` (`probe/capture/capture.ms`, 2026-10-17). OSC 11, OSC 52 writes
  and DECSCUSR reach Haro.
- conhost swallows a kitty keyboard reply written to the input pipe: `ESC[?0u` reaches a child
  reading keys as nothing at all (`probe/inputEcho/inputEcho.ms`), so a program's `CSI ? u` query
  never sees Haro's answer and stays in legacy key encoding.
- nvim 0.12 with the person's config, 30 presses of `j` (release Haro, 2026-10-17): nvim's first
  output follows the key in 4 ms (median), and the last frame applies 48 ms after the key (median,
  126 ms max). Haro's old pacing timer added a median 13 ms (max 32 ms) to each later chunk, because
  Ion's timers step by `GetTickCount64`, about 16 ms. Since output applies in the window's frame
  callback (`ea961a7`), the last chunk lands in the frame drawn a median 3.3 ms after its wake (max
  7.7 ms in the quieter run), measured 2026-10-18 by interleaving the two builds under the same
  load. The machine was at 54-100 % CPU, so nvim's own response (key to first output) was not
  comparable between runs and is not restated.

## First window, smoke-run

`src/app/haro.ms --smoke` (tree `c120ef45157c565615ff1a9e380849230844608e`, msc `b267cdb1`, neon
`f48eec6`, ion `a68e849`, Consolas 14 px at 96 DPI, 948x588 → 118x34 cells,
`pwsh -NoLogo -NoProfile`, run from the void repository root for void's default font path):

- The prompt and command output appear with no window event: the ConPTY reader calls
  `ionWakeLoop()` (`src/pty/conpty.c` `ptySetWake`) and `onWake` pumps and applies the frame plan.
- 200 lines (`1..200 | % { "line $_" }`) leave rows `line 168` … `line 200` and the prompt in
  order: the scroll path is correct.
- Idle: frame counts did not move over 2 s (`requested=4 drawn=5` before and after), and the
  process used 0–15.6 ms of CPU over 3 s.
- Keys (`WM_KEYDOWN`/`WM_CHAR` posted to the window), committed text (`ệ`), Up-arrow history
  through `Keys.encode`, and three resizes (pwsh reported 84x21, 99x26, 59x14) reached the shell.
- With the person's profile the window exited at the first prompt: starship prints U+F0054, above
  U+FFFF. Since `9b63bd7` the grid builds such cells with std's `fromCodePoint`.

Re-run 2026-10-16 (msc `5631dd3e5`, neon `2b0f58c`, void `40e9bfa3`, JetBrains Mono NL 14 px,
105x30 cells): through a live ConPTY, bold, italic, bold-italic, plain and curly underline,
strike-through, 16/256/truecolor and backgrounds draw right. A replay that ends before the first
frame drew every row over row 0: the row height is a signal set in `onLayout`, and Neon requested
no frame for a layout-only change until neon `2104058`.

## Measured

Ryzen 9 9950X, Windows 11 10.0.26200, msc `3f6873ee`, tree
`07cec781ff808899b343bb1c595281a4d4ccffe1`.

| what | number | how |
|---|---|---|
| full read of a 200x60 screen, every cell styled | 0.555–0.580 ms | `msc build probe/frameRead.ms --release`, median of 50, three runs |
| `dirtyRows()` after one write | 9.4–9.8 µs | same probe |
| `update()` after one write | 0.4–1.0 µs | same probe |
| CPU while a child is silent for 3 s, reading with `pty.wait` | 16–31 ms, 3 wakes | a loop of `wait(10000)` then `read` over `cmd.exe /c ping -n 4 127.0.0.1 > nul`, release, `TotalProcessorTime`, two runs |
| the same child, reading in a spin loop | 3,016–3,078 ms | the same loop without `wait` |

Flood and pipeline, 2026-10-16 (msc `5631dd3e5`, release):

| what | number | how |
|---|---|---|
| Haro CPU while `cmd /c type` floods 10 MB | 74–80 % of a core before pacing (`318eab2`), 17–25 % after (`b2e9537`); flood 5.7–9.9 s either way; idle 0 % | `-Work flood` of a scratch driver that is not in the repo, three runs each, the Haro process only. The same script gave other terminals 17–22 %, 32–38 %, 85–102 % and 127–145 % the day before |
| a full 40-row repaint through `applyFrame`, no window | about 0.5 ms (light_cells), 1.6 ms (dense_cells) | `sh bench/run.sh`, median of 7 |
| `row.line()` | about 10 µs a row | same |
| `spansOf` on a row whose every cell changes colour | about 57 µs a row; under 1 µs on plain rows | same |
| libghostty-vt `write` of `y` and a newline, scrolling | about 20 MiB/s | same |

What the numbers decided: per-key getters stay. A full redraw costs about 3.5% of a 60 Hz frame,
so neither `get_multi` nor a C row reader is needed until a measurement says otherwise.

Live window, 2026-10-19 (msc `4fe2a5eec`, neon `7675ed3`, void `a38429c8`, ion `0cac3a0`, release
with `-d:voidProfiler`, 165 Hz display, 105x30 cells; other sessions held the machine at 41–60 %
CPU). `pwsh bench/live/drive.ps1 -Exe <haro> -Work <work>` reads `--stats`; echo runs from the key
to the first apply that changes rows, settle from the last wake before that apply.

| work | Haro CPU | what the counters show |
|---|---|---|
| flood: `cmd /c type` of 10 MB plain | 57–67 %, 9.4–15.5 s, four runs | every frame a Repaint of all 30 rows at 165 frames/s; ~5,500 wakes/s; Void draw p50 1.75 ms; the profiler build costs nothing measurable |
| colour: 10 MB of truecolour cells | 34–50 %, 7.4–21 s, three runs | a Scroll frame per frame, ~6 new rows each; Void draw p50 0.65 ms |
| echo: `a` into `cmd /k`, 120 keys 40 ms apart | 2–3 % | echo p50 3.8–66 ms; settle p50 3.7–19 ms; the quietest run 3.8 ms echo, 7.9 ms max |
| nvim: `j` in `nvim --clean -n`, 120 keys | 6–8 % | echo p50 50–80 ms against settle p50 4.7–6.4 ms; each frame sends ~28 of 30 rows |

What the numbers say: flood CPU is three times the 17–25 % of 2026-10-16 (frames then rode a timer;
since `ea961a7` each applies in a 165 Hz frame callback), unconfirmed against that build. The nvim
echo of 50–80 ms did not hold: the same builds gave 4.9–5.5 ms the same evening (settle 3.8–4.0 ms),
so the afternoon figure came from the machine's state then, cause unknown. An idle focused window
draws 1–2 frames a second: the blink.

Changes measured against that baseline, builds interleaved, same day and load:

| change | before → after | how |
|---|---|---|
| a scroll moves the kept rows to the bottom (`List.move`) instead of removing and pushing one per line | colour flood: Void draw p50 0.65–0.67 → 0.26–0.36 ms, Haro CPU per drawn frame 3.35–3.45 → 2.3–3.0 ms | `-Work color`, three pairs |
| leftover output, wheel, key-bound and autoscroll refreshes wait for the next paced frame | replay of 10 MB: 10 of 10 applies ran outside any frame with dirty-to-present 20–24 ms → all 10 inside frames at 2.4–2.6 ms; 30 wheel records at once: 30 refreshes building 900 rows for one drawn frame → 1 refresh, 30 rows | `-Work replay`, three pairs; 30 `WM_MOUSEWHEEL` posted to the window |
| Neon `510b0c6` (no draw for a frame that changes nothing, window hidden until the first frame), with Haro `2d8cc6f` | none within noise: flood 7.1 → 7.3 s at 53.7 → 53.6 % CPU, colour 8.5 → 6.7 s at 38.8 → 40.6 %; an idle focused window still draws 1–2 frames a second, which is the cursor blink | `-Work flood` and `-Work color`, second of two interleaved rounds (the first ran under 40–60 % machine load from other jobs and varied 2–4×) |
| a row leaves out its trailing empty cells (a blank with the default background, no underline or strikethrough) | headless, short-line workloads: plan+lines 1.8–2.3 → 1.1–1.3 ms, applyFrame 5.1–8.6 → 4.3–6.6 ms; full rows unchanged. Live flood: 118 → 65 characters per row, Void draw p50 1.41–1.64 → 1.39–1.54 ms, wall and CPU unchanged (the flood waits on conhost); nvim unchanged, since its rows carry its own background | `bench/run.sh`, two interleaved rounds; `-Work flood` and `-Work nvim`, three interleaved pairs |
| 2026-10-21 (msc `b1f63337f`): `line()` walks a cell's codepoints in place instead of copying them into a `Vec` per cell, and appends each one without a temporary string | headless lines stage, 64 KiB frames: dense_cells 10.4–11.2 → 5.0–5.4 ms (9.4–10.1 → 4.5–4.8 µs a row), light_cells 6.5–6.8 → 2.6–2.9 ms, unicode 4.0–4.7 → 2.3–2.4 ms, ghosttyWideMix 29.1–29.6 → 16.9 ms, ghosttyStyled 30.4–32.1 → 17.7–18.0 ms; spans unchanged (dense_cells 58–61 ms, the style strings) | `bench/bench.ms --only <name>`, old and new builds interleaved, two rounds |
| 2026-10-21 (msc `b1f63337f`): the style cache keys a run by its colours and attributes packed in one number, and builds the style strings only on a miss | headless spans stage, 64 KiB frames: dense_cells 57.0–57.3 → 11.1–11.4 ms (applyFrame 75.9–76.2 → 26.8–26.9 ms), ghosttyStyled 23.5–24.0 → 15.8–16.9 ms (applyFrame 66.4–68.9 → 60.2–61.2 ms), light_cells 0.27–0.28 → 0.12–0.13 ms | `bench/bench.ms --only <name>`, old and new builds interleaved, two rounds |

Launch, 2026-10-19 (Haro `b5d2e7d`, same stack; `--stats` prints `haro launch:`, and
`-Work launch` or a `--shell` override turns it into ms after the process was created; three
launches each, machine at ~50 % CPU):

| shell | main | layout | spawned | first output | first text |
|---|---|---|---|---|---|
| `cmd.exe` | 10–19 | 164–209 | 178–257 | 463–501 | 467–505 |
| `pwsh -NoLogo -NoProfile` | 10–14 | 178–184 | 188–200 | 453–485 | 456–486 |
| `pwsh -NoLogo` with the person's profile | 11–14 | 169–182 | 181–196 | 445–472 | 1312–1361 |

A config cache hit costs under 2 ms. The window, both devices and the first layout take 150–190 ms
before the shell is spawned, and ConPTY needs 250–290 ms after the spawn before the first byte,
whatever the shell.

ConPTY host, 2026-10-19 evening (Haro `c6c96fd` loads a `conpty.dll` beside `haro.exe`; one
binary copied beside nothing, beside an OpenConsole 1.22.2502.04002 pair, and beside NuGet
`Microsoft.Windows.Console.ConPTY` 1.25.260930003; the process tree confirmed conhost.exe,
OpenConsole.exe and OpenConsole.exe; three interleaved rounds, machine at 15–57 % CPU):

| work | inbox conhost 10.0.26100.1 | OpenConsole 1.22 | OpenConsole 1.25 |
|---|---|---|---|
| flood, 10 MB | 5.8–6.5 s, Haro 48–55 % | 5.1–6.4 s, 52–62 % | 5.4–5.9 s, 58–60 % |
| colour, 10 MB | 4.7–7.0 s, Haro 45–48 % | 5.1–6.7 s, 56–67 % | 5.1–5.4 s, 59–66 %; one run 38 s, the host emitting 20–30 rows a second |
| echo into `cmd /k`, p50 | 3.5–4.9 ms | 3.2–4.1 ms | 3.3–4.3 ms |
| nvim `j`, echo p50 | 4.4–4.7 ms | 4.5–4.6 ms | 4.3–4.6 ms |
| spawn to first byte | 226–262 ms | 221–460 ms | 228–455 ms |

Neither OpenConsole moves throughput, echo or launch for Haro; both cost Haro more CPU per byte,
and 1.25 stalled once. During an inbox flood no process saturates a core (cmd ~35 %, conhost
45–55 %, Haro ~60 %), and HighQoS on conhost changed nothing, so the flood waits on something
other than conhost's speed.

What the new host does carry is the sequences an app writes. `probe/recordPty.ms` recorded
`cmd /c type` of one file holding 13 tagged sequences through each host. OpenConsole 1.25
passed all 13 unchanged and in place. Inbox conhost re-renders its own buffer:

- dropped: Kitty graphics APC and sixel DCS;
- kept, but moved out of place: OSC 7, 52 and 0 (the title arrived only after the child exited);
- kept: `?2026h/l`, but sent before the text it bracketed rather than around it, so nothing is
  synchronized;
- kept: OSC 133, OSC 8 (with an `id=` added), `CSI >1u`, `?2004h` and the underline colour;
- absent from the stream: mouse modes `?1000h ?1006h` and focus `?1004h`. The host takes these as
  its own, so a recording of output cannot say whether the mouse works.

Clicks posted to a live Haro window (`WM_LBUTTONDOWN` at two rows, two runs per host) reached
the app through both hosts alike. nvim `--clean` with `mouse=a` moved its cursor to rows 16
and 24. A Python app that set VT input and wrote `?1000h ?1006h` read
`\x1b[<0;36;16M\x1b[<0;36;16m` and the same for row 24. So on Windows 11 the inbox host does
not cost Haro the mouse, and the mouse is no reason to bundle OpenConsole there. Windows 10, which
never receives host fixes, was not measured.

Keys go the other way, and neither host carries them better. `probe/keysPty.ms` sent 22 chords
through Haro's own encoder (libghostty-vt) into pwsh `[Console]::ReadKey`. Both hosts gave
the same result:

- lost: Shift+Enter, Ctrl+Enter and Ctrl+Tab. Haro sends `CSI 27;<mod>;<key>~`, and ConPTY
  drops it;
- lost before ConPTY: Ctrl+Shift+A and Ctrl+. (the encoder writes nothing for them);
- arrived as another key: Ctrl+Space as Ctrl+Shift+2 (NUL), Ctrl+/ as Ctrl+Shift+- (0x1F);
- arrived intact: Ctrl+letters, Ctrl+Alt+A, Alt+F, Alt/Ctrl+Backspace, Shift+Tab, Ctrl+Left,
  Shift+Home, F5 with each modifier, Escape.

Both hosts ask the terminal for win32-input-mode at startup: `?9001h` is in the startup
bytes `probe/recordPty.ms` recorded through each of them. A terminal that answers it sends each
key as a full Win32 key record. libghostty-vt has no `?9001`.
