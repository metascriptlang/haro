# Running Haro's server on another machine

`haro-server` is the server half of Haro without a window: it owns the shells and their screens,
so they survive a client that disconnects. It links no window, GPU or webview code and runs on a
machine with no display.

## Over ssh

The window reaches a remote machine with

```sh
ssh <host> ~/.haro/bin/haro-server-<version> proxy
```

`proxy` bridges its stdin and stdout to the user's server on the machine's unix socket, byte for
byte, and starts the server in the background (as `start` does) when none answers. The server
outlives the proxy, the ssh session and its hangup; the end of the proxy's stdin closes only the
proxy's own connection. Who gets in is decided by ssh (keys, or Tailscale SSH).

`<version>` is what `haro-server version` prints first. A window that finds no binary of its
version uploads one into `~/.haro/bin/` under a temporary name and renames it into place, so two
windows uploading at once never run a half-written file:

```sh
mkdir -p ~/.haro/bin && cat > ~/.haro/bin/.haro-server-<version>.$$ \
  && chmod 755 ~/.haro/bin/.haro-server-<version>.$$ \
  && mv -f ~/.haro/bin/.haro-server-<version>.$$ ~/.haro/bin/haro-server-<version>
```

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

`scripts/buildServer.sh` builds `out/haro-server/<os>-<arch>/` for the machine it runs on;
`scripts/serverCheck.sh <binary>` drives a build end to end on a private socket.
