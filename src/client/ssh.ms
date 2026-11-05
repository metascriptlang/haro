import { env, execPath } from "std/process";
import { chmod, ensureDir, exists, readFile, remove } from "std/fs";
import { dirname, join } from "std/fs/path";
import { homeDir, tmpDir } from "std/os";
import { close as closeFd, recvAsync } from "std/net";
import { Connection } from "../server/transport";
import { PROTOCOL_VERSION } from "../server/protocol";
import { Dial, DialError, Failure, offline, refused } from "./link";

when (!windows) {
	@include("spawn.h");
	@include("sys/socket.h");
	@include("sys/wait.h");
	@include("fcntl.h");
	@include("unistd.h");
	@include("../server/version.h");

	extern struct SpawnFiles from "posix_spawn_file_actions_t" {}
	extern struct SpawnAttr from "posix_spawnattr_t" {}
	extern const AF_UNIX: int32 from "AF_UNIX";
	extern const SOCK_STREAM: int32 from "SOCK_STREAM";
	extern const SHUT_WR: int32 from "SHUT_WR";
	extern const F_SETFD: int32 from "F_SETFD";
	extern const FD_CLOEXEC: int32 from "FD_CLOEXEC";
	extern const O_WRONLY: int32 from "O_WRONLY";
	extern const O_CREAT: int32 from "O_CREAT";
	extern const O_TRUNC: int32 from "O_TRUNC";
	extern const WNOHANG: int32 from "WNOHANG";
	extern const HARO_SERVER_VERSION: cstring from "HARO_SERVER_VERSION";
	extern function socketpair(domain: int32, kind: int32, protocol: int32, pair: Ptr<int32>): int32;
	extern function shutdown(fd: int32, how: int32): int32;
	extern function fcntl(fd: int32, command: int32, arg: int32): int32;
	extern function closeRaw(fd: int32): int32 from "close";
	extern function waitpid(pid: int32, status: Ptr<int32>, options: int32): int32;
	extern function exitedNormally(status: int32): int32 from "WIFEXITED";
	extern function exitStatus(status: int32): int32 from "WEXITSTATUS";
	extern function signalled(status: int32): int32 from "WIFSIGNALED";
	extern function termSignal(status: int32): int32 from "WTERMSIG";
	extern function posix_spawn_file_actions_init(files: Ptr<SpawnFiles>): int32;
	extern function posix_spawn_file_actions_destroy(files: Ptr<SpawnFiles>): int32;
	extern function posix_spawn_file_actions_adddup2(
		files: Ptr<SpawnFiles>,
		fd: int32,
		to: int32,
	): int32;
	extern function posix_spawn_file_actions_addopen(
		files: Ptr<SpawnFiles>,
		fd: int32,
		path: cstring,
		flags: int32,
		mode: int32,
	): int32;
	extern function posix_spawnattr_init(attr: Ptr<SpawnAttr>): int32;
	extern function posix_spawnattr_destroy(attr: Ptr<SpawnAttr>): int32;
	extern function posix_spawnattr_setflags(attr: Ptr<SpawnAttr>, flags: int16): int32;
	extern function posix_spawnp(
		pid: Ptr<int32>,
		file: cstring,
		files: Ptr<SpawnFiles>,
		attr: Ptr<SpawnAttr>,
		argv: Ptr<Ptr<char>>,
		envp: Ptr<Ptr<char>>,
	): int32;
}

when (macos) {
	@include("crt_externs.h");

	extern const POSIX_SPAWN_CLOEXEC_DEFAULT: int16 from "POSIX_SPAWN_CLOEXEC_DEFAULT";
	extern function nsEnviron(): Ptr<Ptr<Ptr<char>>> from "_NSGetEnviron";

	function environment(): Ptr<Ptr<char>> {
		return nsEnviron()[0];
	}

	function spawnFlags(attr: Ptr<SpawnAttr>): int32 {
		return posix_spawnattr_setflags(attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
	}
} else when (!windows) {
	extern const environ: Ptr<Ptr<char>> from "environ";

	function environment(): Ptr<Ptr<char>> {
		return environ;
	}

	function spawnFlags(attr: Ptr<SpawnAttr>): int32 {
		return 0;
	}
}

const SSH = "ssh";
const READ_CHUNK: int32 = 64 * 1024;
const REAP_POLL_MS: int32 = 10;
const LINGER_POLL_MS: int32 = 500;
const OWNER_ONLY_DIR: int32 = 0o700;
const SSH_FAILED: int32 = 255;
export const NEEDS_KEY = "ssh needs a key or Tailscale SSH";

let spawns: int32 = 0;

export struct Ran {
	code: int32;
	out: string;
	err: string;
}

struct Spawned {
	pid: int32;
	fd: int32;
	errPath: string;
}

export function serverVersion(): string {
	when (windows) {
		return "dev";
	} else {
		return HARO_SERVER_VERSION as string;
	}
}

export function serverPath(): string {
	return `.haro/server/${serverVersion()}/haro-server`;
}

function serverCommand(): string {
	return `~/${quoted(serverPath())}`;
}

export struct ServerVersion {
	build: string;
	protocol: uint32;
	vt: string;
}

export function versionOf(out: string): ServerVersion | null {
	const words = out.trim().split(" ");
	if (words.length != 6 || words[0] != "haro-server" || words[2] != "protocol" || words[4] != "vt") {
		return null;
	}
	const protocol = parseInt(words[3]);
	if (`${protocol}` != words[3] || protocol < 0) { return null; }
	return { build: words[1], protocol: protocol as uint32, vt: words[5] };
}

export function versionLine(vt: string): string {
	return `haro-server ${serverVersion()} protocol ${PROTOCOL_VERSION} vt ${vt}`;
}

function answersVersion(out: string): boolean {
	const v = versionOf(out);
	return v !== null && v.build == serverVersion() && v.protocol == PROTOCOL_VERSION;
}

function controlDir(): string {
	return join(join(homeDir(), ".haro"), "ssh");
}

function sshOptions(): string[] {
	return [
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=10",
		"-o", "ControlMaster=auto",
		"-o", `ControlPath=${join(controlDir(), "%C")}`,
		"-o", "ControlPersist=300",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=3",
	];
}

export function sshArgs(destination: string, command: string): string[] {
	return [SSH, ...sshOptions(), "--", destination, command];
}

function quoted(arg: string): string {
	return `'${arg.replaceAll("'", "'\\''")}'`;
}

export function paneCommand(destination: string): string {
	const args = [SSH, "-t", ...sshOptions(), "--", destination];
	return args.map(quoted).join(" ");
}

export function serversDir(): string {
	const chosen = env.get("HARO_SERVERS");
	if (chosen != "") { return chosen; }
	const beside = join(dirname(execPath), "servers");
	const bundled = join(join(join(dirname(execPath), ".."), "Resources"), "servers");
	return exists(beside) || !exists(bundled) ? beside : bundled;
}

export function platformOf(uname: string): string | null {
	return match (uname.trim()) {
		"Linux x86_64" => "linux-x64",
		"Linux aarch64" | "Linux arm64" => "linux-arm64",
		"Darwin arm64" => "macos-arm64",
		"Darwin x86_64" => "macos-x64",
		_ => null,
	};
}

when (!windows) {
	function socketPair(): [int32, int32] | null {
		let pair: Vec<int32> = [-1, -1];
		if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair as Span<int32> as Ptr<int32>) != 0) {
			return null;
		}
		const _parent = fcntl(pair[0], F_SETFD, FD_CLOEXEC);
		const _child = fcntl(pair[1], F_SETFD, FD_CLOEXEC);
		return [pair[0], pair[1]];
	}

	function spawnedOn(args: string[], child: int32, errPath: string): int32 {
		let files: SpawnFiles = {};
		let attr: SpawnAttr = {};
		const fileActions = files as Ptr<SpawnFiles>;
		const attributes = attr as Ptr<SpawnAttr>;
		let rc = posix_spawn_file_actions_init(fileActions);
		if (rc != 0) { return -rc; }
		rc = posix_spawnattr_init(attributes);
		if (rc != 0) {
			const _files = posix_spawn_file_actions_destroy(fileActions);
			return -rc;
		}
		rc = posix_spawn_file_actions_adddup2(fileActions, child, 0);
		if (rc == 0) { rc = posix_spawn_file_actions_adddup2(fileActions, child, 1); }
		if (rc == 0) {
			rc = posix_spawn_file_actions_addopen(
				fileActions,
				2,
				errPath,
				O_WRONLY | O_CREAT | O_TRUNC,
				0o600,
			);
		}
		if (rc == 0) { rc = spawnFlags(attributes); }
		let argv: Vec<Ptr<char> | null> = [];
		for (const a of args) { argv.push((a as cstring) as Ptr<char>); }
		argv.push(null);
		let pid: Vec<int32> = [0];
		if (rc == 0) {
			rc = posix_spawnp(
				pid as Span<int32> as Ptr<int32>,
				args[0],
				fileActions,
				attributes,
				argv as Span<Ptr<char> | null> as Ptr<Ptr<char>>,
				environment(),
			);
		}
		const _files = posix_spawn_file_actions_destroy(fileActions);
		const _attr = posix_spawnattr_destroy(attributes);
		return rc == 0 ? pid[0] : -rc;
	}
}

function spawned(args: string[]): Result<Spawned, string> {
	when (windows) {
		return Result.err("ssh hosts are not available on Windows yet");
	} else {
		if (args.some((a: string): boolean => a.includes("\n") || a.includes("\0"))) {
			return Result.err("an ssh argument holds a line break or a NUL");
		}
		spawns += 1;
		const errPath = join(tmpDir(), `haro-ssh-${Date.now()}-${spawns}.err`);
		const pair = socketPair();
		if (pair === null) { return Result.err("no socket pair for ssh"); }
		const pid = spawnedOn(args, pair[1], errPath);
		const _child = closeRaw(pair[1]);
		if (pid <= 0) {
			const _parent = closeRaw(pair[0]);
			return Result.err(`${args[0]} did not start (errno ${-pid})`);
		}
		return Result.ok({ pid: pid, fd: pair[0], errPath: errPath });
	}
}

async function reaped(pid: int32, pollMs: int32): Promise<int32> {
	when (windows) {
		return -1;
	} else {
		let status: Vec<int32> = [0];
		while (true) {
			const got = waitpid(pid, status as Span<int32> as Ptr<int32>, WNOHANG);
			if (got < 0) { return -1; }
			if (got > 0) { break; }
			await sleepAsync(pollMs);
		}
		if (exitedNormally(status[0]) != 0) { return exitStatus(status[0]); }
		if (signalled(status[0]) != 0) { return 128 + termSignal(status[0]); }
		return -1;
	}
}

function lastLine(path: string): string {
	const text = readFile(path);
	const _removed = remove(path);
	if (!text.ok) { return ""; }
	const lines = text.value.split("\n").filter((l: string): boolean => l.trim() != "");
	return lines.length == 0 ? "" : lines[lines.length - 1].trim();
}

export async function run(args: string[]): Promise<Result<Ran, string>> {
	const s = try spawned(args);
	when (!windows) { const _shut = shutdown(s.fd, SHUT_WR); }
	let out = "";
	while (true) {
		const chunk = await recvAsync(s.fd, READ_CHUNK);
		if (chunk.length == 0) { break; }
		out += chunk.asString();
	}
	closeFd(s.fd);
	const code = await reaped(s.pid, REAP_POLL_MS);
	return Result.ok({ code: code, out: out, err: lastLine(s.errPath) });
}

export function sshFailure(err: string): DialError {
	if (err.includes("Permission denied")) { return refused(NEEDS_KEY); }
	if (err.includes("Host key verification failed")) { return refused(err); }
	return offline(err == "" ? "ssh could not reach the host" : err);
}

function unkept(destination: string, why: string): DialError {
	return { failure: Failure.Unkept, why: why, command: paneCommand(destination) };
}

async function ssh(args: string[]): Promise<Result<Ran, DialError>> {
	const ran = await run(args);
	if (!ran.ok) { return Result.err(refused(ran.error)); }
	if (ran.value.code == SSH_FAILED) { return Result.err(sshFailure(ran.value.err)); }
	return Result.ok(ran.value);
}

enum Installed {
	Current,
	Stale,
	Missing,
}

async function installed(destination: string): Promise<Result<Installed, DialError>> {
	const ran = try await ssh(sshArgs(destination, `${serverCommand()} version`));
	if (answersVersion(ran.out)) { return Result.ok(Installed.Current); }
	return Result.ok(versionOf(ran.out) === null ? Installed.Missing : Installed.Stale);
}

function unpackScript(replace: boolean): string {
	return `set -e; d="$HOME/.haro/server"; v=${quoted(serverVersion())}; mkdir -p "$d"; ` +
		`t=$(mktemp -d "$d/.tmp-XXXXXX"); trap 'rm -rf "$t" "$d/$v/\${t##*/}"' EXIT; ` +
		`tar -xzf - -C "$t"; ${replace ? 'rm -rf "$d/$v"; ' : ""}[ -e "$d/$v" ] || mv "$t" "$d/$v"`;
}

async function uploaded(
	destination: string,
	replace: boolean,
	uploading: () => void,
): Promise<Result<string, DialError>> {
	const uname = try await ssh(sshArgs(destination, "uname -sm"));
	const platform = uname.code == 0 ? platformOf(uname.out) : null;
	if (platform === null) {
		return Result.ok(`no Haro server is built for ${uname.out.trim()}`);
	}
	const bundle = join(serversDir(), platform);
	if (!exists(join(bundle, "haro-server"))) {
		return Result.ok(`no Haro server for ${platform} beside this app`);
	}
	uploading();
	const streamed = 'COPYFILE_DISABLE=1 tar -czf - -C "$0" . | "$@"';
	const unpack = `sh -c ${quoted(unpackScript(replace))}`;
	const put = try await ssh(["/bin/sh", "-c", streamed, bundle, ...sshArgs(destination, unpack)]);
	if (put.code != 0) { return Result.ok(`the upload failed: ${put.err}`); }
	return Result.ok("");
}

async function linger(s: Spawned): Promise<void> {
	const _code = await reaped(s.pid, LINGER_POLL_MS);
	const _removed = remove(s.errPath);
}

function proxyCommand(socket: string | null): string {
	if (socket === null) { return `${serverCommand()} proxy`; }
	const place = `HARO_SOCKET=${quoted(socket)}`;
	return `env ${place} ${serverCommand()} proxy --state-dir ${quoted(dirname(socket))}`;
}

function proxied(destination: string, socket: string | null): Result<Connection, DialError> {
	const s = spawned(sshArgs(destination, proxyCommand(socket)));
	if (!s.ok) { return Result.err(refused(s.error)); }
	const _reaped = linger(s.value);
	return Result.ok(new Connection(s.value.fd));
}

export function sshDial(destination: string, socket: string | null = null): Dial {
	return async (uploading: () => void): Promise<Result<Connection, DialError>> => {
		const dir = controlDir();
		if (!ensureDir(dir).ok || !chmod(dir, OWNER_ONLY_DIR).ok) {
			return Result.err(refused(`${dir} cannot hold ssh's control sockets`));
		}
		const found = try await installed(destination);
		if (found != Installed.Current) {
			const missing = try await uploaded(destination, found == Installed.Stale, uploading);
			if (missing != "") { return Result.err(unkept(destination, missing)); }
			if ((try await installed(destination)) != Installed.Current) {
				return Result.err(unkept(destination, "the uploaded Haro server does not answer version"));
			}
		}
		return proxied(destination, socket);
	};
}

test "uname names the server binary built for the host's system" {
	assert platformOf("Linux x86_64\n") == "linux-x64";
	assert platformOf("Linux aarch64") == "linux-arm64";
	assert platformOf("Darwin arm64") == "macos-arm64";
	assert platformOf("Darwin x86_64") == "macos-x64";
	assert platformOf("FreeBSD amd64") === null;
}

test "the version line names the build and the protocol a window compares" {
	const v = versionOf("haro-server abc123 protocol 1 vt 1.2.0-dev+7a1\n");
	assert v !== null;
	if (v !== null) {
		assert v.build == "abc123" && v.protocol == 1 && v.vt == "1.2.0-dev+7a1";
	}
	assert versionOf("haro-server abc123 protocol one vt x") === null;
	assert versionOf("haro-server abc123 protocol 1") === null;
	assert versionOf(versionLine("x")) !== null;
}

test "ssh that asks for a password is refused, an unreachable host is offline" {
	const password = sshFailure("me@box: Permission denied (publickey,password).");
	assert password.failure == Failure.Refused && password.why == NEEDS_KEY;
	assert sshFailure("Host key verification failed.").failure == Failure.Refused;
	const gone = sshFailure("ssh: connect to host box port 22: Connection refused");
	assert gone.failure == Failure.Offline;
	assert gone.why == "ssh: connect to host box port 22: Connection refused";
}

test "the fallback pane runs ssh with every argument quoted for the shell" {
	const command = paneCommand("me@box");
	assert command.startsWith("'ssh' '-t' '-o' 'BatchMode=yes'");
	assert command.endsWith("'--' 'me@box'");
	assert quoted("it's") == "'it'\\''s'";
}
