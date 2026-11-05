import { NeonNode } from "../../../neon/src/render/node";
import { requestFrame } from "../../../neon/src/animation/frame";
import { onSettled } from "../../../neon/src/core/effect";
import { Cleanup } from "../../../neon/src/core/types";
import {
	runWindow,
	DesktopOptions,
	desktopOptions,
	setOptionAsAlt,
	setWindowTitle,
	OptionAsAlt as OptionSides,
} from "../../../neon/src/platform/ion/window";
import {
	AttentionInformational,
	CursorHand,
	CursorIbeam,
	WindowEventCloseRequested,
	getWindow,
	listen,
	notify,
	onExitRequested,
	onWake,
	onWindowEvent,
	openExternal,
	preventClose,
	preventExit,
	requestUserAttention,
	setCursor,
} from "../../../ion/src/index";
import { ionWakeLoop } from "../../../ion/src/platform/bridge.h";
import { argv, exit } from "std/process";
import { appendFile, ensureDir, exists, fileSize, readFile, removeAll, rename, writeFile } from "std/fs";
import { dirname } from "std/fs/path";
import { homeDir } from "std/os";
import { App } from "./app";
import { Pace, Slot } from "./pace";
import { Stats, empty, mark, noteWake } from "./stats";
import { logStatsEverySecond } from "./statsLog";
import { familyList, registerFallbacks } from "./fonts";
import { Config } from "../config/config";
import { CommandDone } from "../vt/vt";
import { KeyEvent, OptionAsAlt } from "../keys/keys";
import { cacheDir, configPath } from "../config/source";
import {
	HookPane,
	Hooks,
	KeyAnswer,
	UNHANDLED,
	answerKey,
	commandDone,
	prompted,
} from "../config/hooks";
import {
	ConfigWatch,
	forFile,
	readConfig,
	reloadNow,
	shellScripts,
	startIn,
	watchConfig,
} from "./configWatch";
import {
	Reattach,
	smoke,
	smokeAttach,
	smokeFlood,
	smokeHosts,
	smokePanes,
	smokeReplay,
	smokeTyping,
} from "./smoke";
import { join } from "std/fs/path";
import { tmpDir } from "std/os";
import { Connection, connectToUnix, socketPath } from "../server/transport";
import { otherVersion, otherVersionAdvice } from "../server/control";
import { Attached, Dial, Failure, ServerLink, attach } from "../client/link";
import { connectLocal, dialLocal, dialUnix } from "../client/connect";
import { startFake } from "../client/fakeServer";
import { ScreenFormat } from "../server/protocol";
import { CommandKind } from "../workspace/workspace";
import { PaneId } from "../workspace/tree";
import { writeText } from "../vt/vt";
import { sshDial } from "../client/ssh";
import { destinationOf } from "../client/destination";
import { vtBuild } from "../vt/snapshot";
import { ptySetWake } from "../pty/nativePty.h";
import { ConfigChange, ConfigOutcome } from "./components/features/terminal/paneModel";
import { RunningPane } from "./panes";
import { WindowHost, WorkspaceView, addHosts, closeShells, open, quit } from "./workspaceView";
import { keptHostsPath } from "../client/hostBook";

const APP_TITLE = "Haro";
const NOTIFICATION_ID = "haro";

when (!windows) {
	import { env } from "std/process";

	@include("signal.h");

	extern function kill(pid: int32, signal: int32): int32;
	extern const SIGTERM: int32 from "SIGTERM";
}

when (macos) {
	import { MenuItem, MenuRole, ModAlt, ModCmd, ModShift, Submenu, setAppMenu } from "../../../ion/src/index";

	@include("unistd.h");

	extern function getppid(): int32;

	function menuBar(): Submenu[] {
		return [
			{
				title: "",
				items: [
					MenuItem.standard(MenuRole.About),
					MenuItem.separator(),
					MenuItem.action("open_config", "Settings…", ",", ModCmd),
					MenuItem.action("reload_config", "Reload Configuration", ",", ModCmd | ModShift),
					MenuItem.separator(),
					MenuItem.standard(MenuRole.Hide),
					MenuItem.standard(MenuRole.HideOthers),
					MenuItem.standard(MenuRole.ShowAll),
					MenuItem.separator(),
					MenuItem.standard(MenuRole.Quit),
				],
			},
			{
				title: "File",
				items: [
					MenuItem.action("new_tab_on_host", "New Tab on Host…", "t", ModCmd | ModAlt),
					MenuItem.action("add_remote_host", "Add Remote Host…", "", 0),
					MenuItem.action("remove_remote_host", "Remove Remote Host…", "", 0),
					MenuItem.separator(),
					MenuItem.action("close_pane", "Close Pane", "w", ModCmd),
					MenuItem.action("close_window", "Close Window", "w", ModCmd | ModShift),
				],
			},
			{
				title: "Edit",
				items: [
					MenuItem.action("copy", "Copy", "c", ModCmd),
					MenuItem.action("paste", "Paste", "v", ModCmd),
					MenuItem.action("select_all", "Select All", "a", ModCmd),
				],
			},
			{
				title: "View",
				items: [
					MenuItem.action("clear_scrollback", "Clear Scrollback", "k", ModCmd),
					MenuItem.separator(),
					MenuItem.action("increase_font_size", "Increase Font Size", "=", ModCmd),
					MenuItem.action("decrease_font_size", "Decrease Font Size", "-", ModCmd),
					MenuItem.action("reset_font_size", "Reset Font Size", "0", ModCmd),
				],
			},
			{
				title: "Window",
				items: [MenuItem.standard(MenuRole.Minimize), MenuItem.standard(MenuRole.Zoom)],
			},
		];
	}
}

const pace = Pace.start();
let waiting: Vec<() => void> = [];
const stats = Stats.empty();
const config = ConfigWatch.forFile(flagValue("--config") ?? configPath());

const ATTACH_TIMEOUT_MS: int32 = 5000;
const HELLO_COLS: int32 = 80;
const HELLO_ROWS: int32 = 24;
const SMOKE_FLAGS: string[] = ["--smoke", "--smoke-panes", "--typing", "--flood"];

const CONFIG_STUB = `import { HaroConfig } from "haro";\n\nexport const config: HaroConfig = {};\n`;
const LOG_LIMIT_BYTES = 1048576;
let logFailed = false;

function logFailure(what: string): void {
	if (logFailed) { return; }
	logFailed = true;
	console.error(`haro: log write failed: ${what}`);
}

function note(line: string): void {
	console.log(`haro: ${line}`);
	const dir = cacheDir();
	const made = ensureDir(dir);
	if (!made.ok) { logFailure(made.error.toString()); return; }
	const path = `${dir}/haro.log`;
	if (exists(path) && fileSize(path) > LOG_LIMIT_BYTES) {
		const rotated = rename(path, `${path}.1`);
		if (!rotated.ok) { logFailure(rotated.error.toString()); return; }
	}
	const logged = appendFile(path, `${Date.now()} ${line}\n`);
	if (!logged.ok) { logFailure(logged.error.toString()); }
}

function fileUrl(path: string): string {
	const slashed = path.replaceAll("\\", "/").replaceAll(" ", "%20");
	return slashed.startsWith("/") ? `file://${slashed}` : `file:///${slashed}`;
}

function openConfig(): void {
	const path = config.file;
	if (!exists(path)) {
		const made = ensureDir(dirname(path));
		if (!made.ok) { note(`open config: cannot create ${dirname(path)}`); return; }
		if (!writeFile(path, CONFIG_STUB).ok) { note(`open config: cannot write ${path}`); return; }
	}
	openExternal(fileUrl(path));
}

let applyConfig: ((c: Config | null, error: string) => void) | null = null;

function reloadConfig(): void {
	const apply = applyConfig;
	if (apply === null) { fail("reload config: the window does not take a config yet"); }
	config.reloadNow(apply);
}

function fail(message: string): never {
	note(message);
	exit(1);
}

function failVisibly(message: string): never {
	notify(APP_TITLE, message, NOTIFICATION_ID);
	fail(message);
}

function titleOr(title: string): string {
	return title == "" ? APP_TITLE : title;
}

function sidesOf(option: OptionAsAlt): OptionSides {
	return match (option) {
		OptionAsAlt.Left => "left",
		OptionAsAlt.Right => "right",
		OptionAsAlt.Both => "both",
		OptionAsAlt.Neither => "neither",
	};
}

function flagValue(flag: string): string | null {
	for (let i = 1; i + 1 < argv.length; i++) {
		if (argv[i] == flag) { return argv[i + 1]; }
	}
	return null;
}

function hasFlag(flag: string): boolean {
	for (const arg of argv) {
		if (arg == flag) { return true; }
	}
	return false;
}

function probableCli(): boolean {
	when (windows) {
		return false;
	} else {
		when (macos) {
			if (getppid() == 1) { return false; }
		}
		return (env.get("TERM_PROGRAM") ?? "") != "" || argv.length > 1;
	}
}

function ranNow(runs: Vec<() => void>): void {
	pace.applied();
	const _id = requestFrame((time: number): void => {
		if (!pace.ticked()) { return; }
		const next = waiting;
		waiting = [];
		ranNow(next);
	});
	for (const run of runs) { run(); }
}

function inFrame(run: () => void): void {
	match (pace.asksFrame()) {
		Slot.Now => { ranNow([run]); },
		Slot.Tick | Slot.Taken => { waiting.push(run); },
	}
}

function withHooks<R>(absent: R, use: (hooks: Hooks) => R): R {
	const hooks = config.loaded.hooks;
	return hooks === null ? absent : use(hooks);
}

interface Launch {
	command: string;
	startIn: string | null;
	shellScripts: string | null;
	recording: string | null;
}

interface Served {
	link: ServerLink | null;
	attached: Attached | null;
	dial: Dial | null;
	label: string;
	remotes: boolean;
}

const IN_PROCESS: Served = { link: null, attached: null, dial: null, label: "", remotes: false };

async function openWindow(
	launch: Launch,
	started: (v: WorkspaceView, first: RunningPane) => void,
	served: Served = IN_PROCESS,
): Promise<int32> {
	registerFallbacks();
	ptySetWake(ionWakeLoop);
	const families = familyList(config.loaded.faces);
	const host: WindowHost = {
		setTitle: (title: string, belled: boolean): void => {
			setWindowTitle(`${belled ? "🔔 " : ""}${titleOr(title)}`);
		},
		notify: (title: string, body: string): void => {
			notify(titleOr(title), body, NOTIFICATION_ID);
		},
		openLink: (uri: string): void => { openExternal(uri); },
		attention: (): void => {
			const win = getWindow("main");
			if (win !== null) { requestUserAttention(win, AttentionInformational); }
		},
		setHand: (on: boolean): void => {
			const win = getWindow("main");
			if (win !== null) { setCursor(win, on ? CursorHand : CursorIbeam); }
		},
		openConfig: openConfig,
		reloadConfig: reloadConfig,
		quit: (): void => { exit(0); },
		wake: (): void => { ionWakeLoop(); },
		report: { note: note, fail: fail },
		timing: { clock: (): float64 => performance.now(), schedule: inFrame },
		keyHook: {
			answer: (pane: HookPane, k: KeyEvent): Result<KeyAnswer, string> => {
				const unhandled: Result<KeyAnswer, string> = Result.ok(UNHANDLED);
				return withHooks(unhandled, (hooks: Hooks): Result<KeyAnswer, string> => {
					return hooks.answerKey(pane, k);
				});
			},
		},
		shellHook: {
			prompted: (pane: HookPane, at: int32): Result<void, string> => {
				return withHooks(Result.ok(null), (hooks: Hooks): Result<void, string> => {
					return hooks.prompted(pane, at);
				});
			},
			commandDone: (pane: HookPane, done: CommandDone): Result<void, string> => {
				return withHooks(Result.ok(null), (hooks: Hooks): Result<void, string> => {
					return hooks.commandDone(pane, done);
				});
			},
		},
		events: {
			onWake: (handler: () => void): void => {
				onWake((): void => {
					stats.noteWake(performance.now());
					handler();
				});
			},
			onMenu: (handler: (id: string) => void): void => {
				listen((name: string, id: string): void => {
					if (name == "menu.click") { handler(id); }
				});
			},
			onCloseRequest: (handler: () => void): void => {
				onWindowEvent((label: string, eventType: int32): void => {
					if (eventType != WindowEventCloseRequested) { return; }
					preventClose();
					handler();
				});
				onExitRequested((): void => {
					preventExit();
					handler();
				});
			},
			onConfig: (handler: (change: ConfigChange) => void): void => {
				if (config.error != "") {
					const error = config.error;
					onSettled((): Cleanup | null => {
						handler({ outcome: ConfigOutcome.Refused, error: error });
						return null;
					});
				}
				const apply = (c: Config | null, error: string): void => {
					if (c === null) {
						handler({ outcome: ConfigOutcome.Refused, error: error });
						return;
					}
					setOptionAsAlt(sidesOf(c.optionAsAlt));
					handler({
						outcome: ConfigOutcome.Loaded,
						config: c,
						family: familyList(config.loaded.faces).join(", "),
						error: error,
					});
				};
				applyConfig = apply;
				config.watchConfig(apply);
			},
		},
		stats: stats,
		fontFamily: families.join(", "),
		hostBook: { path: keptHostsPath(), dial: (address: string): Dial => sshDial(address) },
	};
	const view = WorkspaceView.open(
		host,
		config.loaded.config,
		launch.command,
		launch.shellScripts,
		launch.startIn,
		launch.recording,
		served.link,
		served.attached,
		served.dial,
		served.label,
	);
	if (served.remotes) { view.addHosts(config.loaded.config.remoteHosts); }
	view.started = (first: RunningPane): void => { started(view, first); };
	if (hasFlag("--stats")) { logStatsEverySecond(pace, stats); }
	when (macos) {
		const bar = setAppMenu(menuBar());
		if (!bar.ok) { fail(bar.error); }
	}
	setOptionAsAlt(sidesOf(config.loaded.config.optionAsAlt));
	const opts: DesktopOptions = {
		...desktopOptions(APP_TITLE, 960, 600),
		font: families[0],
		fontFamily: families.join(", "),
	};
	const code = runWindow(opts, (): NeonNode => App(view));
	note("the window closed");
	await view.closeShells();
	return code;
}

function quitter(v: WorkspaceView): () => void {
	return (): void => { const _quit = v.quit(); };
}

function smokes(stop: () => void): (v: WorkspaceView, first: RunningPane) => void {
	return (v: WorkspaceView, first: RunningPane): void => {
		const io = first.model.io;
		const rows = first.model.view;
		const quit = (): void => {
			stop();
			quitter(v)();
		};
		if (hasFlag("--smoke")) { smoke(io, rows, quit); }
		if (hasFlag("--flood")) { smokeFlood(io, rows, pace, quit); }
		if (hasFlag("--typing")) { smokeTyping(io, quit); }
		if (hasFlag("--smoke-panes")) { const _s = smokePanes(v, stop); }
	};
}

function nothing(): void {}

async function runShell(command: string): Promise<int32> {
	const launch: Launch = {
		command: command,
		startIn: config.startIn(probableCli(), homeDir()),
		shellScripts: config.shellScripts(),
		recording: null,
	};
	return await openWindow(launch, smokes(nothing));
}

async function runReplay(path: string): Promise<int32> {
	const recording = readFile(path);
	if (!recording.ok) {
		fail(`the recording ${path} did not read`);
	}
	const launch: Launch = {
		command: "",
		startIn: null,
		shellScripts: null,
		recording: recording.value,
	};
	return await openWindow(launch, (v: WorkspaceView, first: RunningPane): void => {
		if (hasFlag("--smoke")) { smokeReplay(first.model.view, quitter(v)); }
	});
}

async function attachedTo(connection: Connection, path: string): Promise<Reattach> {
	const link = new ServerLink(connection);
	link.begin();
	const got = await attach(link, vtBuild(), HELLO_COLS, HELLO_ROWS, ATTACH_TIMEOUT_MS);
	if (!got.ok) {
		link.connection.close();
		if (got.error.failure == Failure.Refused) {
			failVisibly(await otherVersion(path) ?? otherVersionAdvice(path, got.error.why, null));
		}
		failVisibly(`Haro could not attach to its server at ${path}: ${got.error.why}`);
	}
	return { link: link, attached: got.value };
}

const CLIENT_LAUNCH: Launch = { command: "", startIn: null, shellScripts: null, recording: null };

function ignoreStart(v: WorkspaceView, first: RunningPane): void {}

async function runClient(): Promise<int32> {
	const path = socketPath();
	const connected = await connectLocal(path);
	if (!connected.ok) { failVisibly(connected.error); }
	const server = await attachedTo(connected.value, path);
	return await openWindow(CLIENT_LAUNCH, ignoreStart, {
		link: server.link,
		attached: server.attached,
		dial: dialLocal(path),
		label: "",
		remotes: true,
	});
}

async function runRemote(destination: string): Promise<int32> {
	return await openWindow(CLIENT_LAUNCH, ignoreStart, {
		link: null,
		attached: null,
		dial: sshDial(destination),
		label: destination,
		remotes: false,
	});
}

async function reattachAt(path: string): Promise<Result<Reattach, string>> {
	const c = await connectToUnix(path, ATTACH_TIMEOUT_MS);
	if (!c.ok) { return Result.err(`no server answered at ${path}: ${c.error.toString()}`); }
	const link = new ServerLink(c.value);
	link.begin();
	const got = await attach(link, vtBuild(), HELLO_COLS, HELLO_ROWS, ATTACH_TIMEOUT_MS);
	if (!got.ok) { return Result.err(got.error.why); }
	return Result.ok({ link: link, attached: got.value });
}

interface PrivateServer {
	dir: string;
	path: string;
	first: Reattach;
	stop: () => void;
}

async function privateServer(what: string): Promise<PrivateServer> {
	when (windows) {
		fail(`${what}: a Haro server does not run on Windows yet`);
	} else {
		const dir = join(tmpDir(), `haro-${what}-${Date.now()}`);
		const path = join(dir, "haro.sock");
		const _chosen = env.set("HARO_SOCKET", path);
		const started = await connectLocal(path);
		if (!started.ok) { fail(`${what}: ${started.error}`); }
		const link = new ServerLink(started.value);
		link.begin();
		const first = await attach(link, vtBuild(), HELLO_COLS, HELLO_ROWS, ATTACH_TIMEOUT_MS);
		if (!first.ok) { fail(`${what}: ${first.error.why}`); }
		const daemon = first.value.serverPid;
		return {
			dir: dir,
			path: path,
			first: { link: link, attached: first.value },
			stop: (): void => {
				if (kill(daemon, SIGTERM) != 0) { console.log(`${what}: the server ${daemon} was already gone`); }
				const _removed = removeAll(dir);
			},
		};
	}
}

function servedBy(server: PrivateServer): Served {
	return { link: server.first.link, attached: server.first.attached, dial: null, label: "", remotes: false };
}

async function runSmoke(): Promise<int32> {
	const server = await privateServer("smoke");
	const code = await openWindow(CLIENT_LAUNCH, smokes(server.stop), servedBy(server));
	server.stop();
	return code;
}

async function runSmokeAttach(): Promise<int32> {
	const server = await privateServer("smoke-attach");
	const reconnect = (): Promise<Result<Reattach, string>> => reattachAt(server.path);
	const code = await openWindow(
		CLIENT_LAUNCH,
		(v: WorkspaceView, shown: RunningPane): void => {
			const _s = smokeAttach(v, reconnect, server.stop);
		},
		servedBy(server),
	);
	server.stop();
	return code;
}

async function runSmokeHosts(): Promise<int32> {
	const server = await privateServer("smoke-hosts");
	const remotePath = join(server.dir, "remote.sock");
	const fake = startFake(remotePath, ScreenFormat.Native);
	if (!fake.ok) { fail(`smoke-hosts: the fake remote did not listen: ${fake.error.toString()}`); }
	const _tab = fake.value.apply({ kind: CommandKind.NewTab });
	fake.value.paneOf(1 as PaneId)?.vt.writeText("remote-marker\r\n");
	const stop = (): void => {
		fake.value.close();
		server.stop();
	};
	const code = await openWindow(
		CLIENT_LAUNCH,
		(v: WorkspaceView, shown: RunningPane): void => {
			const _s = smokeHosts(v, fake.value, dialUnix(remotePath), stop);
		},
		servedBy(server),
	);
	stop();
	return code;
}

async function main(): Promise<int32> {
	stats.mark("main", Date.now());
	config.readConfig();
	stats.mark("config", Date.now());
	const replayPath = flagValue("--replay");
	if (replayPath !== null) { return await runReplay(replayPath); }
	when (windows) {
		return await runShell(flagValue("--shell") ?? config.loaded.config.command);
	} else {
		if (flagValue("--shell") !== null) {
			fail("--shell picks the shell only on Windows; elsewhere the server runs command from config.ms");
		}
		if (hasFlag("--smoke-attach")) { return await runSmokeAttach(); }
		if (hasFlag("--smoke-hosts")) { return await runSmokeHosts(); }
		if (SMOKE_FLAGS.some((flag: string): boolean => hasFlag(flag))) { return await runSmoke(); }
		const remote = flagValue("--connect");
		if (remote !== null) {
			const destination = destinationOf(remote);
			if (!destination.ok) { failVisibly(`--connect: ${destination.error}`); }
			return await runRemote(destination.value);
		}
		return await runClient();
	}
}

when (!testBuild) {
	exit(await main());
}
