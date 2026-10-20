import { execFileCapture, findOnPath } from "std/process";
when (!macos) {
	import { env } from "std/process";
}
import { homeDir } from "std/os";
import { changeStamp, ensureDir, exists, readFile, writeFile } from "std/fs";
import { relative } from "std/fs/path";
import { Config, defaults, parse } from "./config";
import { Faces, installedFaces } from "./fonts";

export interface Loaded {
	config: Config;
	faces: Vec<Faces>;
	stamp: string;
}

export function configPath(): string {
	return `${homeDir().replaceAll("\\", "/")}/.config/haro/config.ms`;
}

export function cacheDir(): string {
	when (windows) {
		return `${env.get("LOCALAPPDATA").replaceAll("\\", "/")}/haro`;
	} else when (macos) {
		return `${homeDir()}/Library/Caches/haro`;
	} else {
		const xdg = env.get("XDG_CACHE_HOME");
		return `${xdg != "" ? xdg : `${homeDir()}/.cache`}/haro`;
	}
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
	const installedMsc = `${homeDir()}/.metascript/bin/msc`;
	const msc = findOnPath("msc") != "" ? findOnPath("msc") : exists(installedMsc) ? installedMsc : "";
	if (msc == "") { return Result.err(`running config.ms needs msc on PATH or at ${installedMsc}`); }
	const target = relative(dir, path);
	const importPath = target.startsWith(".") || target.indexOf(":") > 0 ? target : `./${target}`;
	const runner = `import { config } from ${JSON.stringify(importPath)};\nconsole.log(JSON.stringify(config));\n`;
	if (!writeFile(`${dir}/evaluate.ms`, runner).ok) { return Result.err(`cannot write ${dir}/evaluate.ms`); }
	const ran = execFileCapture(msc, ["run", "--target=raiser", "evaluate.ms"], dir);
	if (!ran.ok) { return Result.err(withoutStyles(`${ran.error.output}${ran.error.errorOutput}`).trim()); }
	return Result.ok(lastLine(ran.value));
}

function facesFor(c: Config): Result<Vec<Faces>, string> {
	let faces: Vec<Faces> = [];
	for (const family of c.fontFamily) { faces.push(try installedFaces(family)); }
	return Result.ok(faces);
}

const LINES_PER_FAMILY = 4;

function encodeCache(stamp: string, json: string, faces: Vec<Faces>): string {
	let lines = [stamp, json];
	for (const f of faces) {
		for (const path of [f.regular, f.bold ?? "", f.italic ?? "", f.boldItalic ?? ""]) { lines.push(path); }
	}
	return lines.join("\n");
}

function decodeCache(lines: string[], stamp: string): Loaded | null {
	if (lines.length < 2 || lines[0] != stamp) { return null; }
	const c = parse(lines[1]);
	if (!c.ok || lines.length != 2 + c.value.fontFamily.length * LINES_PER_FAMILY) { return null; }
	let faces: Vec<Faces> = [];
	for (let at = 2; at < lines.length; at += LINES_PER_FAMILY) {
		faces.push({
			regular: lines[at],
			bold: lines[at + 1] == "" ? null : lines[at + 1],
			italic: lines[at + 2] == "" ? null : lines[at + 2],
			boldItalic: lines[at + 3] == "" ? null : lines[at + 3],
		});
	}
	return { config: c.value, faces: faces, stamp: stamp };
}

export function load(path: string): Result<Loaded, string> {
	const stamp = stampOf(path);
	if (stamp == "") { return Result.ok({ config: defaults(), faces: [], stamp: "" }); }
	const dir = cacheDir();
	const cacheFile = `${dir}/config.cache`;
	const previous = readFile(cacheFile);
	if (previous.ok) {
		const hit = decodeCache(previous.value.split("\n"), stamp);
		if (hit !== null) { return Result.ok(hit); }
	}
	if (!ensureDir(dir).ok) { return Result.err(`cannot create ${dir}`); }
	const json = try evaluate(path, dir);
	const c = parse(json);
	if (!c.ok) { return Result.err(c.error); }
	const faces = try facesFor(c.value);
	if (!writeFile(cacheFile, encodeCache(stamp, json, faces)).ok) { return Result.err(`cannot write ${cacheFile}`); }
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

test "a cached record gives back each family's faces in order" {
	const json = "{\"fontFamily\":[\"A\",\"B\"]}";
	const faces: Vec<Faces> = [
		{ regular: "/a.otf", bold: null, italic: "/ai.otf", boldItalic: null },
		{ regular: "/b.otf", bold: "/bb.otf", italic: null, boldItalic: "/bbi.otf" },
	];
	const hit = decodeCache(encodeCache("s1", json, faces).split("\n"), "s1");
	assert hit !== null;
	if (hit !== null) {
		assert hit.faces.length == 2;
		assert hit.faces[0].italic == "/ai.otf";
		assert hit.faces[0].bold === null;
		assert hit.faces[1].boldItalic == "/bbi.otf";
	}
	assert decodeCache(encodeCache("s1", json, faces).split("\n"), "s2") === null;
	assert decodeCache(encodeCache("s1", json, [faces[0]]).split("\n"), "s1") === null;
}
