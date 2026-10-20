import { cwd } from "std/process";
when (!macos) {
	import { env } from "std/process";
}
import { homeDir } from "std/os";
import { changeStamp, ensureDir, exists, readFile, writeFile } from "std/fs";
import { dirname, isAbsolute, relative } from "std/fs/path";
import { Config, defaults, parse } from "./config";
import { Faces, installedFaces } from "./fonts";
import {
	callRoutine,
	createInterpreter,
	evalModule,
	selectRoutine,
	unboxString,
} from "../../../../.metascript/src/embed/index";

export interface Loaded {
	config: Config;
	faces: Vec<Faces>;
	stamp: string;
	notice: string;
}

export function empty(this typeof Loaded): Loaded {
	return { config: defaults(), faces: [], stamp: "", notice: "" };
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

function packagesOf(api: string): string {
	return `const config = { deps: { "haro": ${JSON.stringify(`file:${api}`)} } };\n` +
		"export default config;\n";
}

function evaluate(path: string, dir: string, api: string): Result<string, string> {
	const target = relative(dir, path);
	const importPath = target.startsWith(".") || isAbsolute(target) ? target : `./${target}`;
	const runner = `import { config } from ${JSON.stringify(importPath)};\n` +
		"export function configJson(): string { return JSON.stringify(config); }\n";
	if (!writeFile(`${dir}/evaluate.ms`, runner).ok) {
		return Result.err(`cannot write ${dir}/evaluate.ms`);
	}
	const beside = `${dirname(path)}/build.ms`;
	if (!exists(beside)) { const _written = writeFile(beside, packagesOf(api)); }
	const made = createInterpreter(`${homeDir().replaceAll("\\", "/")}/.metascript`, [dirname(api)]);
	if (!made.ok) {
		return Result.err(`running config.ms needs MetaScript installed: ${made.error}`);
	}
	const interp = made.value;
	const ran = evalModule(interp, `${dir}/evaluate.ms`);
	if (!ran.ok) {
		return Result.err(ran.error.map(
			(d) => `${d.file}${d.line > 0 ? `:${d.line}:${d.column}` : ""}: ${d.message}`,
		).join("\n"));
	}
	const routine = selectRoutine(interp, "configJson");
	if (!routine.ok) { return Result.err(routine.error); }
	const got = callRoutine(interp, routine.value, []);
	if (!got.ok) { return Result.err(got.error); }
	return Result.ok(unboxString(got.value));
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

export function load(path: string, api: string): Result<Loaded, string> {
	const stamp = changeStamp(path);
	if (stamp == "") { return Result.ok(Loaded.empty()); }
	const dir = cacheDir();
	const cacheFile = `${dir}/config.cache`;
	const previous = readFile(cacheFile);
	if (previous.ok) {
		const hit = decodeCache(previous.value.split("\n"), stamp);
		if (hit !== null) { return Result.ok(hit); }
	}
	if (!ensureDir(dir).ok) { return Result.err(`cannot create ${dir}`); }
	const json = try evaluate(path, dir, api);
	const config = try parse(json);
	const fonts = fontsFound(config.fontFamily);
	if (fonts.notice == "" && !writeFile(cacheFile, encodeCache(stamp, json, fonts.faces)).ok) {
		return Result.err(`cannot write ${cacheFile}`);
	}
	return Result.ok({ config: config, faces: fonts.faces, stamp: stamp, notice: fonts.notice });
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

test "a config typed with HaroConfig evaluates, and a misspelt field is the checker's error" {
	const dir = `${cwd()}/out/typedConfig`;
	assert ensureDir(dir).ok;
	const path = `${dir}/config.ms`;
	const api = `${cwd()}/assets/haro`;
	const head = `import { HaroConfig } from "haro";\n\nexport const config: HaroConfig = `;
	const body = `{ fontSize: 13, keybinds: [{ keys: "super+w", text: "x", mode: "alt" }] };\n`;
	assert writeFile(path, `${head}${body}`).ok;
	const typed = evaluate(path, dir, api);
	assert typed.ok;
	if (typed.ok) {
		const c = parse(typed.value);
		assert c.ok && c.value.fontSize == 13 && c.value.keybinds.length == 1;
	}
	assert exists(`${dir}/build.ms`);
	assert writeFile(path, `${head}{ fontSiz: 13 };\n`).ok;
	const misspelt = evaluate(path, dir, api);
	assert !misspelt.ok;
	if (!misspelt.ok) {
		assert misspelt.error.includes("/config.ms:3:");
		assert misspelt.error.includes("'fontSiz' does not exist in type 'HaroConfig'");
	}
}
