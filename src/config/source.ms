import { cwd } from "std/process";
when (!macos) {
	import { env } from "std/process";
}
import { homeDir } from "std/os";
import { changeStamp, ensureDir, exists, readFile, writeFile } from "std/fs";
import { dirname, isAbsolute, relative } from "std/fs/path";
import { Config, defaults, parse } from "./config";
import { Rgb } from "../vt/vt";
import { Faces, installedFaces } from "./fonts";
import { Hooks, answerKey } from "./hooks";
import { KeyAction, KeyMod, NO_MODS, keyEvent, modSet } from "../keys/keys";
import {
	callRoutine,
	createInterpreter,
	evalModule,
	selectRoutine,
	unboxBool,
} from "../../../../.metascript/src/embed/index";

export interface Loaded {
	config: Config;
	faces: Vec<Faces>;
	stamp: string;
	notice: string;
	hooks: Hooks | null;
}

export function empty(this typeof Loaded): Loaded {
	return { config: defaults(), faces: [], stamp: "", notice: "", hooks: null };
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

interface Evaluated {
	json: string;
	hooks: Hooks | null;
}

function runnerOf(importPath: string): string {
	return `import { config as written } from ${JSON.stringify(importPath)};\n` +
		`import { HaroConfig, KeyAnswer, KeyPress } from "haro";\n` +
		"const config: HaroConfig = written;\n" +
		"export function configJson(): string {\n" +
		"\tconst { onKey: _onKey, ...settings } = config;\n" +
		"\treturn JSON.stringify(settings);\n" +
		"}\n" +
		"export function hooked(): boolean { return config.onKey !== undefined; }\n" +
		"export function onKey(e: KeyPress): KeyAnswer {\n" +
		"\tconst hook = config.onKey;\n" +
		"\treturn hook === undefined ? { handled: false } : hook(e);\n" +
		"}\n";
}

function evaluate(path: string, dir: string, api: string, metascript: string): Result<Evaluated, string> {
	const target = relative(dir, path);
	const importPath = target.startsWith(".") || isAbsolute(target) ? target : `./${target}`;
	const runner = runnerOf(importPath);
	if (!writeFile(`${dir}/evaluate.ms`, runner).ok) {
		return Result.err(`cannot write ${dir}/evaluate.ms`);
	}
	const beside = `${dirname(path)}/build.ms`;
	if (!exists(beside) && !writeFile(beside, packagesOf(api)).ok) {
		return Result.err(`cannot write ${beside}`);
	}
	const made = createInterpreter(metascript, [dirname(api)]);
	if (!made.ok) {
		return Result.err(`running config.ms needs MetaScript's std: ${made.error}`);
	}
	const interp = made.value;
	const ran = evalModule(interp, `${dir}/evaluate.ms`);
	if (!ran.ok) {
		return Result.err(ran.error.map(
			(d) => `${d.file}${d.line > 0 ? `:${d.line}:${d.column}` : ""}: ${d.message}`,
		).join("\n"));
	}
	const json = try callRoutine(interp, try selectRoutine(interp, "configJson"), []);
	const hooked = try callRoutine(interp, try selectRoutine(interp, "hooked"), []);
	const hooks: Hooks | null = unboxBool(hooked.root)
		? { interp: interp, onKey: try selectRoutine(interp, "onKey") }
		: null;
	return Result.ok({ json: json.text(), hooks: hooks });
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
	return { config: c.value, faces: faces, stamp: stamp, notice: "", hooks: null };
}

export function load(path: string, api: string, metascript: string): Result<Loaded, string> {
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
	const evaluated = try evaluate(path, dir, api, metascript);
	const config = try parse(evaluated.json);
	const fonts = fontsFound(config.fontFamily);
	const cacheable = fonts.notice == "" && evaluated.hooks === null;
	const uncached = cacheable && !writeFile(cacheFile, encodeCache(stamp, evaluated.json, fonts.faces)).ok;
	const notice = uncached ? `cannot write ${cacheFile}, so the config is read again next start` : fonts.notice;
	return Result.ok({ config: config, faces: fonts.faces, stamp: stamp, notice: notice, hooks: evaluated.hooks });
}

const INSTALLED = `${homeDir().replaceAll("\\", "/")}/.metascript`;

test "a config is evaluated against the std it is given, and a missing one is named" {
	const dir = `${cwd()}/out/rootedConfig`;
	assert ensureDir(dir).ok;
	const path = `${dir}/config.ms`;
	assert writeFile(path, `export const config = { fontSize: 13 };\n`).ok;
	const missing = evaluate(path, dir, `${cwd()}/assets/haro`, `${dir}/noStd`);
	assert !missing.ok;
	if (!missing.ok) { assert missing.error.includes(`${dir}/noStd/std/core/system/index.ms`), missing.error; }
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
	const body = `{ fontSize: 13, keybinds: [{ keys: "super+w", text: "x", mode: "alt" }, ` +
		`{ keys: "super+q", action: "close_window", mode: "~alt" }] };\n`;
	assert writeFile(path, `${head}${body}`).ok;
	const typed = evaluate(path, dir, api, INSTALLED);
	assert typed.ok;
	if (typed.ok) {
		const c = parse(typed.value.json);
		assert c.ok && c.value.fontSize == 13 && c.value.keybinds.length == 2;
	}
	assert exists(`${dir}/build.ms`);
	assert writeFile(path, `${head}{ fontSiz: 13 };\n`).ok;
	const misspelt = evaluate(path, dir, api, INSTALLED);
	assert !misspelt.ok;
	if (!misspelt.ok) {
		assert misspelt.error.includes("/config.ms:3:");
		assert misspelt.error.includes("'fontSiz' does not exist in type 'HaroConfig'");
	}
	assert writeFile(path, `${head}{ keybinds: [{ keys: "a", text: "x", mode: "Alt" }] };\n`).ok;
	const wrongMode = evaluate(path, dir, api, INSTALLED);
	assert !wrongMode.ok;
	if (!wrongMode.ok) { assert wrongMode.error.includes("/config.ms:3:"), wrongMode.error; }
}

test "a config spreads saigonNight from the haro package and keeps its own fields over it" {
	const dir = `${cwd()}/out/themedConfig`;
	assert ensureDir(dir).ok;
	const path = `${dir}/config.ms`;
	const config = `import { HaroConfig, saigonNight } from "haro";\n\nexport const config: HaroConfig = { ...saigonNight, fontSize: 13 };\n`;
	assert writeFile(path, config).ok;
	const themed = evaluate(path, dir, `${cwd()}/assets/haro`, INSTALLED);
	assert themed.ok;
	if (themed.ok) {
		const c = parse(themed.value.json);
		const background: Rgb = { r: 22, g: 22, b: 30 };
		const brightWhite: Rgb = { r: 172, g: 176, b: 208 };
		assert c.ok && c.value.fontSize == 13 && c.value.background == background;
		assert c.ok && c.value.palette.length == 16 && c.value.palette[15] == brightWhite;
	}
}

test "an onKey in config.ms answers the keys it handles and lets the rest through" {
	const dir = `${cwd()}/out/hookedConfig`;
	assert ensureDir(dir).ok;
	const path = `${dir}/config.ms`;
	const config = `import { HaroConfig } from "haro";\n\nexport const config: HaroConfig = {\n` +
		`\tfontSize: 13,\n` +
		`\tonKey: (e) => e.code == "KeyK" && e.super ? { handled: true, send: "clear\\n" } : { handled: false },\n};\n`;
	assert writeFile(path, config).ok;
	const hooked = evaluate(path, dir, `${cwd()}/assets/haro`, INSTALLED);
	assert hooked.ok, hooked.ok ? "" : hooked.error;
	if (!hooked.ok) { return; }
	const c = parse(hooked.value.json);
	assert c.ok && c.value.fontSize == 13;
	const hooks = hooked.value.hooks;
	assert hooks !== null;
	if (hooks === null) { return; }
	const superK = hooks.answerKey(keyEvent(KeyAction.Press, "KeyK", modSet(KeyMod.Super)));
	assert superK.ok && superK.value.handled && superK.value.send == "clear\n";
	const plainK = hooks.answerKey(keyEvent(KeyAction.Press, "KeyK", NO_MODS));
	assert plainK.ok && !plainK.value.handled && plainK.value.send == "";
	assert writeFile(path, `import { HaroConfig } from "haro";\n\nexport const config: HaroConfig = { fontSize: 13 };\n`).ok;
	const plain = evaluate(path, dir, `${cwd()}/assets/haro`, INSTALLED);
	assert plain.ok && plain.value.hooks === null;
}
