import { cwd } from "std/process";
when (!macos) {
	import { env } from "std/process";
}
import { homeDir } from "std/os";
import { changeStamp, ensureDir, exists, readFile, remove, rename, writeFile } from "std/fs";
import { dirname, isAbsolute, relative } from "std/fs/path";
import { Config, defaults, parse } from "./config";
import { CommandDone, Rgb } from "../vt/vt";
import { RowNote, RowTint } from "../grid/lines";
import { Faces, installedFaces } from "./fonts";
import {
	HookPane,
	Hooks,
	answerKey,
	calledOutsideHooks,
	commandDone,
	implementRoutines,
	prompted,
} from "./hooks";
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

function windowsCacheDir(localAppData: string, home: string): string {
	const base = localAppData != "" ? localAppData : `${home}/AppData/Local`;
	return `${base.replaceAll("\\", "/")}/haro`;
}

export function cacheDir(): string {
	when (windows) {
		return windowsCacheDir(env.get("LOCALAPPDATA"), homeDir().replaceAll("\\", "/"));

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
		`import { CommandDone, HaroConfig, KeyAnswer, KeyPress, Prompt } from "haro";\n` +
		"const config: HaroConfig = written;\n" +
		"export function configJson(): string {\n" +
		"\tconst { onKey: _onKey, onPrompt: _onPrompt, onCommandDone: _onCommandDone, ...settings } = config;\n" +
		"\treturn JSON.stringify(settings);\n" +
		"}\n" +
		"export function hooked(): boolean {\n" +
		"\treturn config.onKey !== undefined || config.onPrompt !== undefined ||\n" +
		"\t\tconfig.onCommandDone !== undefined;\n" +
		"}\n" +
		"export function onKey(e: KeyPress): KeyAnswer {\n" +
		"\tconst hook = config.onKey;\n" +
		"\treturn hook === undefined ? { handled: false } : hook(e);\n" +
		"}\n" +
		"export function onPrompt(e: Prompt): void {\n" +
		"\tconst hook = config.onPrompt;\n" +
		"\tif (hook !== undefined) { hook(e); }\n" +
		"}\n" +
		"export function onCommandDone(e: CommandDone): void {\n" +
		"\tconst hook = config.onCommandDone;\n" +
		"\tif (hook !== undefined) { hook(e); }\n" +
		"}\n";
}

function writeAtomically(path: string, content: string): Result<void, string> {
	const temp = `${path}.${Date.now()}.${performance.now()}.tmp`;
	if (!writeFile(temp, content).ok) { return Result.err(`cannot write ${path}`); }
	if (!rename(temp, path).ok) {
		const _abandoned = remove(temp);
		return Result.err(`cannot write ${path}`);
	}
	return Result.ok(null);
}

function evaluate(path: string, dir: string, api: string, metascript: string): Result<Evaluated, string> {
	const target = relative(dir, path);
	const importPath = target.startsWith(".") || isAbsolute(target) ? target : `./${target}`;
	const runner = runnerOf(importPath);
	try writeAtomically(`${dir}/evaluate.ms`, runner);
	const beside = `${dirname(path)}/build.ms`;
	if (!exists(beside)) { try writeAtomically(beside, packagesOf(api)); }
	const made = createInterpreter(metascript, [dirname(api)]);
	if (!made.ok) {
		return Result.err(`running config.ms needs MetaScript's std: ${made.error}`);
	}
	const interp = made.value;
	implementRoutines();
	const ran = evalModule(interp, `${dir}/evaluate.ms`);
	if (!ran.ok) {
		return Result.err(ran.error.map(
			(d) => `${d.file}${d.line > 0 ? `:${d.line}:${d.column}` : ""}: ${d.message}`,
		).join("\n"));
	}
	const json = try callRoutine(interp, try selectRoutine(interp, "configJson"), []);
	const hooked = try callRoutine(interp, try selectRoutine(interp, "hooked"), []);
	try calledOutsideHooks();
	const hooks: Hooks | null = unboxBool(hooked.root)
		? {
			interp: interp,
			onKey: try selectRoutine(interp, "onKey"),
			onPrompt: try selectRoutine(interp, "onPrompt"),
			onCommandDone: try selectRoutine(interp, "onCommandDone"),
		}
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
	const uncached = cacheable &&
		!writeAtomically(cacheFile, encodeCache(stamp, evaluated.json, fonts.faces)).ok;
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

test "Windows keeps its cache under the home directory when LOCALAPPDATA is unset" {
	assert windowsCacheDir("C:\\Users\\me\\AppData\\Local", "C:/Users/me") == "C:/Users/me/AppData/Local/haro";
	assert windowsCacheDir("", "C:/Users/me") == "C:/Users/me/AppData/Local/haro";
}

test "a file is written whole under its name, with no temporary file left beside it" {
	const dir = `${cwd()}/out/atomicWrite`;
	assert ensureDir(dir).ok;
	assert writeFile(`${dir}/f.txt`, "old").ok;
	assert writeAtomically(`${dir}/f.txt`, "new").ok;
	const read = readFile(`${dir}/f.txt`);
	assert read.ok && read.value == "new";
	assert readDir(dir).length == 1;
	assert !writeAtomically(`${dir}/missing/f.txt`, "x").ok;
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
	const superK = hooks.answerKey(UNHEARD, keyEvent(KeyAction.Press, "KeyK", modSet(KeyMod.Super)));
	assert superK.ok && superK.value.handled && superK.value.send == "clear\n";
	const plainK = hooks.answerKey(UNHEARD, keyEvent(KeyAction.Press, "KeyK", NO_MODS));
	assert plainK.ok && !plainK.value.handled && plainK.value.send == "";
	assert writeFile(path, `import { HaroConfig } from "haro";\n\nexport const config: HaroConfig = { fontSize: 13 };\n`).ok;
	const plain = evaluate(path, dir, `${cwd()}/assets/haro`, INSTALLED);
	assert plain.ok && plain.value.hooks === null;
}

test "an onCommandDone in config.ms gets the exit code, command and duration, and a throw is its error" {
	const dir = `${cwd()}/out/shellHookConfig`;
	assert ensureDir(dir).ok;
	const path = `${dir}/config.ms`;
	const config = `import { HaroConfig } from "haro";\n\nexport const config: HaroConfig = {\n` +
		`\tfontSize: 13,\n` +
		`\tonPrompt: () => {},\n` +
		`\tonCommandDone: (e) => {\n` +
		`\t\tif (e.exitCode === undefined) { throw new Error(\`no code for \${e.command}\`); }\n` +
		`\t\tif (e.exitCode != 0) { throw new Error(\`\${e.command} \${e.exitCode} \${e.durationMs}\`); }\n` +
		`\t},\n};\n`;
	assert writeFile(path, config).ok;
	const hooked = evaluate(path, dir, `${cwd()}/assets/haro`, INSTALLED);
	assert hooked.ok, hooked.ok ? "" : hooked.error;
	if (!hooked.ok) { return; }
	const c = parse(hooked.value.json);
	assert c.ok && c.value.fontSize == 13;
	const hooks = hooked.value.hooks;
	assert hooks !== null;
	if (hooks === null) { return; }
	assert hooks.prompted(UNHEARD, 0).ok;
	assert hooks.commandDone(UNHEARD, ran(0, "make", 12.5)).ok;
	const failed = hooks.commandDone(UNHEARD, ran(2, "make", 12.5));
	assert !failed.ok && failed.error.includes("make 2 12.5"), failed.ok ? "" : failed.error;
	const unknown = hooks.commandDone(UNHEARD, ran(null, "", null));
	assert !unknown.ok && unknown.error.includes("no code for"), unknown.ok ? "" : unknown.error;
}

function ran(exitCode: int32 | null, command: string, durationMs: float64 | null): CommandDone {
	return {
		exitCode: exitCode,
		command: command,
		durationMs: durationMs,
		prompt: null,
		output: null,
		end: 0,
	};
}

const UNHEARD: HookPane = {
	send: (text: string): void => {},
	notify: (title: string, body: string): void => {},
	decorate: (from: int32, to: int32, tint: RowTint): int32 => -1,
	undecorate: (id: int32): void => {},
	annotate: (at: int32, note: RowNote): int32 => -1,
	unannotate: (id: int32): void => {},
};

interface Heard {
	said: Vec<string>;
}

function paneHeard(heard: Heard): HookPane {
	return {
		send: (text: string): void => { heard.said.push(`send ${text}`); },
		notify: (title: string, body: string): void => { heard.said.push(`notify ${title}|${body}`); },
		decorate: (from: int32, to: int32, tint: RowTint): int32 => {
			heard.said.push(`decorate ${from}..${to} ${tintText(tint.bg)} ${tintText(tint.fg)}`);
			return 40 + (heard.said.length as int32);
		},
		undecorate: (id: int32): void => { heard.said.push(`undecorate ${id}`); },
		annotate: (at: int32, note: RowNote): int32 => {
			const colours = `${tintText(note.fg)} ${tintText(note.bg)}`;
			heard.said.push(`annotate ${at} ${note.text} ${colours}`);
			return 40 + (heard.said.length as int32);
		},
		unannotate: (id: int32): void => { heard.said.push(`unannotate ${id}`); },
	};
}

function tintText(c: Rgb | null): string {
	return c === null ? "-" : `${c.r},${c.g},${c.b}`;
}

test "an onCommandDone that calls send and notify reaches the pane it runs for, and a call outside a hook is the config's error" {
	const dir = `${cwd()}/out/routineConfig`;
	assert ensureDir(dir).ok;
	const path = `${dir}/config.ms`;
	const head = `import { HaroConfig, notify, send } from "haro";\n\n`;
	assert writeFile(path, `${head}export const config: HaroConfig = {\n` +
		`\tonCommandDone: (e) => {\n` +
		`\t\tsend(\`echo \${e.command}\\n\`);\n` +
		`\t\tnotify(e.command, \`exit \${e.exitCode}\`);\n` +
		`\t},\n};\n`).ok;
	const hooked = evaluate(path, dir, `${cwd()}/assets/haro`, INSTALLED);
	assert hooked.ok, hooked.ok ? "" : hooked.error;
	if (!hooked.ok) { return; }
	const hooks = hooked.value.hooks;
	assert hooks !== null;
	if (hooks === null) { return; }
	const heard: Heard = { said: [] };
	assert hooks.commandDone(paneHeard(heard), ran(2, "make", 1.5)).ok;
	assert heard.said.join("|") == "send echo make\n|notify make|exit 2", heard.said.join("|");
	assert calledOutsideHooks().ok;

	assert writeFile(path, `${head}send("ls\\n");\nexport const config: HaroConfig = { fontSize: 13 };\n`).ok;
	const outside = evaluate(path, dir, `${cwd()}/assets/haro`, INSTALLED);
	assert !outside.ok;
	if (!outside.ok) {
		assert outside.error == "config.ms called send outside a hook, and send acts only on the pane a hook runs for",
			outside.error;
	}
}

test "an onCommandDone that decorates reaches the pane with its anchors and colours, and a bad colour is the hook's error" {
	const dir = `${cwd()}/out/decorateConfig`;
	assert ensureDir(dir).ok;
	const path = `${dir}/config.ms`;
	const head = `import { HaroConfig, decorate, undecorate } from "haro";\n\n`;
	assert writeFile(path, `${head}let last = -1;\nexport const config: HaroConfig = {\n` +
		`\tonPrompt: (e) => { if (last >= 0 && e.at > 100) { undecorate(last); } },\n` +
		`\tonCommandDone: (e) => {\n` +
		`\t\tif (e.prompt === undefined) { return; }\n` +
		`\t\tconst background = e.exitCode == 2 ? "#3a1c24" : "red";\n` +
		`\t\tlast = decorate({ from: e.prompt, to: e.end, background: background });\n` +
		`\t\tdecorate({ from: e.end, to: e.end, foreground: "#00FF00" });\n` +
		`\t},\n};\n`).ok;
	const hooked = evaluate(path, dir, `${cwd()}/assets/haro`, INSTALLED);
	assert hooked.ok, hooked.ok ? "" : hooked.error;
	if (!hooked.ok) { return; }
	const hooks = hooked.value.hooks;
	assert hooks !== null;
	if (hooks === null) { return; }
	const heard: Heard = { said: [] };
	const done: CommandDone = { ...ran(2, "make", 1.5), prompt: 3, output: 4, end: 5 };
	assert hooks.commandDone(paneHeard(heard), done).ok;
	assert hooks.prompted(paneHeard(heard), 101).ok;
	assert hooks.commandDone(paneHeard(heard), { ...ran(2, "make", 1.5), end: 9 }).ok;
	assert heard.said.join("|") == "decorate 3..5 58,28,36 -|decorate 5..5 - 0,255,0|undecorate 41",
		heard.said.join("|");
	const refused = hooks.commandDone(paneHeard(heard), { ...done, exitCode: 1 });
	assert !refused.ok;
	if (!refused.ok) {
		const expected = `decorate's background: "red" is not a #rrggbb colour`;
		assert refused.error == `onCommandDone in config.ms failed: ${expected}`, refused.error;
	}

	const topLevel = `${head}decorate({ from: 0, to: 1 });\nexport const config: HaroConfig = {};\n`;
	assert writeFile(path, topLevel).ok;
	const outside = evaluate(path, dir, `${cwd()}/assets/haro`, INSTALLED);
	assert !outside.ok;
	if (!outside.ok) {
		assert outside.error.includes("called decorate outside a hook"), outside.error;
	}
}

function hooksOf(name: string, source: string): Result<Hooks | null, string> {
	const dir = `${cwd()}/out/${name}`;
	const path = `${dir}/config.ms`;
	if (!ensureDir(dir).ok || !writeFile(path, source).ok) {
		return Result.err(`cannot write ${path}`);
	}
	const hooked = evaluate(path, dir, `${cwd()}/assets/haro`, INSTALLED);
	if (!hooked.ok) { return Result.err(hooked.error); }
	return Result.ok(hooked.value.hooks);
}

test "an onCommandDone that annotates reaches the pane with its anchor, text and colours" {
	const got = hooksOf("annotateConfig",
		`import { HaroConfig, annotate, unannotate } from "haro";\n\n` +
		`export const config: HaroConfig = {\n` +
		`\tonCommandDone: (e) => {\n` +
		`\t\tconst id = annotate({ at: e.end, text: e.command, foreground: "#00ff00" });\n` +
		`\t\tif (e.exitCode == 0) { unannotate(id); }\n` +
		`\t},\n};\n`);
	assert got.ok, got.ok ? "" : got.error;
	const hooks = got.ok ? got.value : null;
	assert hooks !== null;
	if (hooks === null) { return; }
	const heard: Heard = { said: [] };
	assert hooks.commandDone(paneHeard(heard), { ...ran(0, "make", null), end: 5 }).ok;
	assert heard.said.join("|") == "annotate 5 make 0,255,0 -|unannotate 41", heard.said.join("|");
	const refused = hooks.commandDone(paneHeard(heard), { ...ran(1, "a\tb", null), end: 6 });
	assert !refused.ok;
	if (!refused.ok) {
		const expected = `annotate's text "a\\tb" holds a control character`;
		assert refused.error == `onCommandDone in config.ms failed: ${expected}`, refused.error;
	}
}

test "markFailed from the haro package tints a failed block and notes its exit code and duration" {
	const got = hooksOf("markFailedConfig",
		`import { HaroConfig, markFailed } from "haro";\n\n` +
		`export const config: HaroConfig = { onCommandDone: (e) => { markFailed(e); } };\n`);
	assert got.ok, got.ok ? "" : got.error;
	const hooks = got.ok ? got.value : null;
	assert hooks !== null;
	if (hooks === null) { return; }
	const heard: Heard = { said: [] };
	const failed: CommandDone = { ...ran(2, "make", 1300), prompt: 3, output: 4, end: 5 };
	assert hooks.commandDone(paneHeard(heard), failed).ok;
	assert hooks.commandDone(paneHeard(heard), { ...failed, exitCode: 0 }).ok;
	assert hooks.commandDone(paneHeard(heard), { ...failed, durationMs: null, prompt: 7 }).ok;
	assert hooks.commandDone(paneHeard(heard), { ...failed, prompt: null }).ok;
	assert heard.said.join("|") ==
		"decorate 3..5 58,28,36 -|annotate 3 exit 2 · 1.3s - -|" +
		"decorate 7..5 58,28,36 -|annotate 7 exit 2 - -", heard.said.join("|");
}
