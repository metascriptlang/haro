@include("./wake.h");
@compile("./wake.c");

import { NeonNode } from "../../../neon/src/render/node";
import { requestFrame } from "../../../neon/src/animation/frame";
import { runWindow, DesktopOptions, desktopOptions } from "../../../neon/src/platform/ion/window";
import { getWindow, listen, onWake, openExternal, setTitle } from "../../../ion/src/index";
import { argv, exit } from "std/process";
import { appendFile, ensureDir, readFile } from "std/fs";
import { homeDir } from "std/os";
import { Pty, PtyError } from "../pty/transport";
import { NativePty } from "../pty/pty";
import { Replay } from "../pty/replay";
import { App } from "./app";
import { Pace } from "./pace";
import { stats, mark, noteWake } from "./stats";
import { logStatsEverySecond } from "./statsLog";
import { familyList, registerFallbacks } from "./fonts";
import { Config } from "../config/config";
import { cacheDir, configPath } from "../config/source";
import { ConfigWatch, forFile, readConfig, watchConfig } from "./configWatch";
import { smoke, smokeFlood, smokeReplay } from "./smoke";
import { Term, exitCodeText, openTerm, shutdown } from "./components/features/terminal/term";
import { AppHost } from "./components/features/terminal/paneModel";

extern function appWireWake(): void;

const CLOSE_WINDOW = "close_window";
const APP_TITLE = "Haro";
const NEON_WINDOW = "main";

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
const config = ConfigWatch.forFile(flagValue("--config") ?? configPath());

function note(line: string): void {
	console.log(`haro: ${line}`);
	const dir = cacheDir();
	if (!ensureDir(dir).ok) { return; }
	const _logged = appendFile(`${dir}/haro.log`, `${Date.now()} ${line}\n`);
}

function fail(message: string): void {
	note(message);
	exit(1);
}

function titleOr(title: string): string {
	return title == "" ? APP_TITLE : title;
}

function setWindowTitle(title: string): void {
	const win = getWindow(NEON_WINDOW);
	if (win === null) {
		note(`no window labelled ${NEON_WINDOW} to title`);
		return;
	}
	setTitle(win, titleOr(title));
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

function openWindow(t: Term, exited: (code: int32) => void): int32 {
	registerFallbacks();
	const families = familyList(config.loaded.faces);
	const host: AppHost = {
		onWake: (handler: () => void): void => {
			onWake((): void => {
				stats.noteWake(performance.now());
				const drained = t.drain();
				if (!drained.ok) {
					fail(`drain: ${drained.error.toString()}`);
					return;
				}
				inFrame(handler);
			});
		},
		schedule: inFrame,
		exited: exited,
		fail: fail,
		setTitle: setWindowTitle,
		openLink: (uri: string): void => { openExternal(uri); },
		close: (): void => {
			note("Close Window or a keybind closed the window");
			t.shutdown();
			exit(0);
		},
		onCloseKey: (handler: () => void): void => {
			listen((name: string, id: string): void => {
				if (name == "menu.click" && id == CLOSE_WINDOW) { handler(); }
			});
		},
		onConfig: (
			handler: (c: Config | null, fontFamily: string, error: string) => void,
		): void => {
			if (config.error != "") { handler(null, "", config.error); }
			config.watchConfig((c: Config | null, error: string): void => {
				handler(c, c === null ? "" : familyList(config.loaded.faces).join(", "), error);
			});
		},
		fontFamily: families.join(", "),
	};
	if (hasFlag("--stats")) { logStatsEverySecond(pace); }
	when (macos) {
		const bar = setAppMenu(menuBar());
		if (!bar.ok) { fail(bar.error); }
	}
	const opts: DesktopOptions = {
		...desktopOptions(APP_TITLE, 960, 600),
		font: families[0],
		fontFamily: families.join(", "),
	};
	const code = runWindow(opts, (): NeonNode => App(t, host, config.loaded.config));
	note("the window closed");
	t.shutdown();
	return code;
}

function runShell(shell: string): int32 {
	const cwd = config.loaded.config.startDirectory(probableCli(), homeDir());
	const opened = openTerm((
		cols: int32,
		rows: int32,
		cellWidth: int32,
		cellHeight: int32,
	): Result<Pty, PtyError> => {
		return NativePty.spawn(shell, cols, rows, cwd, cellWidth, cellHeight);
	});
	if (!opened.ok) {
		fail(`open: ${opened.error.toString()}`);
		return 1;
	}
	const t = opened.value;
	appWireWake();
	if (hasFlag("--smoke")) { smoke(t); }
	if (hasFlag("--flood")) { smokeFlood(t, pace); }
	return openWindow(t, (code: int32): void => {
		note(`the shell exited with code ${exitCodeText(code)}`);
		t.shutdown();
		exit(0);
	});
}

function runReplay(path: string): int32 {
	const recording = readFile(path);
	if (!recording.ok) {
		fail(`the recording ${path} did not read`);
		return 1;
	}
	const replay = Replay.ofText(recording.value);
	const opened = openTerm((cols: int32, rows: int32): Result<Pty, PtyError> => {
		return Result.ok(replay.toPty());
	});
	if (!opened.ok) {
		fail(`open: ${opened.error.toString()}`);
		return 1;
	}
	const t = opened.value;
	if (hasFlag("--smoke")) { smokeReplay(t); }
	return openWindow(t, (code: int32): void => {
		console.log(`haro: the recording ended with code ${exitCodeText(code)}`);
	});
}

function main(): int32 {
	stats.mark("main", Date.now());
	config.readConfig();
	stats.mark("config", Date.now());
	const replayPath = flagValue("--replay");
	if (replayPath !== null) { return runReplay(replayPath); }
	return runShell(flagValue("--shell") ?? config.loaded.config.command);
}

exit(main());
