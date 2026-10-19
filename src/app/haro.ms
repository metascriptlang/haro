@include("./wake.h");
@compile("./wake.c");

import { NeonNode } from "../../../neon/src/render/node";
import { requestFrame } from "../../../neon/src/animation/frame";
import {
	runWindow,
	DesktopOptions,
	desktopOptions,
	frameCounts,
} from "../../../neon/src/platform/ion/window";
when (voidProfiler) {
	import { frameStats } from "../../../void/src/void2d/frameMarks";
	import { ringCount, ringPercentile } from "../../../void/src/void2d/profiler";
}
import {
	MenuItem,
	MenuRole,
	ModCmd,
	Submenu,
	listen,
	onWake,
	openExternal,
	resourcePath,
	setAppMenu,
} from "../../../ion/src/index";
import { FontStyle, registerFace } from "../../../void/src/void2d/font";
import { argv, env, exit } from "std/process";
import { appendFile, ensureDir, readFile } from "std/fs";
import { homeDir } from "std/os";
import { Pty, PtyError } from "../pty/transport";
import { NativePty } from "../pty/pty";
import { Replay } from "../pty/replay";
import { App, Entry } from "./app";
import { Pace } from "./pace";
import { stats, launched, launchLine, line, mark, noteWake, reset } from "./stats";
import { Config, defaults } from "../config/config";
import { Loaded, cacheDir, configPath, load, stampOf } from "../config/source";
import { Faces } from "../config/fonts";
import { smoke, smokeFlood, smokeReplay } from "./smoke";
import { Term, openTerm, shutdown } from "./term";

extern function appWireWake(): void;

const ASSETS = resourcePath() == "" ? "assets" : `${resourcePath().replaceAll("\\", "/")}/assets`;
const FONT_PATH = `${ASSETS}/JetBrainsMonoNL-Regular.ttf`;
const FONT_BOLD = `${ASSETS}/JetBrainsMonoNL-Bold.ttf`;
const FONT_ITALIC = `${ASSETS}/JetBrainsMonoNL-Italic.ttf`;
const FONT_BOLD_ITALIC = `${ASSETS}/JetBrainsMonoNL-BoldItalic.ttf`;
const CLOSE_WINDOW = "close_window";

interface SystemFace {
	path: string;
	family: string;
}

when (windows) {
	function fallbackFaces(): SystemFace[] {
		const fonts = `${env.get("WINDIR")}/Fonts`;
		return [
			{ path: `${fonts}/seguiemj.ttf`, family: "Segoe UI Emoji" },
			{ path: `${fonts}/seguisym.ttf`, family: "Segoe UI Symbol" },
			{ path: `${fonts}/msyh.ttc`, family: "Microsoft YaHei" },
		];
	}
} else when (macos) {
	@include("unistd.h");

	extern function getppid(): int32;

	function fallbackFaces(): SystemFace[] {
		return [
			{ path: "/System/Library/Fonts/Apple Color Emoji.ttc", family: "Apple Color Emoji" },
			{ path: "/System/Library/Fonts/Apple Symbols.ttf", family: "Apple Symbols" },
			{ path: "/System/Library/Fonts/Hiragino Sans GB.ttc", family: "Hiragino Sans GB" },
		];
	}

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
			{ title: "Window", items: [MenuItem.standard(MenuRole.Minimize), MenuItem.standard(MenuRole.Zoom)] },
		];
	}
} else {
	function fallbackFaces(): SystemFace[] {
		return [];
	}
}
const CONFIG_POLL_MS = 1000;
const STATS_MS = 1000;

const pace = Pace.start();
const configFile = valueOf("--config") ?? configPath();
let loaded: Loaded = { config: defaults(), faces: [], stamp: "" };
let configError = "";
let launchShown = false;

function note(line: string): void {
	console.log(`haro: ${line}`);
	const dir = cacheDir();
	if (ensureDir(dir).ok) { const _logged = appendFile(`${dir}/haro.log`, `${Date.now()} ${line}\n`); }
}

function fail(message: string): void {
	note(message);
	exit(1);
}

function valueOf(flag: string): string | null {
	for (let i = 1; i + 1 < argv.length; i++) {
		if (argv[i] == flag) { return argv[i + 1]; }
	}
	return null;
}

function has(flag: string): boolean {
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

function readConfig(): void {
	const got = load(configFile);
	if (got.ok) {
		loaded = got.value;
		return;
	}
	configError = got.error;
	loaded.stamp = stampOf(configFile);
}

function watchConfig(handler: (c: Config | null, error: string) => void): void {
	setTimeout((): void => {
		const stamp = stampOf(configFile);
		if (stamp != loaded.stamp) {
			const got = load(configFile);
			if (got.ok) {
				loaded = got.value;
				handler(got.value.config, "");
			} else {
				loaded.stamp = stamp;
				handler(null, got.error);
			}
		}
		watchConfig(handler);
	}, CONFIG_POLL_MS);
}

function milliseconds(ns: int64): float64 {
	return Math.round((ns as float64) / 10000.0) / 100;
}

function voidLine(): string {
	when (voidProfiler) {
		const draws = frameStats.draws;
		if (draws.ringCount() == 0) { return "void frames=0"; }
		const dirty = frameStats.dirtyToPresent;
		const d2p = dirty.ringCount() == 0
			? ""
			: ` d2p p50=${milliseconds(dirty.ringPercentile(50))} p99=${milliseconds(dirty.ringPercentile(99))}`;
		return `void frames=${frameStats.frames} draw p50=${milliseconds(draws.ringPercentile(50))} p99=${milliseconds(draws.ringPercentile(99))}${d2p}`;
	} else {
		return "";
	}
}

function logStats(wakes: int32, applies: int32, requested: number, drawn: number): void {
	setTimeout((): void => {
		const counts = frameCounts();
		console.log(
			`haro stats: ${stats.line()} wakes=${pace.wakes - wakes} applies=${pace.applies - applies} ` +
			`requested=${counts[0] - requested} drawn=${counts[1] - drawn} ${voidLine()}`,
		);
		stats.reset();
		if (!launchShown && stats.launched()) {
			launchShown = true;
			console.log(`haro launch: ${stats.launchLine()}`);
		}
		logStats(pace.wakes, pace.applies, counts[0], counts[1]);
	}, STATS_MS);
}

function registerBuiltIn(): void {
	registerFace(FONT_BOLD, FONT_PATH, 700, FontStyle.Normal);
	registerFace(FONT_ITALIC, FONT_PATH, 400, FontStyle.Italic);
	registerFace(FONT_BOLD_ITALIC, FONT_PATH, 700, FontStyle.Italic);
}

function registerFamily(faces: Faces): string {
	const family = faces.regular;
	const bold = faces.bold;
	const italic = faces.italic;
	const boldItalic = faces.boldItalic;
	registerFace(family, family, 400, FontStyle.Normal);
	if (bold !== null) { registerFace(bold, family, 700, FontStyle.Normal); }
	if (italic !== null) { registerFace(italic, family, 400, FontStyle.Italic); }
	if (boldItalic !== null) { registerFace(boldItalic, family, 700, FontStyle.Italic); }
	return family;
}

function registerFamilies(): string[] {
	registerBuiltIn();
	registerFace(FONT_PATH, FONT_PATH, 400, FontStyle.Normal);
	let families: string[] = [];
	for (const faces of loaded.faces) { families.push(registerFamily(faces)); }
	families.push(FONT_PATH);
	for (const face of fallbackFaces()) {
		registerFace(face.path, face.family, 400, FontStyle.Normal);
		families.push(face.family);
	}
	return families;
}

function inFrame(run: () => void): void {
	if (!pace.asksFrame()) { return; }
	const _id = requestFrame((time: number): void => {
		pace.applied();
		run();
	});
}

function show(t: Term, exited: (code: int32) => void): int32 {
	const families = registerFamilies();
	const entry: Entry = {
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
		onConfig: (handler: (c: Config | null, error: string) => void): void => {
			if (configError != "") { handler(null, configError); }
			watchConfig(handler);
		},
	};
	if (has("--stats")) { logStats(0, 0, 0, 0); }
	when (macos) {
		const bar = setAppMenu(menuBar());
		if (!bar.ok) { fail(bar.error); }
	}
	const opts: DesktopOptions = { ...desktopOptions("Haro", 960, 600), font: families[0], fontFamily: families.join(", ") };
	const code = runWindow(opts, (): NeonNode => App(t, entry, loaded.config));
	note("the window closed");
	t.shutdown();
	return code;
}

function runShell(shell: string): int32 {
	const cwd = loaded.config.startDirectory(probableCli(), homeDir());
	const opened = openTerm((cols: int32, rows: int32): Result<Pty, PtyError> => {
		return NativePty.spawn(shell, cols, rows, cwd);
	});
	if (!opened.ok) {
		fail(`open: ${opened.error.toString()}`);
		return 1;
	}
	const t = opened.value;
	appWireWake();
	if (has("--smoke")) { smoke(t); }
	if (has("--flood")) { smokeFlood(t, pace); }
	return show(t, (code: int32): void => {
		note(`the shell exited with code ${code}`);
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
	if (has("--smoke")) { smokeReplay(t); }
	return show(t, (code: int32): void => {
		console.log(`haro: the recording ended with code ${code}`);
	});
}

function main(): int32 {
	stats.mark("main", Date.now());
	readConfig();
	stats.mark("config", Date.now());
	const replayPath = valueOf("--replay");
	if (replayPath !== null) { return runReplay(replayPath); }
	return runShell(valueOf("--shell") ?? loaded.config.command);
}

exit(main());
