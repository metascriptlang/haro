import { changeStamp } from "std/fs";
import { Config, defaults } from "../config/config";
import { Loaded, empty, load } from "../config/source";
import { resourcePath } from "../../../ion/src/index";
import { cwd } from "std/process";

// Polled until card 2026-09-26-await-on-fs-watch-never-resumes.md lets a watch resume in an Ion window
const CONFIG_POLL_MS = 1000;
const API = resourcePath() == ""
	? `${cwd().replaceAll("\\", "/")}/assets/haro`
	: `${resourcePath().replaceAll("\\", "/")}/assets/haro`;

export interface ConfigWatch {
	file: string;
	loaded: Loaded;
	error: string;
}

export function forFile(this typeof ConfigWatch, file: string): ConfigWatch {
	return { file: file, loaded: Loaded.empty(), error: "" };
}

function reload(this w: ConfigWatch): Result<Config, string> {
	const got = try load(w.file, API);
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
	w.loaded.stamp = changeStamp(w.file);
}

function poll(this w: ConfigWatch, handler: (c: Config | null, error: string) => void): void {
	const stamp = changeStamp(w.file);
	if (stamp == w.loaded.stamp) { return; }
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

export function watchConfig(
	this w: ConfigWatch,
	handler: (c: Config | null, error: string) => void,
): void {
	setTimeout((): void => {
		w.poll(handler);
		w.watchConfig(handler);
	}, CONFIG_POLL_MS);
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
