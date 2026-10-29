import { ensureDir, isDir, writeFile } from "std/fs";
import { Config, StartKind, defaults } from "../config/config";
import { Loaded, configStamp, empty, load } from "../config/source";
import { resourcePath } from "../../../ion/src/index";
import { cwd } from "std/process";
import { homeDir } from "std/os";

// Polled until compiler card 2026-09-26-await-on-fs-watch-never-resumes lets a watch resume in an Ion window
const CONFIG_POLL_MS = 1000;
const ASSETS = resourcePath() == ""
	? `${cwd().replaceAll("\\", "/")}/assets`
	: `${resourcePath().replaceAll("\\", "/")}/assets`;
const API = `${ASSETS}/haro`;
const METASCRIPT = resourcePath() == ""
	? `${homeDir().replaceAll("\\", "/")}/.metascript`
	: `${resourcePath().replaceAll("\\", "/")}/metascript`;

export interface ConfigWatch {
	file: string;
	loaded: Loaded;
	error: string;
}

export function forFile(this typeof ConfigWatch, file: string): ConfigWatch {
	return { file: file, loaded: Loaded.empty(), error: "" };
}

function reload(this w: ConfigWatch): Result<Config, string> {
	const got = try load(w.file, API, METASCRIPT);
	w.loaded = got;
	return Result.ok(got.config);
}

export function readConfig(this w: ConfigWatch): void {
	const got = w.reload();
	if (got.ok) {
		w.error = w.loaded.notice;
		return;
	}
	w.error = got.error;
	w.loaded.stamp = w.stampNow();
}

function stampNow(this w: ConfigWatch): string {
	return stampText(configStamp(w.file, API));
}

function stampText(read: Result<string, string>): string {
	return read.ok ? read.value : `unreadable: ${read.error}`;
}

function poll(this w: ConfigWatch, handler: (c: Config | null, error: string) => void): void {
	const read = configStamp(w.file, API);
	const stamp = stampText(read);
	if (stamp == w.loaded.stamp) { return; }
	if (!read.ok) {
		w.loaded.stamp = stamp;
		handler(null, read.error);
		return;
	}
	if (stamp == "") {
		w.loaded.stamp = stamp;
		handler(null, `${w.file} is gone; the last config it gave stays`);
		return;
	}
	const got = w.reload();
	if (got.ok) {
		handler(got.value, w.loaded.notice);
	} else {
		w.loaded.stamp = stamp;
		handler(null, got.error);
	}
}

export function startIn(this w: ConfigWatch, probableCli: boolean, home: string): string | null {
	const dir = w.loaded.config.startDirectory(probableCli, home);
	if (dir === null || isDir(dir)) { return dir; }
	const skipped = `workingDirectory ${dir} does not exist, so the shell starts where Haro was started`;
	w.error = w.error == "" ? skipped : `${w.error}; ${skipped}`;
	return null;
}

export function shellScripts(this w: ConfigWatch): string | null {
	return w.loaded.config.shellIntegration ? `${ASSETS}/shell` : null;
}

export function watchConfig(
	this w: ConfigWatch,
	handler: (c: Config | null, error: string) => void,
): void {
	setTimeout((): void => {
		w.poll(handler);
		w.watchConfig(handler);
	}, CONFIG_POLL_MS);
}

test "a start directory that does not exist is skipped and said, and one that exists is kept" {
	const w = ConfigWatch.forFile("/no/such/haro/config.ms");
	w.loaded = { config: { ...defaults(), workingDirectory: { kind: StartKind.Path, path: "/no/such/haro/dir" } }, faces: [], stamp: "", notice: "" };
	assert w.startIn(true, "/home/me") === null;
	assert w.error == "workingDirectory /no/such/haro/dir does not exist, so the shell starts where Haro was started";
	const here = cwd();
	w.loaded.config.workingDirectory = { kind: StartKind.Path, path: here };
	w.error = "";
	assert w.startIn(true, "/home/me") == here;
	assert w.error == "";
}

test "a config file that disappears keeps the last config and says so once" {
	const w = ConfigWatch.forFile("/no/such/haro/config.ms");
	w.loaded = { config: { ...defaults(), fontSize: 20 }, faces: [], stamp: "seen", notice: "" };
	let calls = 0;
	let said = "";
	const handler = (c: Config | null, error: string): void => {
		calls++;
		assert c === null;
		said = error;
	};
	w.poll(handler);
	assert calls == 1;
	assert said.includes("is gone");
	assert w.loaded.config.fontSize == 20;
	w.poll(handler);
	assert calls == 1;
}

test "a changed config file is handed over, and one with an error keeps the last config until it is fixed" {
	const dir = `${cwd()}/out/watchedConfig`;
	assert ensureDir(dir).ok;
	const path = `${dir}/config.ms`;
	const head = `import { HaroConfig } from "haro";\n\nexport const config: HaroConfig = `;
	assert writeFile(path, `${head}{ fontSize: 13 };\n`).ok;
	const w = ConfigWatch.forFile(path);
	w.readConfig();
	assert w.error == "";
	assert w.loaded.config.fontSize == 13;
	let calls = 0;
	let handed: Config | null = null;
	let said = "";
	const handler = (c: Config | null, error: string): void => {
		calls++;
		handed = c;
		said = error;
	};
	w.poll(handler);
	assert calls == 0;
	assert writeFile(path, `${head}{ fontSize: 150 };\n`).ok;
	w.poll(handler);
	assert calls == 1;
	const changed = handed;
	assert changed !== null;
	if (changed !== null) { assert changed.fontSize == 150; }
	assert writeFile(path, `${head}{ fontSiz: 13 };\n`).ok;
	w.poll(handler);
	assert calls == 2;
	assert handed === null;
	assert said.includes("fontSiz");
	assert w.loaded.config.fontSize == 150;
	w.poll(handler);
	assert calls == 2;
	assert writeFile(path, `${head}{ fontSize: 21 };\n`).ok;
	w.poll(handler);
	assert calls == 3;
	const fixed = handed;
	assert fixed !== null;
	if (fixed !== null) { assert fixed.fontSize == 21; }
}
