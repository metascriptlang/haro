import { NeonNode } from "../../../neon/src/render/node";
import { requestFrame } from "../../../neon/src/animation/frame";
import { onSettled } from "../../../neon/src/core/effect";
import { Cleanup } from "../../../neon/src/core/types";
import {
	runWindow, DesktopOptions, desktopOptions, setOptionAsAlt, setWindowTitle, OptionAsAlt as OptionSides,
} from "../../../neon/src/platform/ion/window";
import {
	WindowEventCloseRequested,
	beep,
	listen,
	notify,
	onExitRequested,
	onWake,
	onWindowEvent,
	openExternal,
	preventClose,
	preventExit,
} from "../../../ion/src/index";
import { ionWakeLoop } from "../../../ion/src/platform/bridge.h";
import { argv, exit } from "std/process";
import { appendFile, ensureDir, exists, fileSize, readFile, rename } from "std/fs";
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
import { HookPane, KeyAnswer, UNHANDLED, answerKey, commandDone, prompted } from "../config/hooks";
import {
	ConfigWatch,
	forFile,
	readConfig,
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

const CLOSE_WINDOW = "close_window";
const APP_TITLE = "Haro";
const NOTIFICATION_ID = "haro";

when (!windows) {
	import { env } from "std/process";
}

when (macos) {
	import { MenuItem, MenuRole, ModCmd, Submenu, setAppMenu } from "../../../ion/src/index";

	@include("unistd.h");

	extern function getppid(): int32;

	function menuBar(): Submenu[] {
		return [
			{
				title: "",
				items: [
					MenuItem.standard(MenuRole.About),
					MenuItem.separator(),
					MenuItem.standard(MenuRole.Hide),
					MenuItem.standard(MenuRole.HideOthers),
					MenuItem.standard(MenuRole.ShowAll),
					MenuItem.separator(),
					MenuItem.standard(MenuRole.Quit),
				],
			},
			{ title: "File", items: [MenuItem.action(CLOSE_WINDOW, "Close Window", "w", ModCmd)] },
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

async function openWindow(shell: Shell, view: View, exited: (code: int32) => void): Promise<int32> {
	registerFallbacks();
	const families = familyList(config.loaded.faces);
	const host: AppHost = {
		desktop: {
			setTitle: (title: string): void => { setWindowTitle(titleOr(title)); },
			notify: (title: string, body: string): void => {
				notify(titleOr(title), body, NOTIFICATION_ID);
			},
			openLink: (uri: string): void => { openExternal(uri); },
			bell: (): void => { beep(); },
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
				const hooks = config.loaded.hooks;
				return hooks === null ? Result.ok(UNHANDLED) : hooks.answerKey(pane, k);
			},
		},
		shellHook: {
			prompted: (pane: HookPane, at: int32): Result<void, string> => {
				const hooks = config.loaded.hooks;
				return hooks === null ? Result.ok(null) : hooks.prompted(pane, at);
			},
			commandDone: (pane: HookPane, done: CommandDone): Result<void, string> => {
				const hooks = config.loaded.hooks;
				return hooks === null ? Result.ok(null) : hooks.commandDone(pane, done);
			},
		},
		events: {
			onWake: (handler: () => void): void => {
				onWake((): void => {
					stats.noteWake(performance.now());
					handler();
				});
			},
			onCloseKey: (handler: () => void): void => {
				listen((name: string, id: string): void => {
					if (name == "menu.click" && id == CLOSE_WINDOW) { handler(); }
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
				config.watchConfig((c: Config | null, error: string): void => {
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
				});
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
	const code = runWindow(opts, (): NeonNode => App(portOf(shell), view, host, config.loaded.config, stats));
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
	if (hasFlag("--smoke")) { smokeReplay(portOf(shell), view, quitWith(shell)); }
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
