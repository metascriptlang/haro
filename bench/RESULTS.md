# Server path: in-process vs client/server

`sh scripts/benchServerPath.sh [--reps N] [--flood-mb M] [--no-attach]` builds and runs
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
