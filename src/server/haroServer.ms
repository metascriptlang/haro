import { ensureDir, exists, fileSize, isDir, readFile, rename } from "std/fs";
import { dirname, join } from "std/fs/path";
import { homeDir } from "std/os";
import { ChildStream, argv, cwd, env, execPath, exit, spawn as spawnProcess } from "std/process";
import { defaults, dividerCellsOf } from "../config/config";
import { configPath, load } from "../config/source";
import { Invocation, USAGE, Verb, parseArgs, runArgs, tailnetChoice } from "./cli";
import { answeringPid, askStatus, askStop, nobody } from "./control";
import { PROTOCOL_VERSION } from "./protocol";
import { proxy } from "./proxy";
import { serveOn } from "./serve";
import { vtBuild } from "../vt/vt";
import { socketPath } from "./transport";

@include("./version.h");

extern const HARO_SERVER_VERSION: cstring from "HARO_SERVER_VERSION";

when (!windows) {
	@include("unistd.h");

	extern function setsid(): int32;
}

const LOG_NAME = "server.log";
const LOG_ROTATE_BYTES: number = 8 * 1024 * 1024;
const START_WAIT_MS: int32 = 10000;
const START_POLL_MS: int32 = 50;
const LOG_TAIL_LINES: int32 = 20;
const SHELL_WAIT_MS: int32 = 5000;

function say(line: string): void {
	console.log(line);
}

function logged(line: string): void {
	console.error(line);
}

function stateDirOf(inv: Invocation): string {
	const chosen = inv.stateDir;
	if (chosen !== null) { return chosen; }
	when (macos) {
		return `${homeDir()}/Library/Logs/haro`;
	} else {
		const xdg = env.get("XDG_STATE_HOME");
		return `${xdg != "" ? xdg : `${homeDir()}/.local/state`}/haro`;
	}
}

function resourceRoot(): string {
	const beside = dirname(execPath);
	return execPath != "" && isDir(`${beside}/assets`) ? beside : cwd();
}

async function run(inv: Invocation): Promise<int32> {
	if (inv.detach) {
		when (!windows) { const _session = setsid(); }
	}
	const root = resourceRoot();
	const assets = `${root}/assets`;
	const bundled = `${root}/metascript`;
	const metascript = isDir(bundled) ? bundled : `${homeDir()}/.metascript`;
	const path = configPath();
	let config = defaults();
	const loaded = load(path, `${assets}/haro`, metascript);
	if (loaded.ok) {
		config = loaded.value.config;
	} else {
		logged(`haro server: ${path} not used, defaults instead: ${loaded.error}`);
	}
	let startIn = config.startDirectory(false, homeDir());
	if (startIn !== null && !isDir(startIn)) {
		logged(`haro server: workingDirectory ${startIn} does not exist, so shells start in ${cwd()}`);
		startIn = null;
	}
	return await serveOn({
		config: config,
		shellScripts: config.shellIntegration ? `${assets}/shell` : null,
		startIn: startIn,
		dividerCells: dividerCellsOf(config),
	}, tailnetChoice(inv, config), logged);
}

function rotated(log: string): void {
	if (exists(log) && fileSize(log) > LOG_ROTATE_BYTES) { const _moved = rename(log, `${log}.1`); }
}

function lastLines(text: string, count: int32): string {
	const lines = text.trimEnd().split("\n");
	return lines.slice(Math.max(0, lines.length - count)).join("\n");
}

async function start(inv: Invocation, say: (line: string) => void): Promise<int32> {
	const socket = socketPath();
	const running = await answeringPid(socket);
	if (running !== null) {
		say(`a Haro server already answers at ${socket} (pid ${running})`);
		return 1;
	}
	if (execPath == "") {
		say("the OS does not report this program's path, so it cannot start itself");
		return 1;
	}
	const dir = stateDirOf(inv);
	if (!ensureDir(dir).ok) {
		say(`cannot create the state directory ${dir}`);
		return 1;
	}
	const log = join(dir, LOG_NAME);
	rotated(log);
	const detach = 'log=$1; shift; "$@" </dev/null >>"$log" 2>&1 &';
	const launched = spawnProcess("/bin/sh", ["-c", detach, "haro-server", log, execPath, ...runArgs(inv)]);
	if (!launched.ok) {
		say(`starting ${execPath} failed: ${launched.error.message}`);
		return 1;
	}
	const shell = launched.value;
	const _drained = shell.read(ChildStream.Stdout, SHELL_WAIT_MS);
	const _waited = shell.wait(SHELL_WAIT_MS);
	shell.close();
	const deadline = Date.now() + START_WAIT_MS;
	while (Date.now() < deadline) {
		const pid = await answeringPid(socket);
		if (pid !== null) {
			say(`haro server ${pid} serves ${socket}, logging to ${log}`);
			return 0;
		}
		await sleepAsync(START_POLL_MS);
	}
	const said = readFile(log);
	say(`the Haro server did not answer at ${socket} within ${START_WAIT_MS / 1000} s; ${log} ends:`);
	if (said.ok) { say(lastLines(said.value, LOG_TAIL_LINES)); }
	return 1;
}

async function status(): Promise<int32> {
	const got = await askStatus(socketPath());
	if (!got.ok) {
		say(got.error);
		return 1;
	}
	const report = got.value;
	say(`pid ${report.pid}`);
	for (const l of report.listeners) { say(`listening ${l}`); }
	say(`attached clients ${report.clients.length}`);
	for (const c of report.clients) { say(`  ${c}`); }
	return 0;
}

async function stop(): Promise<int32> {
	const socket = socketPath();
	const got = await askStop(socket);
	if (!got.ok) {
		say(got.error);
		return 1;
	}
	say(`haro server ${got.value} stopped`);
	return 0;
}

function logs(inv: Invocation): int32 {
	const log = join(stateDirOf(inv), LOG_NAME);
	const said = readFile(log);
	if (!said.ok) {
		say(`no log at ${log}: start writes it; a server under systemd or launchd logs where that manager logs`);
		return 1;
	}
	console.log(said.value.trimEnd());
	return 0;
}

async function bridged(inv: Invocation): Promise<int32> {
	const done = await proxy(socketPath(), async (): Promise<boolean> => (await start(inv, logged)) == 0);
	if (!done.ok) {
		logged(`haro-server proxy: ${done.error}`);
		return 1;
	}
	return 0;
}

function version(): int32 {
	say(`haro-server ${(HARO_SERVER_VERSION as string)} protocol ${PROTOCOL_VERSION} vt ${vtBuild()}`);
	return 0;
}

async function main(args: string[]): Promise<int32> {
	when (windows) {
		say("haro-server does not run on Windows yet");
		return 1;
	}
	const parsed = parseArgs(args);
	if (!parsed.ok) {
		console.error(`haro-server: ${parsed.error}\n\n${USAGE}`);
		return 2;
	}
	const inv = parsed.value;
	return match (inv.verb) {
		Verb.Run => await run(inv),
		Verb.Start => await start(inv, say),
		Verb.Proxy => await bridged(inv),
		Verb.Version => version(),
		Verb.Status => await status(),
		Verb.Stop => await stop(),
		Verb.Logs => logs(inv),
		Verb.Help => {
			say(USAGE);
			0
		},
	};
}

when (!testBuild) {
	exit(await main(argv.slice(1)));
}
