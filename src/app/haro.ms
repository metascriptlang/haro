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
import { appendFile, ensureDir, exists, fileSize, readFile, rename, writeFile } from "std/fs";
import { dirname } from "std/fs/path";
import { homeDir } from "std/os";
import { App } from "./app";
import { Pace } from "./pace";
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
import { smoke, smokeFlood, smokeReplay, smokeTyping } from "./smoke";
import { exitCodeText } from "../controller/term";
import { Shell, closeThen, closed, opened, portOf } from "../controller/shell";
import { View, open } from "./frame";
import { ptySetWake } from "../pty/nativePty.h";
import {
	AppHost,
	ConfigChange,
	ConfigOutcome,
} from "./components/features/terminal/paneModel";

const APP_TITLE = "Haro";
const NOTIFICATION_ID = "haro";

when (!windows) {
	import { env } from "std/process";
}

when (macos) {
	import { MenuItem, MenuRole, ModCmd, ModShift, Submenu, setAppMenu } from "../../../ion/src/index";

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
			{ title: "File", items: [MenuItem.action("close_window", "Close Window", "w", ModCmd)] },
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
const stats = Stats.empty();
const config = ConfigWatch.forFile(flagValue("--config") ?? configPath());

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

function inFrame(run: () => void): void {
	if (!pace.asksFrame()) { return; }
	const _id = requestFrame((time: number): void => {
		pace.applied();
		run();
	});
}

function quitWith(shell: Shell): () => void {
	return (): void => { const _closing = closeThen(shell, (): void => { exit(0); }); };
}

function withHooks<R>(absent: R, use: (hooks: Hooks) => R): R {
	const hooks = config.loaded.hooks;
	return hooks === null ? absent : use(hooks);
}

async function openWindow(shell: Shell, view: View, exited: (code: int32) => void): Promise<int32> {
	registerFallbacks();
	const families = familyList(config.loaded.faces);
	const host: AppHost = {
		desktop: {
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
			close: (): void => {
				note("Close Window or a keybind closed the window");
				quitWith(shell)();
			},
			exited: exited,
		},
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
		fontFamily: families.join(", "),
	};
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
	const code = runWindow(opts, (): NeonNode => {
		return App(portOf(shell), view, host, config.loaded.config, stats);
	});
	note("the window closed");
	await closed(shell);
	return code;
}

async function started(shell: Shell): Promise<void> {
	const refused = await opened(shell);
	if (refused !== null) { fail(`open: ${refused.toString()}`); }
}

async function runShell(command: string): Promise<int32> {
	const cwd = config.startIn(probableCli(), homeDir());
	const shell = new Shell({
		command: command,
		cwd: cwd,
		recording: null,
		shellScripts: config.shellScripts(),
	});
	await started(shell);
	const view = View.open();
	ptySetWake(ionWakeLoop);
	if (hasFlag("--smoke")) { smoke(portOf(shell), view, quitWith(shell)); }
	if (hasFlag("--flood")) { smokeFlood(portOf(shell), view, pace, quitWith(shell)); }
	if (hasFlag("--typing")) { smokeTyping(portOf(shell), quitWith(shell)); }
	return await openWindow(shell, view, (code: int32): void => {
		note(`the shell exited with code ${exitCodeText(code)}`);
		quitWith(shell)();
	});
}

async function runReplay(path: string): Promise<int32> {
	const recording = readFile(path);
	if (!recording.ok) {
		fail(`the recording ${path} did not read`);
	}
	const shell = new Shell({ command: "", cwd: null, recording: recording.value });
	await started(shell);
	const view = View.open();
	if (hasFlag("--smoke")) { smokeReplay(view, quitWith(shell)); }
	return await openWindow(shell, view, (code: int32): void => {
		console.log(`haro: the recording ended with code ${exitCodeText(code)}`);
	});
}

async function main(): Promise<int32> {
	stats.mark("main", Date.now());
	config.readConfig();
	stats.mark("config", Date.now());
	const replayPath = flagValue("--replay");
	if (replayPath !== null) { return await runReplay(replayPath); }
	return await runShell(flagValue("--shell") ?? config.loaded.config.command);
}

when (!testBuild) {
	exit(await main());
}
