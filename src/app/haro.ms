@include("./wake.h");
@compile("./wake.c");

import { NeonNode } from "../../../neon/src/render/node";
import { requestFrame } from "../../../neon/src/animation/frame";
import {
	runWindow,
	DesktopOptions,
	desktopOptions,
} from "../../../neon/src/platform/ion/window";
import { onWake, openExternal } from "../../../ion/src/index";
import { FontStyle, registerFace } from "../../../void/src/void2d/font";
import { argv, env, exit } from "std/process";
import { readFile } from "std/fs";
import { Pty, PtyError } from "../pty/transport";
import { ConPty } from "../pty/pty";
import { Replay } from "../pty/replay";
import { App, Entry } from "./app";
import { Pace } from "./pace";
import { Config, defaults } from "../config/config";
import { Loaded, configPath, load, stampOf } from "../config/source";
import { smoke, smokeFlood, smokeReplay } from "./smoke";
import { Term, openTerm, shutdown } from "./term";

extern function appWireWake(): void;

const FONT_PATH = "assets/JetBrainsMonoNL-Regular.ttf";
const FONT_BOLD = "assets/JetBrainsMonoNL-Bold.ttf";
const FONT_ITALIC = "assets/JetBrainsMonoNL-Italic.ttf";
const FONT_BOLD_ITALIC = "assets/JetBrainsMonoNL-BoldItalic.ttf";
const FALLBACK_FAMILIES = "Segoe UI Symbol, Microsoft YaHei";
const CONFIG_POLL_MS = 1000;

const pace = Pace.start();
const configFile = valueOf("--config") ?? configPath();
let loaded: Loaded = { config: defaults(), faces: null, stamp: "" };
let configError = "";

function fail(message: string): void {
	console.log(`haro: ${message}`);
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

function registerBuiltIn(): void {
	registerFace(FONT_BOLD, FONT_PATH, 700, FontStyle.Normal);
	registerFace(FONT_ITALIC, FONT_PATH, 400, FontStyle.Italic);
	registerFace(FONT_BOLD_ITALIC, FONT_PATH, 700, FontStyle.Italic);
}

function registerFaces(): string {
	registerBuiltIn();
	const faces = loaded.faces;
	if (faces === null) { return FONT_PATH; }
	registerFace(FONT_PATH, FONT_PATH, 400, FontStyle.Normal);
	const family = faces.regular;
	const bold = faces.bold;
	const italic = faces.italic;
	const boldItalic = faces.boldItalic;
	if (bold !== null) { registerFace(bold, family, 700, FontStyle.Normal); }
	if (italic !== null) { registerFace(italic, family, 400, FontStyle.Italic); }
	if (boldItalic !== null) { registerFace(boldItalic, family, 700, FontStyle.Italic); }
	return family;
}

function familiesAfter(font: string): string {
	return font == FONT_PATH ? `${font}, ${FALLBACK_FAMILIES}` : `${font}, ${FONT_PATH}, ${FALLBACK_FAMILIES}`;
}

function show(t: Term, exited: (code: int32) => void): int32 {
	const font = registerFaces();
	const systemFonts = `${env.get("WINDIR")}/Fonts`;
	registerFace(`${systemFonts}/seguisym.ttf`, "Segoe UI Symbol", 400, FontStyle.Normal);
	registerFace(`${systemFonts}/msyh.ttc`, "Microsoft YaHei", 400, FontStyle.Normal);
	const entry: Entry = {
		onWake: (handler: () => void): void => {
			onWake((): void => {
				const drained = t.drain();
				if (!drained.ok) {
					fail(`drain: ${drained.error.toString()}`);
					return;
				}
				if (!pace.asksFrame()) { return; }
				const _id = requestFrame((time: number): void => {
					pace.applied();
					handler();
				});
			});
		},
		exited: exited,
		fail: fail,
		openLink: (uri: string): void => { openExternal(uri); },
		onConfig: (handler: (c: Config | null, error: string) => void): void => {
			if (configError != "") { handler(null, configError); }
			watchConfig(handler);
		},
	};
	const opts: DesktopOptions = { ...desktopOptions("Haro", 960, 600), font: font, fontFamily: familiesAfter(font) };
	const code = runWindow(opts, (): NeonNode => App(t, entry, loaded.config));
	t.shutdown();
	return code;
}

function runShell(shell: string): int32 {
	const opened = openTerm((cols: int32, rows: int32): Result<Pty, PtyError> => {
		return ConPty.spawn(shell, cols, rows);
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
		console.log(`haro: the shell exited with code ${code}`);
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
	readConfig();
	const replayPath = valueOf("--replay");
	if (replayPath !== null) { return runReplay(replayPath); }
	return runShell(valueOf("--shell") ?? loaded.config.command);
}

exit(main());
