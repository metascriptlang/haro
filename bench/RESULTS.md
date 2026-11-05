# Server path: in-process vs client/server

`sh scripts/benchServerPath.sh [--reps N] [--flood-mb M] [--no-attach]` builds and runs
`bench/serverPath.ms`. Run it on a host, not on the Mac:
`run-remote.sh --mac --host m1m --cores 4 -- sh scripts/benchServerPath.sh`, and `--host rtx` for Linux.
Each measure prints one `RESULT` line, and a table follows at the end.

What it drives: in-process is a `Term` over a `NativePty`. Client/server is a separate
`serverPath.exe --serve` process running `Server.start` on a temp `HARO_SOCKET`, and a
`ServerLink` + `attach` client that feeds each `Output` into a `RemotePty`-backed `Term` and drains it.
Both modes run on one thread with no Shell actor, no `WorkspaceView` inbox and no frames.
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
