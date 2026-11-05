import { ensureDir, exists, readFile, removeAll, rename, writeFile } from "std/fs";
import { dirname, join } from "std/fs/path";
import { tmpDir } from "std/os";
import { JSON } from "std/core/json";
import { RemoteHost, parse } from "../config/config";
import { Dial } from "./link";
import { stateDir } from "../server/cli";

export interface HostBook {
	path: string;
	dial: (address: string) => Dial;
}

export function keptHostsPath(): string {
	return `${stateDir()}/hosts.json`;
}

export function readKept(path: string): Result<Vec<RemoteHost>, string> {
	if (path == "" || !exists(path)) { return Result.ok([]); }
	const text = readFile(path);
	if (!text.ok) { return Result.err(`${path} could not be read: ${text.error.toString()}`); }
	const read = parse(text.value);
	if (!read.ok) { return Result.err(`${path}: ${read.error}`); }
	return Result.ok(read.value.remoteHosts);
}

function keptText(hosts: RemoteHost[]): string {
	const rows = hosts.map((h: RemoteHost): string =>
		`{"label":${JSON.stringify(h.label)},"address":${JSON.stringify(h.address)}}`
	);
	return `{"remoteHosts":[${rows.join(",")}]}\n`;
}

export function writeKept(path: string, hosts: RemoteHost[]): Result<void, string> {
	if (path == "") { return Result.ok(null); }
	const made = ensureDir(dirname(path));
	if (!made.ok) { return Result.err(`${dirname(path)} could not be made: ${made.error.toString()}`); }
	const fresh = `${path}.new`;
	const wrote = writeFile(fresh, keptText(hosts));
	if (!wrote.ok) { return Result.err(`${fresh} could not be written: ${wrote.error.toString()}`); }
	const moved = rename(fresh, path);
	if (!moved.ok) { return Result.err(`${path} could not be replaced: ${moved.error.toString()}`); }
	return Result.ok(null);
}

test "kept hosts read back as written, a missing file holds none, and a bad entry is refused" {
	const dir = join(tmpDir(), `haro-kept-${Date.now()}`);
	const path = join(join(dir, "state"), "hosts.json");
	const none = readKept(path);
	assert none.ok && none.value.length == 0;
	assert writeKept(path, [{ label: "build", address: "me@build" }, { label: "gpu \"x\"", address: "gpu" }]).ok;
	const two = readKept(path);
	assert two.ok;
	if (two.ok) {
		assert two.value.length == 2;
		assert two.value[0].label == "build" && two.value[0].address == "me@build";
		assert two.value[1].label == "gpu \"x\"";
	}
	assert writeFile(path, `{"remoteHosts":[{"label":"b","address":"-x"}]}`).ok;
	assert !readKept(path).ok;
	assert readKept("").ok;
	const _removed = removeAll(dir);
}
