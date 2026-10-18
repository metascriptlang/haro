import { JSON, JsonKind, JsonValue } from "std/core/json";
import { Rgb, SCROLLBACK_LINES } from "../vt/vt";
import { Keybind, keybind } from "../input/bindings";

export interface Config {
	fontFamily: Vec<string>;
	fontSize: number;
	command: string;
	scrollback: int64;
	foreground: Rgb;
	background: Rgb;
	palette: Vec<Rgb>;
	keybinds: Vec<Keybind>;
}

const SCREEN_DPI: number = 96;
const POINTS_PER_INCH: number = 72;
const PALETTE_SIZE = 256;
const MAX_SCROLLBACK: int64 = 100000;

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
		command: DEFAULT_COMMAND,
		scrollback: SCROLLBACK_LINES,
		foreground: { r: 204, g: 204, b: 204 },
		background: { r: 12, g: 12, b: 12 },
		palette: [],
		keybinds: [],
	};
}

export function fontPx(this c: Config): number {
	return c.fontSize * SCREEN_DPI / POINTS_PER_INCH;
}

function hexDigit(c: string): int32 {
	const code = c.charCodeAt(0) as int32;
	if (code >= 48 && code <= 57) { return code - 48; }
	if (code >= 97 && code <= 102) { return code - 87; }
	if (code >= 65 && code <= 70) { return code - 55; }
	return -1;
}

export function colorOf(text: string): Result<Rgb, string> {
	if (text.length != 7 || text[0] != "#") { return Result.err(`"${text}" is not a #rrggbb colour`); }
	let parts: Vec<int32> = [];
	for (let i = 1; i < 7; i += 2) {
		const hi = hexDigit(text[i]);
		const lo = hexDigit(text[i + 1]);
		if (hi < 0 || lo < 0) { return Result.err(`"${text}" is not a #rrggbb colour`); }
		parts.push(hi * 16 + lo);
	}
	return Result.ok({ r: parts[0] as uint8, g: parts[1] as uint8, b: parts[2] as uint8 });
}

function text(v: JsonValue, key: string): Result<string, string> {
	if (v.kind != JsonKind.String) { return Result.err(`${key} must be a string`); }
	return Result.ok(v.strVal);
}

function color(v: JsonValue, key: string): Result<Rgb, string> {
	const s = try text(v, key);
	const c = colorOf(s);
	if (!c.ok) { return Result.err(`${key}: ${c.error}`); }
	return Result.ok(c.value);
}

function items(v: JsonValue, key: string): Result<Vec<JsonValue>, string> {
	if (v.kind != JsonKind.Array) { return Result.err(`${key} must be an array`); }
	let out: Vec<JsonValue> = [];
	for (const item of v.items) { out.push(item); }
	return Result.ok(out);
}

function families(v: JsonValue, key: string): Result<Vec<string>, string> {
	if (v.kind == JsonKind.String) { return Result.ok([v.strVal]); }
	if (v.kind != JsonKind.Array) { return Result.err(`${key} must be a family name or a list of them`); }
	let out: Vec<string> = [];
	for (let n = 0; n < v.items.length; n++) { out.push(try text(v.items[n], `${key}[${n}]`)); }
	return Result.ok(out);
}

function bindOf(v: JsonValue, key: string): Result<Keybind, string> {
	if (v.kind != JsonKind.Object) { return Result.err(`${key} must be { keys, text }`); }
	let keys: string | null = null;
	let sends: string | null = null;
	for (let i = 0; i < v.keys.length; i++) {
		const name = v.keys[i];
		match (name) {
			"keys" => { keys = try text(v.values[i], `${key}.keys`); },
			"text" => { sends = try text(v.values[i], `${key}.text`); },
			_ => { return Result.err(`${key}: unknown field "${name}", expected keys and text`); },
		}
	}
	if (keys === null || sends === null) { return Result.err(`${key} must give both keys and text`); }
	const b = keybind(keys, sends);
	if (!b.ok) { return Result.err(`${key}: ${b.error}`); }
	return Result.ok(b.value);
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
		match (key) {
			"fontFamily" => { c.fontFamily = try families(v, key); },
			"fontSize" => {
				if (v.kind != JsonKind.Number && v.kind != JsonKind.Int) { return Result.err("fontSize must be a number"); }
				c.fontSize = v.asNumber();
				if (c.fontSize <= 0) { return Result.err(`fontSize ${c.fontSize} must be above 0`); }
			},
			"command" => { c.command = try text(v, key); },
			"scrollback" => {
				if (v.kind != JsonKind.Int || v.intVal < 0 || v.intVal > MAX_SCROLLBACK) {
					return Result.err(`scrollback must be a whole number of lines from 0 to ${MAX_SCROLLBACK}`);
				}
				c.scrollback = v.intVal;
			},
			"foreground" => { c.foreground = try color(v, key); },
			"background" => { c.background = try color(v, key); },
			"palette" => {
				const list = try items(v, key);
				if (list.length > PALETTE_SIZE) { return Result.err(`palette has ${list.length} colours, at most ${PALETTE_SIZE}`); }
				for (let n = 0; n < list.length; n++) { c.palette.push(try color(list[n], `palette[${n}]`)); }
			},
			"keybinds" => {
				const list = try items(v, key);
				for (let n = 0; n < list.length; n++) { c.keybinds.push(try bindOf(list[n], `keybinds[${n}]`)); }
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
	assert c.value.command == DEFAULT_COMMAND;
	assert c.value.scrollback == SCROLLBACK_LINES;
	assert c.value.palette.length == 0;
	assert c.value.keybinds.length == 0;
}

test "the fields a config gives replace the defaults" {
	const c = parse(
		`{"fontFamily":"Operator Saigon","fontSize":10.8,"command":"cmd.exe","scrollback":50000,"background":"#1a1b26",` +
			`"foreground":"#A9B1D6","palette":["#32344a","#f7768e"],` +
			`"keybinds":[{"keys":"shift+enter","text":"\\u001b[13;2u"}]}`,
	);
	assert c.ok;
	assert c.value.fontFamily.length == 1;
	assert c.value.fontFamily[0] == "Operator Saigon";
	assert c.value.fontSize == 10.8;
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
	assert refusal(`{"fontSize":0}`) == "fontSize 0 must be above 0";
	assert refusal(`{"background":"#12345"}`) == `background: "#12345" is not a #rrggbb colour`;
	assert refusal(`{"palette":["#000000","red"]}`) == `palette[1]: "red" is not a #rrggbb colour`;
	assert refusal(`{"keybinds":[{"keys":"shift+entre","text":"x"}]}`) ==
		`keybinds[0]: "shift+entre": "entre" is not a key or modifier name`;
	assert refusal(`{"keybinds":[{"keys":"a","txt":"x"}]}`) ==
		`keybinds[0]: unknown field "txt", expected keys and text`;
	assert refusal(`{"keybinds":[{"keys":"a"}]}`) == "keybinds[0] must give both keys and text";
	assert refusal(`{"scrollback":100001}`) == "scrollback must be a whole number of lines from 0 to 100000";
	assert refusal(`{"scrollback":1.5}`) == "scrollback must be a whole number of lines from 0 to 100000";
	assert refusal("[]") == "config must be an object";
}
