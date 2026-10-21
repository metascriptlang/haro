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
	notice: string;
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

function isCsiFinal(c: string): boolean {
	return c >= "@" && c <= "~";
}

function withoutStyles(text: string): string {
	let out = "";
	for (let i = 0; i < text.length; i++) {
		if (text[i] == "\x1b" && i + 1 < text.length && text[i + 1] == "[") {
			i += 2;
			while (i < text.length && !isCsiFinal(text[i])) { i++; }
			continue;
		}
		out += text[i];
	}
	return out;
}

function lastLine(text: string): string {
	const lines = text.trim().split("\n");
	return lines[lines.length - 1].trim();
}

function evaluate(path: string, dir: string): Result<string, string> {
	const installedMsc = `${homeDir()}/.metascript/bin/msc`;
	const onPath = findOnPath("msc");
	const msc = onPath != "" ? onPath : exists(installedMsc) ? installedMsc : "";
	if (msc == "") {
		return Result.err(`running config.ms needs msc on PATH or at ${installedMsc}`);
	}
	const target = relative(dir, path);
	const importPath = target.startsWith(".") || target.indexOf(":") > 0 ? target : `./${target}`;
	const runner = `import { config } from ${JSON.stringify(importPath)};\n` +
		"console.log(JSON.stringify(config));\n";
	if (!writeFile(`${dir}/evaluate.ms`, runner).ok) {
		return Result.err(`cannot write ${dir}/evaluate.ms`);
	}
	const ran = execFileCapture(msc, ["run", "--target=raiser", "evaluate.ms"], dir);
	if (!ran.ok) {
		return Result.err(withoutStyles(`${ran.error.output}${ran.error.errorOutput}`).trim());
	}
	return Result.ok(lastLine(ran.value));
}

interface FontsFound {
	faces: Vec<Faces>;
	notice: string;
}

function fontsFound(families: Vec<string>): FontsFound {
	let faces: Vec<Faces> = [];
	let missing: string[] = [];
	for (const family of families) {
		const found = installedFaces(family);
		if (found.ok) {
			faces.push(found.value);
		} else {
			missing.push(found.error);
		}
	}
	const notice = missing.length == 0 ? "" : `${missing.join("; ")}, so the next font in line draws instead`;
	return { faces: faces, notice: notice };
}

const LINES_PER_FAMILY = 4;

function encodeCache(stamp: string, json: string, faces: Vec<Faces>): string {
	let lines = [stamp, json];
	for (const f of faces) {
		for (const path of [f.regular, f.bold ?? "", f.italic ?? "", f.boldItalic ?? ""]) {
			lines.push(path);
		}
	}
	return lines.join("\n");
}

function pathOrNull(line: string): string | null {
	return line == "" ? null : line;
}

function decodeCache(lines: string[], stamp: string): Loaded | null {
	if (lines.length < 2 || lines[0] != stamp) { return null; }
	const c = parse(lines[1]);
	if (!c.ok || lines.length != 2 + c.value.fontFamily.length * LINES_PER_FAMILY) { return null; }
	let faces: Vec<Faces> = [];
	for (let at = 2; at < lines.length; at += LINES_PER_FAMILY) {
		faces.push({
			regular: lines[at],
			bold: pathOrNull(lines[at + 1]),
			italic: pathOrNull(lines[at + 2]),
			boldItalic: pathOrNull(lines[at + 3]),
		});
	}
	return { config: c.value, faces: faces, stamp: stamp, notice: "" };
}

export function load(path: string): Result<Loaded, string> {
	const stamp = stampOf(path);
	if (stamp == "") { return Result.ok({ config: defaults(), faces: [], stamp: "", notice: "" }); }
	const dir = cacheDir();
	const cacheFile = `${dir}/config.cache`;
	const previous = readFile(cacheFile);
	if (previous.ok) {
		const hit = decodeCache(previous.value.split("\n"), stamp);
		if (hit !== null) { return Result.ok(hit); }
	}
	if (!ensureDir(dir).ok) { return Result.err(`cannot create ${dir}`); }
	const json = try evaluate(path, dir);
	const config = try parse(json);
	const fonts = fontsFound(config.fontFamily);
	if (fonts.notice == "" && !writeFile(cacheFile, encodeCache(stamp, json, fonts.faces)).ok) {
		return Result.err(`cannot write ${cacheFile}`);
	}
	return Result.ok({ config: config, faces: fonts.faces, stamp: stamp, notice: fonts.notice });
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

test "a font family that is not installed is skipped with a notice naming it" {
	const found = fontsFound(["No Such Family Haro"]);
	assert found.faces.length == 0;
	assert found.notice.includes(`"No Such Family Haro"`);
	assert found.notice.endsWith("so the next font in line draws instead");
	assert fontsFound([]).notice == "";
}

when (windows) {
	test "the families that are installed still load beside one that is not" {
		const found = fontsFound(["No Such Family Haro", "segoe ui"]);
		assert found.faces.length == 1;
		assert found.faces[0].regular.toLowerCase().endsWith("/segoeui.ttf");
		assert found.notice.includes(`"No Such Family Haro"`);
	}
}
