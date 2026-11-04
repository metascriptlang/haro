import { env, execPath } from "std/process";
import { chmod, ensureDir, exists, readFile, readFileBytes, remove } from "std/fs";
import { dirname, join } from "std/fs/path";
import { homeDir, tmpDir } from "std/os";
import { close as closeFd, recvAsync, sendAsync } from "std/net";
import { Connection } from "../server/transport";
import { PROTOCOL_VERSION } from "../server/protocol";
import { Dial, DialError, Failure, offline, refused } from "./link";

when (!windows) {
	@include("./spawn.h");
	@include("./version.h");
	@compile("./spawn.c");

	extern function haroSpawnSocket(joined: cstring, errPath: cstring, ref fd: int32): int32;
	extern function haroReap(pid: int32, ref code: int32): int32;
	extern function haroShutdownWrite(fd: int32): int32;
	extern const HARO_SERVER_VERSION: cstring from "HARO_SERVER_VERSION";
}

const SSH = "ssh";
const REMOTE_DIR = "~/.haro/bin";
const READ_CHUNK: int32 = 64 * 1024;
const UPLOAD_CHUNK: int32 = 1024 * 1024;
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

export function serverName(): string {
	return `haro-server-${serverVersion()}`;
}

export function versionLine(): string {
	return `haro-server ${serverVersion()} protocol ${PROTOCOL_VERSION}`;
}

function answersVersion(out: string): boolean {
	const line = out.trim();
	return line == versionLine() || line.startsWith(`${versionLine()} `);
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

function spawned(args: string[]): Result<Spawned, string> {
	when (windows) {
		return Result.err("ssh hosts are not available on Windows yet");
	} else {
		if (args.some((a: string): boolean => a.includes("\n"))) {
			return Result.err("an ssh argument holds a line break");
		}
		spawns += 1;
		const errPath = join(tmpDir(), `haro-ssh-${Date.now()}-${spawns}.err`);
		let fd: int32 = -1;
		const pid = haroSpawnSocket(args.join("\n"), errPath, fd);
		if (pid <= 0) { return Result.err(`${args[0]} did not start (errno ${-pid})`); }
		return Result.ok({ pid: pid, fd: fd, errPath: errPath });
	}
}

async function reaped(pid: int32, pollMs: int32): Promise<int32> {
	when (windows) {
		return -1;
	} else {
		let code: int32 = -1;
		while (haroReap(pid, code) == 0) { await sleepAsync(pollMs); }
		return code;
	}
}

function lastLine(path: string): string {
	const text = readFile(path);
	const _removed = remove(path);
	if (!text.ok) { return ""; }
	const lines = text.value.split("\n").filter((l: string): boolean => l.trim() != "");
	return lines.length == 0 ? "" : lines[lines.length - 1].trim();
}

export async function run(args: string[], input: Buffer): Promise<Result<Ran, string>> {
	const s = try spawned(args);
	when (!windows) {
		const size = input.length as int32;
		for (let at: int32 = 0; at < size; at += UPLOAD_CHUNK) {
			const end = Math.min(at + UPLOAD_CHUNK, size);
			if (await sendAsync(s.fd, input.slice(at, end)) < 0) { break; }
		}
		const _shut = haroShutdownWrite(s.fd);
	}
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

async function ssh(destination: string, command: string, input: Buffer): Promise<Result<Ran, DialError>> {
	const ran = await run(sshArgs(destination, command), input);
	if (!ran.ok) { return Result.err(refused(ran.error)); }
	if (ran.value.code == SSH_FAILED) { return Result.err(sshFailure(ran.value.err)); }
	return Result.ok(ran.value);
}

async function installed(destination: string): Promise<Result<boolean, DialError>> {
	const ran = try await ssh(destination, `${REMOTE_DIR}/${serverName()} version`, Buffer.alloc(0));
	return Result.ok(ran.code == 0 && answersVersion(ran.out));
}

async function uploaded(
	destination: string,
	uploading: () => void,
): Promise<Result<string, DialError>> {
	const uname = try await ssh(destination, "uname -sm", Buffer.alloc(0));
	const platform = uname.code == 0 ? platformOf(uname.out) : null;
	if (platform === null) {
		return Result.ok(`no Haro server is built for ${uname.out.trim()}`);
	}
	const path = join(serversDir(), `haro-server-${platform}`);
	const bytes = readFileBytes(path);
	if (!bytes.ok) { return Result.ok(`no Haro server for ${platform} beside this app`); }
	uploading();
	const tmp = `${REMOTE_DIR}/.tmp-${Date.now()}`;
	const script = `mkdir -p ${REMOTE_DIR} && cat > ${tmp} && chmod +x ${tmp} && ` +
		`mv ${tmp} ${REMOTE_DIR}/${serverName()}`;
	const put = try await ssh(destination, script, bytes.value);
	if (put.code != 0) { return Result.ok(`the upload failed: ${put.err}`); }
	return Result.ok("");
}

async function linger(s: Spawned): Promise<void> {
	const _code = await reaped(s.pid, LINGER_POLL_MS);
	const _removed = remove(s.errPath);
}

function proxied(destination: string): Result<Connection, DialError> {
	const s = spawned(sshArgs(destination, `${REMOTE_DIR}/${serverName()} proxy`));
	if (!s.ok) { return Result.err(refused(s.error)); }
	const _reaped = linger(s.value);
	return Result.ok(new Connection(s.value.fd));
}

export function sshDial(destination: string): Dial {
	return async (uploading: () => void): Promise<Result<Connection, DialError>> => {
		const dir = controlDir();
		if (!ensureDir(dir).ok || !chmod(dir, OWNER_ONLY_DIR).ok) {
			return Result.err(refused(`${dir} cannot hold ssh's control sockets`));
		}
		if (!(try await installed(destination))) {
			const missing = try await uploaded(destination, uploading);
			if (missing != "") { return Result.err(unkept(destination, missing)); }
			if (!(try await installed(destination))) {
				return Result.err(unkept(destination, "the uploaded Haro server does not answer version"));
			}
		}
		return proxied(destination);
	};
}

test "uname names the server binary built for the host's system" {
	assert platformOf("Linux x86_64\n") == "linux-x64";
	assert platformOf("Linux aarch64") == "linux-arm64";
	assert platformOf("Darwin arm64") == "macos-arm64";
	assert platformOf("Darwin x86_64") == "macos-x64";
	assert platformOf("FreeBSD amd64") === null;
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
