# Running Haro's server on another machine

`haro-server` is the server half of Haro without a window: it owns the shells and their screens,
so they survive a client that disconnects. It links no window, GPU or webview code and runs on a
machine with no display.

## Over ssh

The window reaches a remote machine with

```sh
ssh <host> ~/.haro/server/<version>/haro-server proxy
```

`proxy` bridges its stdin and stdout to the user's server on the machine's unix socket, byte for
byte, and starts the server in the background (as `start` does) when none answers. The server
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
