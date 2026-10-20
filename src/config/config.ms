import { JSON, JsonKind, JsonValue } from "std/core/json";
import { isAbsolute } from "std/fs/path";
import { Rgb, SCROLLBACK_LINES } from "../vt/vt";
import { BindAction, Keybind, Screen, keybind } from "../input/bindings";

export interface Config {
	fontFamily: Vec<string>;
	fontSize: float64;
	padding: float64;
	command: string;
	workingDirectory: string | null;
	scrollback: int64;
	foreground: Rgb;
	background: Rgb;
	palette: Vec<Rgb>;
	keybinds: Vec<Keybind>;
}

const SCREEN_DPI: float64 = 96;
const POINTS_PER_INCH: float64 = 72;
const PALETTE_SIZE = 256;
const MAX_SCROLLBACK: int64 = 100000;
const MIN_FONT_SIZE: float64 = 1;
const MAX_FONT_SIZE: float64 = 255;

when (windows) {
	const DEFAULT_COMMAND = "pwsh.exe -NoLogo";
} else when (macos) {
	const DEFAULT_COMMAND = "${SHELL:-/bin/zsh} -l";
} else {
	const DEFAULT_COMMAND = "${SHELL:-/bin/sh}";
}

export function defaults(): Config {
	return {
		fontFamily: [],
		fontSize: 10.5,
		padding: 0,
		command: DEFAULT_COMMAND,
		workingDirectory: null,
		scrollback: SCROLLBACK_LINES,
		foreground: { r: 204, g: 204, b: 204 },
		background: { r: 12, g: 12, b: 12 },
		palette: [],
		keybinds: [],
	};
}

export function startDirectory(this c: Config, probableCli: boolean, home: string): string | null {
	const dir = c.workingDirectory ?? (probableCli ? "inherit" : "home");
	return match (dir) {
		"inherit" => null,
		"home" => home,
		_ => dir.startsWith("~/") ? `${home}${dir.slice(1)}` : dir,
	};
}

export function fontPx(this c: Config): float64 {
	return c.fontSize * SCREEN_DPI / POINTS_PER_INCH;
}

function hexDigit(code: int32): int32 | null {
	if (code >= "0".code && code <= "9".code) { return code - "0".code; }
	if (code >= "a".code && code <= "f".code) { return code - "a".code + 10; }
	if (code >= "A".code && code <= "F".code) { return code - "A".code + 10; }
	return null;
}

function channelAt(text: string, at: int32): uint8 | null {
	const high = hexDigit(text.charCodeAt(at));
	const low = hexDigit(text.charCodeAt(at + 1));
	return high === null || low === null ? null : (high * 16 + low) as uint8;
}

function readString(v: JsonValue, key: string): Result<string, string> {
	if (v.kind != JsonKind.String) { return Result.err(`${key} must be a string`); }
	return Result.ok(v.strVal);
}

function readColor(v: JsonValue, key: string): Result<Rgb, string> {
	const text = try readString(v, key);
	const notColour = `${key}: "${text}" is not a #rrggbb colour`;
	if (text.length != 7 || text[0] != "#") { return Result.err(notColour); }
	const r = channelAt(text, 1);
	const g = channelAt(text, 3);
	const b = channelAt(text, 5);
	if (r === null || g === null || b === null) { return Result.err(notColour); }
	return Result.ok({ r: r, g: g, b: b });
}

function readNumber(v: JsonValue, key: string): Result<float64, string> {
	return match (v.kind) {
		JsonKind.Number | JsonKind.Int => Result.ok(v.asNumber()),
		_ => Result.err(`${key} must be a number`),
	};
}

function readArray(v: JsonValue, key: string): Result<JsonValue[], string> {
	if (v.kind != JsonKind.Array) { return Result.err(`${key} must be an array`); }
	return Result.ok(v.items);
}

function readEach<T>(
	items: JsonValue[],
	key: string,
	read: (v: JsonValue, key: string) => Result<T, string>,
): Result<Vec<T>, string> {
	let out: Vec<T> = [];
	for (let n = 0; n < items.length; n++) { out.push(try read(items[n], `${key}[${n}]`)); }
	return Result.ok(out);
}

function readFamilies(v: JsonValue, key: string): Result<Vec<string>, string> {
	if (v.kind == JsonKind.String) { return Result.ok([v.strVal]); }
	if (v.kind != JsonKind.Array) {
		return Result.err(`${key} must be a family name or a list of them`);
	}
	return readEach(v.items, key, readString);
}

function actionOf(name: string, key: string): Result<BindAction, string> {
	return match (name) {
		"close_window" => Result.ok(BindAction.CloseWindow),
		_ => Result.err(`${key}.action: "${name}" is not an action; close_window is`),
	};
}

function screenOf(name: string, key: string): Result<Screen, string> {
	return match (name) {
		"alt" => Result.ok(Screen.Alternate),
		"~alt" => Result.ok(Screen.Primary),
		_ => Result.err(`${key}.mode: "${name}" must be alt or ~alt`),
	};
}

function readKeybind(v: JsonValue, key: string): Result<Keybind, string> {
	if (v.kind != JsonKind.Object) {
		return Result.err(`${key} must be { keys, text } or { keys, action }`);
	}
	let keys: string | null = null;
	let sends: string | null = null;
	let action: BindAction | null = null;
	let screen = Screen.Any;
	for (let i = 0; i < v.keys.length; i++) {
		const name = v.keys[i];
		const value = v.values[i];
		if (value.kind == JsonKind.Null) { continue; }
		match (name) {
			"keys" => { keys = try readString(value, `${key}.keys`); },
			"text" => { sends = try readString(value, `${key}.text`); },
			"action" => { action = try actionOf(try readString(value, `${key}.action`), key); },
			"mode" => { screen = try screenOf(try readString(value, `${key}.mode`), key); },
			_ => {
				return Result.err(
					`${key}: unknown field "${name}", expected keys, text, action and mode`,
				);
			},
		}
	}
	if (sends !== null && action !== null) {
		return Result.err(`${key} gives both text and action; a keybind does one`);
	}
	if (keys === null || (sends === null && action === null)) {
		return Result.err(`${key} must give keys and either text or action`);
	}
	const b = keybind(keys, sends ?? "", action ?? BindAction.SendText, screen);
	if (!b.ok) { return Result.err(`${key}: ${b.error}`); }
	return Result.ok(b.value);
}

function isWorkingDirectory(dir: string): boolean {
	return match (dir) {
		"home" | "inherit" => true,
		_ => dir.startsWith("~/") || isAbsolute(dir),
	};
}

export function parse(json: string): Result<Config, string> {
	const parsed = JSON.parseValue(json);
	if (!parsed.ok) { return Result.err(`the config is not JSON: ${parsed.error}`); }
	const root = parsed.value;
	if (root.kind != JsonKind.Object) { return Result.err("config must be an object"); }
	const c = defaults();
	for (let i = 0; i < root.keys.length; i++) {
		const key = root.keys[i];
		const v = root.values[i];
		if (v.kind == JsonKind.Null) { continue; }
		match (key) {
			"fontFamily" => { c.fontFamily = try readFamilies(v, key); },
			"fontSize" => {
				c.fontSize = try readNumber(v, key);
				if (c.fontSize < MIN_FONT_SIZE || c.fontSize > MAX_FONT_SIZE) {
					return Result.err(
						`fontSize ${c.fontSize} must be from ${MIN_FONT_SIZE} to ${MAX_FONT_SIZE} points`,
					);
				}
			},
			"padding" => {
				c.padding = try readNumber(v, key);
				if (c.padding < 0) {
					return Result.err(`padding ${c.padding} must be 0 or more`);
				}
			},
			"command" => { c.command = try readString(v, key); },
			"workingDirectory" => {
				const dir = try readString(v, key);
				if (!isWorkingDirectory(dir)) {
					return Result.err(
						`workingDirectory "${dir}" must be home, inherit, an absolute path ` +
							"or a path under ~/",
					);
				}
				c.workingDirectory = dir;
			},
			"scrollback" => {
				if (v.kind != JsonKind.Int || v.intVal < 0 || v.intVal > MAX_SCROLLBACK) {
					return Result.err(
						`scrollback must be a whole number of lines from 0 to ${MAX_SCROLLBACK}`,
					);
				}
				c.scrollback = v.intVal;
			},
			"foreground" => { c.foreground = try readColor(v, key); },
			"background" => { c.background = try readColor(v, key); },
			"palette" => {
				const list = try readArray(v, key);
				if (list.length > PALETTE_SIZE) {
					return Result.err(
						`palette has ${list.length} colours, at most ${PALETTE_SIZE}`,
					);
				}
				c.palette = try readEach(list, key, readColor);
			},
			"keybinds" => {
				c.keybinds = try readEach(try readArray(v, key), key, readKeybind);
			},
			_ => { return Result.err(`unknown config field "${key}"`); },
		}
	}
	return Result.ok(c);
}

function refusal(json: string): string {
	const c = parse(json);
	if (c.ok) { return ""; }
	return c.error;
}

test "an empty config keeps every default" {
	const c = parse("{}");
	assert c.ok;
	assert c.value.fontFamily.length == 0;
	assert c.value.fontSize == 10.5;
	assert c.value.fontPx() == 14;
	assert c.value.padding == 0;
	assert c.value.command == DEFAULT_COMMAND;
	assert c.value.scrollback == SCROLLBACK_LINES;
	assert c.value.palette.length == 0;
	assert c.value.keybinds.length == 0;
}

test "the fields a config gives replace the defaults" {
	const c = parse(
		`{"fontFamily":"Operator Saigon","fontSize":10.8,"padding":6,"command":"cmd.exe",` +
			`"scrollback":50000,"background":"#1a1b26","foreground":"#A9B1D6",` +
			`"palette":["#32344a","#f7768e"],` +
			`"keybinds":[{"keys":"shift+enter","text":"\\u001b[13;2u"}]}`,
	);
	assert c.ok;
	assert c.value.fontFamily.length == 1;
	assert c.value.fontFamily[0] == "Operator Saigon";
	assert c.value.fontSize == 10.8;
	assert c.value.padding == 6;
	assert c.value.command == "cmd.exe";
	assert c.value.scrollback == 50000;
	const background: Rgb = { r: 26, g: 27, b: 38 };
	const foreground: Rgb = { r: 169, g: 177, b: 214 };
	const red: Rgb = { r: 247, g: 118, b: 142 };
	assert c.value.background == background;
	assert c.value.foreground == foreground;
	assert c.value.palette.length == 2;
	assert c.value.palette[1] == red;
	assert c.value.keybinds[0].code == "Enter";
	assert c.value.keybinds[0].mods == 1;
	assert c.value.keybinds[0].text == "\x1b[13;2u";
	assert c.value.keybinds[0].screen == Screen.Any;
}

test "a keybind runs an action or keeps to one screen when its config says so" {
	const c = parse(
		`{"keybinds":[{"keys":"super+w","text":"\\u001b[119;9u","mode":"alt"},` +
			`{"keys":"super+w","action":"close_window","mode":"~alt"}]}`,
	);
	assert c.ok;
	assert c.value.keybinds.length == 2;
	assert c.value.keybinds[0].action == BindAction.SendText;
	assert c.value.keybinds[0].text == "\x1b[119;9u";
	assert c.value.keybinds[0].screen == Screen.Alternate;
	assert c.value.keybinds[1].action == BindAction.CloseWindow;
	assert c.value.keybinds[1].screen == Screen.Primary;
}

test "a field msc prints as null is a field the config left out" {
	const c = parse(`{"fontSize":null,"keybinds":[{"keys":"super+w","text":"x","action":null,"mode":null}]}`);
	assert c.ok;
	assert c.value.fontSize == 10.5;
	assert c.value.keybinds[0].action == BindAction.SendText;
	assert c.value.keybinds[0].screen == Screen.Any;
}

test "a list of font families keeps its order, the first one primary and the rest its fallbacks" {
	const c = parse(`{"fontFamily":["Operator Saigon","OperatorMono Nerd Font Mono"]}`);
	assert c.ok;
	assert c.value.fontFamily.length == 2;
	assert c.value.fontFamily[0] == "Operator Saigon";
	assert c.value.fontFamily[1] == "OperatorMono Nerd Font Mono";
}

test "a field the config cannot use is refused by name" {
	assert refusal(`{"fontFamily":12}`) == "fontFamily must be a family name or a list of them";
	assert refusal(`{"fontFamily":["Operator Saigon",12]}`) == "fontFamily[1] must be a string";
	assert refusal(`{"fontsize":10}`) == `unknown config field "fontsize"`;
	assert refusal(`{"fontSize":"10"}`) == "fontSize must be a number";
	assert refusal(`{"fontSize":0}`) == "fontSize 0 must be from 1 to 255 points";
	assert refusal(`{"fontSize":0.5}`) == "fontSize 0.5 must be from 1 to 255 points";
	assert refusal(`{"fontSize":256}`) == "fontSize 256 must be from 1 to 255 points";
	assert refusal(`{"padding":"6"}`) == "padding must be a number";
	assert refusal(`{"padding":-1}`) == "padding -1 must be 0 or more";
	assert refusal(`{"workingDirectory":"projects"}`) ==
		`workingDirectory "projects" must be home, inherit, an absolute path or a path under ~/`;
	assert refusal(`{"background":"#12345"}`) == `background: "#12345" is not a #rrggbb colour`;
	assert refusal(`{"background":"#0aFg10"}`) == `background: "#0aFg10" is not a #rrggbb colour`;
	assert refusal(`{"palette":["#000000","red"]}`) == `palette[1]: "red" is not a #rrggbb colour`;
	assert refusal(`{"keybinds":[{"keys":"shift+entre","text":"x"}]}`) ==
		`keybinds[0]: "shift+entre": "entre" is not a key or modifier name`;
	assert refusal(`{"keybinds":[{"keys":"a","txt":"x"}]}`) ==
		`keybinds[0]: unknown field "txt", expected keys, text, action and mode`;
	assert refusal(`{"keybinds":[{"keys":"a"}]}`) ==
		"keybinds[0] must give keys and either text or action";
	assert refusal(`{"keybinds":[{"keys":"a","text":"x","action":"close_window"}]}`) ==
		"keybinds[0] gives both text and action; a keybind does one";
	assert refusal(`{"keybinds":[{"keys":"a","action":"quit"}]}`) ==
		`keybinds[0].action: "quit" is not an action; close_window is`;
	assert refusal(`{"keybinds":[{"keys":"a","text":"x","mode":"Alt"}]}`) ==
		`keybinds[0].mode: "Alt" must be alt or ~alt`;
	assert refusal(`{"scrollback":100001}`) ==
		"scrollback must be a whole number of lines from 0 to 100000";
	assert refusal(`{"scrollback":1.5}`) ==
		"scrollback must be a whole number of lines from 0 to 100000";
	assert refusal("[]") == "config must be an object";
}

test "the shell starts at home unless Haro was probably started from a command line" {
	const c = defaults();
	assert c.startDirectory(false, "/Users/me") == "/Users/me";
	assert c.startDirectory(true, "/Users/me") === null;
}

test "a configured working directory wins, with ~/ under home" {
	const at = (dir: string): string | null => {
		const c = parse(`{"workingDirectory":${JSON.stringify(dir)}}`);
		return c.ok ? c.value.startDirectory(true, "/Users/me") : "refused";
	};
	assert at("home") == "/Users/me";
	assert at("inherit") === null;
	assert at("~/code") == "/Users/me/code";
	assert at("/srv/www") == "/srv/www";
}
