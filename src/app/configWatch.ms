import { Config, defaults } from "../config/config";
import { Loaded, load, stampOf } from "../config/source";

// Polled until card 2026-09-26-await-on-fs-watch-never-resumes.md lets a watch resume in an Ion window
const CONFIG_POLL_MS = 1000;

export interface ConfigWatch {
	file: string;
	loaded: Loaded;
	error: string;
}

export function forFile(this typeof ConfigWatch, file: string): ConfigWatch {
	return { file: file, loaded: { config: defaults(), faces: [], stamp: "" }, error: "" };
}

function reload(this w: ConfigWatch): Result<Config, string> {
	const got = load(w.file);
	if (!got.ok) { return Result.err(got.error); }
	w.loaded = got.value;
	return Result.ok(got.value.config);
}

export function readConfig(this w: ConfigWatch): void {
	const got = w.reload();
	if (got.ok) { return; }
	w.error = got.error;
	w.loaded.stamp = stampOf(w.file);
}

export function watchConfig(
	this w: ConfigWatch,
	handler: (c: Config | null, error: string) => void,
): void {
	setTimeout((): void => {
		const stamp = stampOf(w.file);
		if (stamp != w.loaded.stamp) {
			const got = w.reload();
			if (got.ok) {
				handler(got.value, "");
			} else {
				w.loaded.stamp = stamp;
				handler(null, got.error);
			}
		}
		w.watchConfig(handler);
	}, CONFIG_POLL_MS);
}
