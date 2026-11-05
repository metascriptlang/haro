# Running Haro's server on another machine

`haro-server` is the server half of Haro without a window: it owns the shells and their screens,
so they survive a client that disconnects. It links no window, GPU or webview code and runs on a
machine with no display.

## On this machine

The window is always a client of `haro-server`, on this machine as on another one; only the
Windows build still runs its shells inside the window. When nothing answers on the socket, the
window runs `<servers>/<platform>/haro-server start`, where `<servers>` is the app's
`Contents/Resources/servers` (or `servers/` beside the binary, or `HARO_SERVERS`) and `<platform>`
comes from `uname -sm`; with no server there it says which path it looked for. A run from source
builds the bundle first and names it:

```sh
sh scripts/buildServer.sh
HARO_SERVERS="$PWD/out/haro-server" msc run src/app/haro.ms
```

A server left running by an older Haro keeps its shells. A window of the same protocol attaches to
it whatever its build; one of another protocol attaches to nothing and says which program holds
the socket (its path and pid, read from the socket's peer) and how to stop it once its shells are
done, `<that haro-server> stop`. Nothing stops it for the user. The proxy below does the same
check before it bridges, so a remote window gets the same message.

`--smoke`, `--smoke-panes`, `--typing`, `--flood`, `--smoke-attach` and `--smoke-hosts` start a
server of their own on a private `HARO_SOCKET` and stop it when they end. `--shell` exists only
on Windows; elsewhere the server's `command` in `config.ms` picks the shell.

## Over ssh

The window reaches a remote machine with

```sh
ssh <host> ~/.haro/server/<version>/haro-server proxy
```

`proxy` bridges its stdin and stdout to the user's server on the machine's unix socket, byte for
byte after one message that marks the connection remote, and starts the server in the background
(as `start` does) when none answers. The server
outlives the proxy, the ssh session and its hangup; the end of the proxy's stdin closes only the
proxy's own connection. Who gets in is decided by ssh (keys, or Tailscale SSH).

`<version>` is the build both the window and the server were built from, the second word of
`haro-server version`. A window first runs `version` there; when no server answers with its build
and protocol, it streams a gzipped tar of its bundle for the machine's system (the server with the
`assets/` and `metascript/` it reads) and unpacks it under a temporary name, renamed into place
once complete, so a window never runs a half-unpacked server:

```sh
d="$HOME/.haro/server"; mkdir -p "$d"; t=$(mktemp -d "$d/.tmp-XXXXXX")
tar -xzf - -C "$t" && { [ -e "$d/<version>" ] || mv "$t" "$d/<version>"; }
```

When two windows upload at once, the first rename wins and the other's copy is dropped. A server
of the same build that answers with another protocol is replaced.

## Slow links

A remote host's sidebar row shows its smoothed round trip, `rtx · 42 ms`, measured by a ping each
second. On a proxied or tailnet connection the server:

- holds a pane's output for up to 8 ms (never more than half the round trip) once the round trip
  reaches 20 ms, and sends it as one message; output within 50 ms of a keystroke the window sent
  to that pane goes at once;
- deflates a message over 4 KiB when that makes it smaller;
- tells the window when a pane reads a line without echo (a password prompt).

From 30 ms until the round trip falls back to 20 ms, the window draws a printable key typed into a
remote pane at once, underlined after the cursor, and drops it when the pane's output arrives: kept
as the server drew it, or gone when the output differs. After a control key, a wrong guess or a
guess the server never answers, the next key waits for its echo before guesses show again. Nothing
is guessed on the alternate screen or while the pane reads unseen. `remotePrediction` in the config
is `"auto"` (the default), `"on"` at any round trip, or `"off"`.

## Commands

| command | does |
|---|---|
| `run` | serves in the foreground, logging to stderr |
| `start` | serves in the background, logging to `server.log` in the state directory; refused while a server answers |
| `status` | the pid, the listeners and each attached client |
| `stop` | asks the server, through its socket, to close its shells and exit |
| `logs` | prints the log `start` wrote |
| `proxy` | bridges stdin and stdout to the server, starting it when none answers |
| `version` | the binary's version, the protocol version and the libghostty-vt build |

The state directory is `$XDG_STATE_HOME/haro` (else `~/.local/state/haro`) on Linux and
`~/Library/Logs/haro` on macOS; `--state-dir` names another. `HARO_SOCKET` names the socket.
The server reads `~/.config/haro/config.ms` as the window does, with the `assets/` and
`metascript/` directories beside the binary.

## Listening on the tailnet

`--listen-tailnet[=PORT]` on `run` or `start` (or `serverTailnet` in the config) also listens on
the machine's tailnet address, port 7681 unless given. It lets in only the Tailscale user who owns
the machine; a tagged machine or device has no owner, so `--tailnet-allow-identified` is needed to
let in every identified user and tagged device.

## Building

`scripts/buildServer.sh` builds the bundle `out/haro-server/<platform>/` (`linux-x64`,
`linux-arm64`, `macos-arm64`, `macos-x64`) for the machine it runs on;
`scripts/serverCheck.sh <binary>` drives a build end to end on a private socket.
`scripts/buildApp.sh` ships every bundle of its version found under `out/haro-server/` in
`Haro.app/Contents/Resources/servers/<platform>/`, where the window looks for them; `HARO_SERVERS`
names another directory. A bundle is about 36 MB, 11 MB as the gzipped tar a window uploads.

`HARO_REMOTE_HOST=<host> msc test src/client/remoteTest.ms --tests-in-dir` drives the window's ssh
dial against a real host on a private socket: upload, a pane's output, a killed ssh, a redial that
shows the pane again, then `stop` and the removal of the uploaded version. Build it with the
`--passC=-DHARO_SERVER_BUILD=<version>` of the bundles in `HARO_SERVERS`.
