import { env, execFileCapture, findOnPath } from "std/process";
import { changeStamp, ensureDir, exists, readFile, writeFile } from "std/fs";
import { relative } from "std/fs/path";
import { Config, defaults, parse } from "./config";
import { Faces, installedFaces } from "./fonts";

export interface Loaded {
	config: Config;
	faces: Faces | null;
	stamp: string;
}

export function configPath(): string {
	return `${env.get("USERPROFILE").replaceAll("\\", "/")}/.config/haro/config.ms`;
}

function cacheDir(): string {
	return `${env.get("LOCALAPPDATA").replaceAll("\\", "/")}/haro`;
}

export function stampOf(path: string): string {
	return exists(path) ? changeStamp(path) : "";
}

function withoutStyles(text: string): string {
	let out = "";
	let i = 0;
	while (i < text.length) {
		if (text[i] == "\x1b" && i + 1 < text.length && text[i + 1] == "[") {
			i += 2;
			while (i < text.length && !(text[i] >= "@" && text[i] <= "~")) { i++; }
			i++;
			continue;
		}
		out += text[i];
		i++;
	}
	return out;
}

function lastLine(text: string): string {
	const lines = text.trim().split("\n");
	return lines[lines.length - 1].trim();
}

function evaluate(path: string, dir: string): Result<string, string> {
	const msc = findOnPath("msc");
	if (msc == "") { return Result.err("running config.ms needs msc on PATH"); }
	const target = relative(dir, path);
	const from = target.startsWith(".") || target.indexOf(":") > 0 ? target : `./${target}`;
	const runner = `import { config } from ${JSON.stringify(from)};\nconsole.log(JSON.stringify(config));\n`;
	if (!writeFile(`${dir}/evaluate.ms`, runner).ok) { return Result.err(`cannot write ${dir}/evaluate.ms`); }
	const ran = execFileCapture(msc, ["run", "--target=raiser", "evaluate.ms"], dir);
	if (!ran.ok) { return Result.err(withoutStyles(`${ran.error.output}${ran.error.errorOutput}`).trim()); }
	return Result.ok(lastLine(ran.value));
}

function facesFor(c: Config): Result<Faces | null, string> {
	const family = c.fontFamily;
	if (family === null) { return Result.ok(null); }
	const found = installedFaces(family);
	if (!found.ok) { return Result.err(found.error); }
	return Result.ok(found.value);
}

function cached(lines: string[], stamp: string): Loaded | null {
	if (lines.length != 6 || lines[0] != stamp) { return null; }
	const c = parse(lines[1]);
	if (!c.ok) { return null; }
	const regular = lines[2];
	if (regular == "") { return { config: c.value, faces: null, stamp: stamp }; }
	const faces: Faces = {
		regular: regular,
		bold: lines[3] == "" ? null : lines[3],
		italic: lines[4] == "" ? null : lines[4],
		boldItalic: lines[5] == "" ? null : lines[5],
	};
	return { config: c.value, faces: faces, stamp: stamp };
}

export function load(path: string): Result<Loaded, string> {
	const stamp = stampOf(path);
	if (stamp == "") { return Result.ok({ config: defaults(), faces: null, stamp: "" }); }
	const dir = cacheDir();
	const cacheFile = `${dir}/config.cache`;
	const previous = readFile(cacheFile);
	if (previous.ok) {
		const hit = cached(previous.value.split("\n"), stamp);
		if (hit !== null) { return Result.ok(hit); }
	}
	if (!ensureDir(dir).ok) { return Result.err(`cannot create ${dir}`); }
	const json = try evaluate(path, dir);
	const c = parse(json);
	if (!c.ok) { return Result.err(c.error); }
	const faces = try facesFor(c.value);
	const record = [
		stamp, json, faces?.regular ?? "", faces?.bold ?? "", faces?.italic ?? "", faces?.boldItalic ?? "",
	];
	if (!writeFile(cacheFile, record.join("\n")).ok) { return Result.err(`cannot write ${cacheFile}`); }
	return Result.ok({ config: c.value, faces: faces, stamp: stamp });
}

test "styles in the compiler's diagnostics are dropped, the text kept" {
	assert withoutStyles("\x1b[1m\x1b[31merror\x1b[0m: bad") == "error: bad";
	assert withoutStyles("plain") == "plain";
}

test "the evaluated config is the last line printed" {
	assert lastLine("note\n{\"a\":1}\n") == "{\"a\":1}";
	assert lastLine("{}") == "{}";
}
