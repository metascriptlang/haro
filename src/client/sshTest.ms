import { chmod, ensureDir, readDir, readFile, removeAll, writeFile } from "std/fs";
import { dirname, join } from "std/fs/path";
import { tmpDir } from "std/os";
import { env } from "std/process";
import { ScreenFormat } from "../server/protocol";
import { vtBuild } from "../vt/snapshot";
import { writeText } from "../vt/vt";
import { PaneId } from "../workspace/tree";
import { CommandKind } from "../workspace/workspace";
import { DialError, Failure, linkTo } from "./link";
import { FakeServer, startFake } from "./fakeServer";
import { NEEDS_KEY, serverPath, serverVersion, sshDial, versionLine } from "./ssh";

const EXECUTABLE: int32 = 0o755;
const PLATFORMS: string[] = ["linux-x64", "linux-arm64", "macos-arm64", "macos-x64"];

const FAKE_SSH = `#!/bin/sh
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
host="$1"
shift
case "$host" in
needs-password)
	echo "me@needs-password: Permission denied (publickey,password)." >&2
	exit 255;;
unreachable)
	echo "ssh: connect to host unreachable port 22: Connection refused" >&2
	exit 255;;
esac
HOME="$FAKE_REMOTES/$host"
export HOME
mkdir -p "$HOME"
cd "$HOME" || exit 1
exec /bin/sh -c "$*"
`;

const BRIDGE = `import os, socket, sys, threading
s = socket.socket(socket.AF_UNIX)
s.connect(os.environ["FAKE_SOCKET"])
def up():
    while True:
        d = os.read(0, 65536)
        if not d:
            s.shutdown(socket.SHUT_WR)
            return
        s.sendall(d)
threading.Thread(target=up, daemon=True).start()
while True:
    d = s.recv(65536)
    if not d:
        break
    os.write(1, d)
`;

let rigs: int32 = 0;

interface Rig {
	dir: string;
	servers: string;
	remotes: string;
	fake: FakeServer;
	uploads: int32;
}

function must(ok: boolean, what: string): void {
	if (!ok) { throw new Error(`ssh rig: ${what}`); }
}

function written(path: string, text: string): void {
	must(writeFile(path, text).ok && chmod(path, EXECUTABLE).ok, `writing ${path}`);
}

function serverScript(line: string, bridge: string): string {
	return `#!/bin/sh\ncase "$1" in\nversion) echo "${line}";;\n` +
		`proxy) exec python3 ${bridge};;\n*) exit 2;;\nesac\n`;
}

function rig(shipped: boolean): Rig {
	rigs += 1;
	const dir = join(tmpDir(), `haro-ssh-${Date.now()}-${rigs}`);
	const bin = join(dir, "bin");
	const servers = join(dir, "servers");
	const remotes = join(dir, "remotes");
	for (const d of [bin, servers, remotes]) { must(ensureDir(d).ok, d); }
	written(join(bin, "ssh"), FAKE_SSH);
	const bridge = join(dir, "bridge.py");
	must(writeFile(bridge, BRIDGE).ok, bridge);
	if (shipped) {
		for (const p of PLATFORMS) {
			must(ensureDir(join(servers, p)).ok, p);
			written(join(join(servers, p), "haro-server"), serverScript(versionLine("test"), bridge));
		}
	}
	const socket = join(dir, "s.sock");
	const fake = startFake(socket, ScreenFormat.VtBytes);
	if (!fake.ok) { throw new Error(`the fake server did not listen: ${fake.error.toString()}`); }
	const _tab = fake.value.apply({ kind: CommandKind.NewTab });
	fake.value.paneOf(1 as PaneId)?.vt.writeText("over-ssh\r\n");
	const path = env.get("PATH");
	if (!path.startsWith(`${bin}:`)) { const _p = env.set("PATH", `${bin}:${path}`); }
	const _r = env.set("FAKE_REMOTES", remotes);
	const _s = env.set("FAKE_SOCKET", socket);
	const _h = env.set("HARO_SERVERS", servers);
	return { dir: dir, servers: servers, remotes: remotes, fake: fake.value, uploads: 0 };
}

function installed(r: Rig, host: string): string {
	return join(join(r.remotes, host), serverPath());
}

function preinstall(r: Rig, host: string, script: string): void {
	const path = installed(r, host);
	must(ensureDir(dirname(path)).ok, path);
	written(path, script);
}

function answering(r: Rig, line: string): string {
	return serverScript(line, join(r.dir, "bridge.py"));
}

function serverDirEntries(r: Rig, host: string): string[] {
	return readDir(dirname(dirname(installed(r, host))));
}

function done(r: Rig): void {
	r.fake.close();
	const _removed = removeAll(r.dir);
}

async function attachedOver(r: Rig, host: string): Promise<Result<string, DialError>> {
	const got = await linkTo(sshDial(host), (): void => { r.uploads += 1; }, vtBuild(), 80, 24, 10000);
	if (!got.ok) { return Result.err(got.error); }
	const screens = got.value.attached.screens.length;
	got.value.link.detach();
	return Result.ok(`${got.value.attached.layout.tabs.length} tab ${screens} screen`);
}

test "a host whose server answers the version attaches over ssh without an upload" {
	const r = rig(true);
	preinstall(r, "present", answering(r, versionLine("test")));
	const got = await attachedOver(r, "present");
	assert got.ok, got.ok ? "" : got.error.why;
	if (got.ok) { assert got.value == "1 tab 1 screen", got.value; }
	assert r.uploads == 0;
	done(r);
}

test "a host without the server gets the bundle for its system under its version, then attaches" {
	const r = rig(true);
	const got = await attachedOver(r, "bare");
	assert got.ok, got.ok ? "" : got.error.why;
	assert r.uploads == 1;
	const shipped = readFile(installed(r, "bare"));
	assert shipped.ok && shipped.value.includes(versionLine("test"));
	const entries = serverDirEntries(r, "bare");
	assert entries.length == 1 && entries[0] == `${serverVersion()}/`, entries.join(" ");
	done(r);
}

test "an upload into a version directory another upload already made is dropped" {
	const r = rig(true);
	preinstall(r, "raced", "#!/bin/sh\nexit 1\n");
	const got = await attachedOver(r, "raced");
	assert !got.ok;
	if (!got.ok) { assert got.error.failure == Failure.Unkept, got.error.why; }
	assert r.uploads == 1;
	const kept = readFile(installed(r, "raced"));
	assert kept.ok && kept.value.includes("exit 1");
	const entries = serverDirEntries(r, "raced");
	assert entries.length == 1 && entries[0] == `${serverVersion()}/`, entries.join(" ");
	done(r);
}

test "a host whose server of this build speaks another protocol gets this one uploaded over it" {
	const r = rig(true);
	preinstall(r, "stale", answering(r, `haro-server ${serverVersion()} protocol 0 vt test`));
	const got = await attachedOver(r, "stale");
	assert got.ok, got.ok ? "" : got.error.why;
	assert r.uploads == 1;
	const now = readFile(installed(r, "stale"));
	assert now.ok && now.value.includes(versionLine("test"));
	done(r);
}

test "a host no shipped binary fits falls back to an ssh pane that keeps no session" {
	const r = rig(false);
	const got = await attachedOver(r, "elsewhere");
	assert !got.ok;
	if (!got.ok) {
		assert got.error.failure == Failure.Unkept, got.error.why;
		assert got.error.command.startsWith("'ssh' '-t'"), got.error.command;
		assert got.error.command.endsWith("'--' 'elsewhere'"), got.error.command;
	}
	assert r.uploads == 0;
	done(r);
}

test "a host that wants a password is refused, an unreachable one is offline" {
	const r = rig(true);
	const password = await attachedOver(r, "needs-password");
	assert !password.ok;
	if (!password.ok) {
		assert password.error.failure == Failure.Refused;
		assert password.error.why == NEEDS_KEY;
	}
	const gone = await attachedOver(r, "unreachable");
	assert !gone.ok;
	if (!gone.ok) {
		assert gone.error.failure == Failure.Offline;
		assert gone.error.why.includes("Connection refused"), gone.error.why;
	}
	done(r);
}
