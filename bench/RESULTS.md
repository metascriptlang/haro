# Server path: in-process vs client/server

`sh scripts/benchServerPath.sh [--reps N] [--flood-mb M] [--no-attach] [--flood-only]` builds and runs
`bench/serverPath.ms`. Run it on a host, not on the Mac:
`run-remote.sh --mac --host m1m --cores 4 -- sh scripts/benchServerPath.sh`, and `--host rtx` for Linux.
Each measure prints one `RESULT` line, and a table follows at the end.

What it drives: in-process is a `Term` over a `NativePty`. Client/server is a separate
`serverPath.exe --serve` process running `Server.start` on a temp `HARO_SOCKET`, and a
`ServerLink` + `attach` client that feeds each `Output` into a `RemotePty`-backed `Term` and drains it.
Both modes run on one thread with no Shell actor, no `WorkspaceView` inbox and no frames.
The client joins outputs through `src/client/feeds.ms` and resets a pane on a mid-stream Screen
the way `Shell.reseed` does. After a reseed, an echo counts once the VT shows the key at the cursor.
`*_split` rows time each client echo up to the start of the read batch that carries it (`to_client`),
beside the client thread's busy share and its longest batch.
So the A/B difference is the server, the transport and the second parse.
`--flood-only` runs just the flood rows, so a profiler can sample `serverPath.exe --serve` under a flood.
The bench starts the server with `HARO_SERVER_TRACE=<file>`. The server then stamps each key's arrival
and pty write, and each echo-sized output's pty read, hand-off to the connection and socket write.
The `*_stages` rows split client echo into `to_server`, `to_pty`, `to_read`, `to_hand`,
`to_socket`, `to_client` and `parse`, and count jumps. A negative `to_client` means the server loop
saw the send complete late, and `to_socket` overstates by the same amount.
Echo is timed from the write until the client VT has parsed the echoed byte of `cat` under
`stty raw -echo`, 500 keys, 5 ms apart. CPU is `getrusage(RUSAGE_SELF)`. Server CPU is the
server's lifetime CPU minus that of a server that only starts, attaches and stops.

## Baseline, src 28b1017 (tree d641187), bench 1391b4e, 3 reps, 200 MB flood

Cells are the median [min..max] over the reps. "cut" means the server logged
`a client fell too far behind and was cut` and closed the link.

| measure | macOS in-process | macOS client/server | Linux in-process | Linux client/server |
|---|---|---|---|---|
| echo idle p50 ms | 0.08 [0.08..0.11] | 0.24 [0.24..0.25] | 0.16 [0.15..0.16] | 0.14 [0.13..0.15] |
| echo idle p99 ms | 0.94 [0.78..1.36] | 1.12 [1.07..3.18] | 0.29 [0.17..0.31] | 0.24 [0.20..0.28] |
| echo idle p99.9 ms (pooled, n=1500) | 6.33 | 8.67 | 0.51 | 0.60 |
| echo under `cat` loop, p50 / p99.9 ms | 0.72 / 1.11 | cut after 6-11 keys; 308 / 769 before it | 0.10 / 6.77 | cut before the first key |
| echo under `yes`, p50 / p99.9 ms | 8.70 / 9.52 | not reached (cut earlier) | 0.10 / 9.89 | not reached |
| ^C during `yes` until prompt, ms | 18.7 [17.5..19.3] | 537 [536..549] | 4.7 [0.6..5.1] | 147 [100..183] |
| flood MB/s | 90.0 [89.2..94.5] | 72.0 (rep 1); reps 2-3 cut at 92.8 / 0.4 MB | 219 [194..248] | cut every rep at 4.4-17.9 MB, ~10 MB/s before the cut |
| client CPU ms/MB | 12.2 (whole process) | 9.3 | 7.6 (whole process) | - |
| server CPU ms/MB | - | 18.1 | - | - |
| pty-only read loop MB/s (ceiling) | 102 [96..168] | | 193 [192..204] | |
| attach, empty pane: ms, bytes | | Native 11.7, 1247 B; VtBytes 12.4, 237 B | | Native 10.4, 1235 B; VtBytes 10.3, 225 B |
| attach after `seq 1 50000`: ms, bytes | | Native 15.1, 82 KB; VtBytes 27.2, 70 KB | | Native 11.6, 80 KB; VtBytes 17.0, 68 KB |

Hosts: m1m (msc v0.4.0, `msc web 177f04c27`) and rtx (msc v0.4.0, `msc 56ad1fdf80f`).

Read with care:
- The VT keeps 10,000 lines (`SCROLLBACK_LINES`, src/vt/terminal.ms), so the 50k-line attach carries the last 10k lines.
- Attach time includes `attach`'s 5 ms poll (`POLL_MS`, src/client/link.ms), so about 10 ms of it is the poll floor.
- In-process echo under `yes` sits at the 8 ms drain budget on macOS (`DRAIN_BUDGET_MS`, src/controller/term.ms).
- With 500 keys per rep, the p99.9 of one rep is its max. The pooled value uses 1500 keys.

## After the server and client fixes: merge a097bec (tree 246dc08) on m1m, 81970db (tree afb9301) on rtx, 3 reps

Targets: client/server adds < 1 ms echo at p50 and < 8 ms at p99.9, and flood within 10% of in-process.

| measure | macOS in-process | macOS client/server | Linux in-process | Linux client/server |
|---|---|---|---|---|
| echo idle p50 / p99.9 ms (pooled) | 0.08 / 6.68 | 0.38 / 10.17 | 0.16 / 0.29 | 0.20 / 0.43 |
| echo under `cat` loop p50 / p99.9 ms | 0.74 / 1.10 | 0.14 / 0.29, no reseed (see below) | 0.09 / 5.75 | 0.74 / 77.9, 77-137 reseeds per 500 keys |
| echo under `yes` p50 / p99.9 ms | 8.59 / 9.57 | 1124 / 2648, 199-252 reseeds | 0.10 / 0.87 | 0.87 / 33.4, no reseed |
| ^C during `yes` until prompt, ms | 18.1 [17.6..18.9] | 68 [37..170] | 5.7 [5.6..5.8] | 6.0 [5.8..16.8] |
| flood MB/s | 127 [117..144] | 88.9 [76.9..95.7] | 196 [195..196] | 172.5 [168..182] |
| CPU ms/MB | 9.2 | client 5.8, server 16.9 | 8.7 | client 2.2, server 8.9 |
| pty-only ceiling MB/s | 101 [92..171] | | 197 [196..288] | |
| attach after `seq 1 50000`: ms, Native / VtBytes | | 15.3 / 34.8 | | 12.2 / 13.7 |

No link was cut on either host.

Where loaded echo time goes. In every loaded run, `to_client` p99.9 equals the echo p99.9 (Linux `cat`
77.91 / 77.91; macOS `yes` 2647.5 / 2647.7), so the time is spent before the client handles the read.
Meanwhile the client is busy only 36-41% on Linux and 2% on macOS under `yes`, and its longest batch
is 6-15 ms on Linux, so client queueing explains at most one batch of it. The rest is in the server or the
socket before the client reads it.

Drain-budget probe: `DRAIN_BUDGET_MS` 8 → 1 in src/controller/term.ms, uncommitted, rtx, 2 reps, 8 MB.
- Client echo p99.9 fell from 77.9 to 27.2 ms under `cat` and from 33.4 to 17.5 ms under `yes`.
- Reseeds fell to 0, while `cat` p50 rose to 1.9 ms.
- So a flood pane's drain holding the next pump explains part of the tail, not all of it.

Not explained:
- macOS client echo under `cat` beats in-process, with 1-batch-sized reads (longest 0.14 ms). That
  suggests little of the `cat` flood reaches the client there; not traced.
- On macOS under `yes`, nearly every key comes back inside a reseed after about 1 s.

## Per-pane delivery, direct input and sliced drains: 7b62523, 3 reps, 200 MB flood

Before (a097bec, 1 rep, 16 MB), stage p50 / p99.9 ms:
- Linux `cat`: to_server 0.15/7.1, to_pty 0.20/8.4, to_read 0.07/10.4, to_hand 0.05/1.9, to_socket 0.37/97.3.
  16 jumps; echo p99.9 120 ms.
- macOS `yes`: to_server 2.0/9.6, to_pty 8.6/9.6, to_read 8.6/10.0, to_socket 1659/5385.
  216 jumps; echo p50 1099 ms.
- Socket write held the echo behind a whole flood queue, and on macOS the 8 KiB default socket
  buffer turned that into jumps.

What changed:
- Each pane drains and delivers on its own. A pane is held while every keeping-up client already has
  256 KiB of it queued (`FLOW_BYTES`), and a client 250 ms without send progress stops counting.
- Input goes straight to the pty writer.
- A drain is a slice of at most 1 ms or 64 KiB, read 16 KiB at a time.
- macOS asks for 1 MiB socket buffers. A 256 KiB buffer gave `yes` p99.9 17.8 ms against 6.6 ms (1 rep).
  Linux keeps its default, because there 1 MiB let 1.5 MiB of flood sit ahead of another pane's echo.

| measure | macOS in-process | macOS client/server | Linux in-process | Linux client/server |
|---|---|---|---|---|
| echo idle p50 / p99.9 ms (pooled) | 0.08 / 8.79 | 0.25 / 14.79 | 0.16 / 0.39 | 0.21 / 0.43 |
| echo under `cat` p50 / p99.9 ms | 0.72 / 1.09 | 0.15 / 0.30 | 0.09 / 2.69 | 0.79 / 2.56 |
| echo under `yes` p50 / p99.9 ms | 8.62 / 9.59 | 5.23 / 7.00 | 0.09 / 1.36 | 0.42 / 2.18 |
| ^C during `yes` until prompt, ms | 18.4 [18.3..19.4] | 23.8 [23.6..23.8] | 5.5 [4.9..5.6] | 5.8 [5.4..5.8] |
| flood MB/s | 93.3 [93.1..146.7] | 78.2 [77.0..90.2] | 200.7 [194.3..202.0] | 197.2 [196.5..199.3] |
| CPU ms/MB | 11.7 | client 6.2, server 18.8 | 8.2 | client 3.1, server 8.8 |
| pty-only ceiling MB/s | 98 [97..98] | | 194 [193..198] | |
| attach after `seq 1 50000`, Native / VtBytes ms | | 16.0 / 28.4 | | 13.0 / 18.2 |

Hosts: m1m at e4f6043 (the macOS code is the same at 7b62523), rtx at 7b62523.
Jumps and reseeds were 0 in every run.
Stage p50 under `yes` was 0.82 to_server, 1.47 to_read, 1.29 to_hand and 1.46 to_socket on macOS,
against 0.12 / 0.16 / 0.16 for to_read / to_hand / to_socket on Linux.

What is still open:
- macOS idle p99.9 is noisy. Per rep it was 14.2, 3.6 and 49.1 ms. The 49 ms echo spent 46 ms in
  `to_server`, between the client's write and the server's read, on an idle machine. The other tail echoes
  spent 12-13 ms in `to_read`, the pty's own echo; in-process shows the same 9 ms tail.
- Flood on macOS is 16% below in-process. In-process varies 89-147 MB/s from run to run, while
  client/server holds at 77-82 MB/s. The server main thread is the stage holding it: about 82% busy,
  17% in the VT parse and the rest in per-hop runtime work. That work is kqueue register and unregister
  on every socket recv and send (about 10%), completion-queue pipe writes for the Shell actor's replies
  (about 8%), the wake socket and `ptyWait`.
  Probes that did not move it (2-3 reps, 400 MB):
  - `FLOW_BYTES` at 1 MiB: 78-82 MB/s.
  - A wake only when the pty queue empties, plus `ptyWait(0)` without a timed wait: 77.7-79.6.
  - A 4 ms / 256 KiB slice: 73-92.

## Remote: a delay relay in place of the network, 3 reps

`sh scripts/benchServerPath.sh --remote --reps 3 --flood-mb 50` runs the client through a fake `ssh`
whose transport is `serverPath.exe --relay`, a unix-socket relay. The relay delays each direction by
half the RTT, and holds at most 2 MiB in flight per direction, the size of ssh's channel window.
The real dial path runs (`ssh host … haro-server proxy`, `Proxied`, then pings), so the server paces and packs
as it would for a remote client. The plain rows start the server with `--no-pack`.
Echo is 100 keys typed into `cat` under `stty raw -echo`, with prediction off, then a `\r`, then 100 with it on.
With prediction on, a key counts once it is drawn, from the overlay or from the VT.

| measure | Linux (rtx) | macOS (m1m) |
|---|---|---|
| echo p50, prediction off, 50 / 100 / 300 ms RTT | 50.9 / 101.8 / 300.7 | 52.2 / 102.3 / 302.3 |
| echo p50, prediction on, any RTT | 0.01 | 0.07-0.08 |
| echo max, prediction on | one RTT, the first key of an epoch | same |
| keys predicted / misses of 100 | 98 / 0 | 98 / 0 |
| flood MB/s at 100 ms, repeated line, packed / plain | 109.8 / 37.2 | 84.4 / 36.6 |
| wire MB for 50 MB, repeated line, packed / plain | 0.40 / 53.1 | 1.29 / 53.1 |
| flood MB/s at 100 ms, `seq`, packed / plain | 23.8 / 24.2 | 39.1 / 34.0 |
| wire MB for 50 MB, `seq`, packed / plain | 12.35 / 59.1 | 3.08 / 57.3 |
| server CPU ms/MB, `seq`, packed / plain | 68 / 69 | 32 / 27 |
| attach at 100 ms, empty / `seq 1 50000`, packed, ms | 221 / 226 | 276 / 281 |
| attach wire bytes after `seq 1 50000`, packed / plain | 19.8 K / 80.1 K | 19.9 K / 82.1 K |

Hosts: rtx and m1m at 1617807 plus the snapshot flush of 7e67379.
Reading the rows:
- The repeated line is the best case for deflate, and the relay window makes the plain run
  wire bound. The `seq` file is the honest case: on Linux the client's parse (about 28 ms/MB) bounds it,
  so packing saves 4.8x the bytes for the same rate; on macOS it saves 18x and runs 15% faster.
- Deflate at level 1 costs the server about 1-5 ms/MB on top of the drain; on Linux the
  difference is inside the noise.
- Attach is two RTTs plus spawning the fake `ssh` and the proxy; packing shrinks the screen 4x.

Local path: the client/server rows of the same runs match the table above.
Linux flood 189 MB/s against 197, echo idle 0.20 / 0.43, under `cat` 0.81 / 2.45, under `yes` 0.41 / 2.94,
attach Native / VtBytes 11.4 / 12.4 ms. macOS flood 78.0 against 78.2, echo idle 0.24 / 6.41,
under `cat` 0.14 / 0.41, under `yes` 5.19 / 9.16, attach 14.0 / 18.0 ms.
