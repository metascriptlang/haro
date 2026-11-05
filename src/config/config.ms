import { JSON, JsonKind, JsonValue } from "std/core/json";
import { isAbsolute } from "std/fs/path";
import { Rgb, SCROLLBACK_LINES } from "../vt/vt";
import { Action, Keybind, Screen, actionNames, actionNamed, keybind } from "../input/bindings";
import { PARTICLE_DENSITY } from "../term/trail";
import { KeyMod, OptionAsAlt, modSet } from "../keys/keys";
import { destinationOf } from "../client/destination";
import { Predicting } from "../controller/predict";

export enum StartKind {
	Inherit,
	Home,
	Path,
}

export struct StartDir = match (kind: StartKind) {
	StartKind.Inherit => {},
	StartKind.Home => {},
	StartKind.Path => { path: string },
};

export function `==`(this a: StartDir, b: StartDir): boolean {
	if (a.kind == StartKind.Path && b.kind == StartKind.Path) { return a.path == b.path; }
	return a.kind == b.kind;
}

export enum DividerStyle {
	Cell,
	Line,
}

export enum PaneTitle {
	Border,
	None,
}

export enum SidebarSide {
	Left,
	Right,
}

export enum PaneCwd {
	Focused,
	Start,
}

export struct RemoteHost {
	label: string;
	address: string;
}

export struct CursorEffects {
	glitch: boolean;
	trail: boolean;
	dust: float64;
}

export struct Config {
	fontFamily: Vec<string>;
	fontSize: float64;
	padding: float64;
	command: string;
	shellIntegration: boolean;
	copyOnSelect: boolean;
	cursor: CursorEffects;
	workingDirectory: StartDir | null;
	scrollback: int64;
	foreground: Rgb;
	background: Rgb;
	palette: Vec<Rgb>;
	keybinds: Vec<Keybind>;
	optionAsAlt: OptionAsAlt;
	dividerStyle: DividerStyle;
	dividerColor: Rgb | null;
	focusedDividerColor: Rgb | null;
	paneGap: float64;
	paneTitle: PaneTitle;
	paneResizeStep: int64;
	sidebarPosition: SidebarSide;
	sidebarVisible: boolean;
	sidebarWidth: int64;
	confirmClose: boolean;
	newPaneCwd: PaneCwd;
	serverTailnet: boolean;
	serverTailnetPort: int32;
	remoteHosts: Vec<RemoteHost>;
	remotePrediction: Predicting;
}

const POINTS_PER_INCH: float64 = 72;
const PALETTE_SIZE = 256;
const MAX_SCROLLBACK: int64 = 100000;
const MIN_FONT_SIZE: float64 = 1;
const MAX_FONT_SIZE: float64 = 255;
const MAX_PADDING: float64 = 512;
const MAX_CURSOR_DUST: float64 = 10;
const MAX_PANE_GAP: float64 = 64;
const PANE_RESIZE_STEP: int64 = 10;
const MAX_PANE_RESIZE_STEP: int64 = 1000;
const SIDEBAR_WIDTH: int64 = 24;
const MIN_SIDEBAR_WIDTH: int64 = 8;
const MAX_SIDEBAR_WIDTH: int64 = 200;
const SERVER_TAILNET_PORT: int32 = 7681;
const MAX_PORT: int64 = 65535;

when (windows) {
	import { defaultCommand } from "../pty/pty";

	function defaultShell(): string {
		return defaultCommand();
	}
} else when (macos) {
	function defaultShell(): string {
		return "${SHELL:-/bin/zsh} -l";
	}
} else {
	function defaultShell(): string {
		return "${SHELL:-/bin/sh}";
	}
}

when (macos) {
	const SCREEN_DPI: float64 = 72;
	const DEFAULT_FONT_SIZE: float64 = 14;
} else {
	const SCREEN_DPI: float64 = 96;
	const DEFAULT_FONT_SIZE: float64 = 10.5;
}

export function defaults(): Config {
	return {
		fontFamily: [],
		fontSize: DEFAULT_FONT_SIZE,
		padding: 0,
		command: defaultShell(),
		shellIntegration: true,
		copyOnSelect: false,
		cursor: { glitch: true, trail: true, dust: PARTICLE_DENSITY },
		workingDirectory: null,
		scrollback: SCROLLBACK_LINES,
		foreground: { r: 204, g: 204, b: 204 },
		background: { r: 12, g: 12, b: 12 },
		palette: [],
		keybinds: [],
		optionAsAlt: OptionAsAlt.Neither,
		dividerStyle: DividerStyle.Cell,
		dividerColor: null,
		focusedDividerColor: null,
		paneGap: 0,
		paneTitle: PaneTitle.Border,
		paneResizeStep: PANE_RESIZE_STEP,
		sidebarPosition: SidebarSide.Left,
		sidebarVisible: true,
		sidebarWidth: SIDEBAR_WIDTH,
		confirmClose: true,
		newPaneCwd: PaneCwd.Focused,
		serverTailnet: false,
		serverTailnetPort: SERVER_TAILNET_PORT,
		remoteHosts: [],
		remotePrediction: Predicting.Auto,
	};
}

export function startDirectory(this c: Config, probableCli: boolean, home: string): string | null {
	const dir = c.workingDirectory;
	if (dir === null) { return probableCli ? null : home; }
	return match (dir.kind) {
		StartKind.Inherit => null,
		StartKind.Home => home,
		StartKind.Path => dir.path.startsWith("~/") ? `${home}${dir.path.slice(1)}` : dir.path,
	};
}

export function dividerCellsOf(c: Config): int32 {
	return match (c.dividerStyle) {
		DividerStyle.Cell => 1,
		DividerStyle.Line => 0,
	};
}

export function pxOf(points: float64): float64 {
	return points * SCREEN_DPI / POINTS_PER_INCH;
}

export function fontPx(this c: Config): float64 {
	return pxOf(c.fontSize);
}

export function steppedFont(points: float64, by: float64): float64 {
	return Math.min(MAX_FONT_SIZE, Math.max(MIN_FONT_SIZE, points + by));
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
	return rgbOf(try readString(v, key), key);
}

export function rgbOf(text: string, key: string): Result<Rgb, string> {
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

function readBool(v: JsonValue, key: string): Result<boolean, string> {
	if (v.kind != JsonKind.Bool) { return Result.err(`${key} must be true or false`); }
	return Result.ok(v.boolVal);
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

function actionOf(name: string, key: string): Result<Action, string> {
	const action = actionNamed(name);
	if (action === null) {
		return Result.err(`${key}.action: "${name}" is not an action; ${actionNames()} are`);
	}
	return Result.ok(action);
}

function screenOf(name: string, key: string): Result<Screen, string> {
	return match (name) {
		"alt" => Result.ok(Screen.Alternate),
		"~alt" => Result.ok(Screen.Primary),
		_ => Result.err(`${key}.mode: "${name}" must be alt or ~alt`),
	};
}

function optionAsAltOf(name: string): Result<OptionAsAlt, string> {
	return match (name) {
		"neither" => Result.ok(OptionAsAlt.Neither),
		"left" => Result.ok(OptionAsAlt.Left),
		"right" => Result.ok(OptionAsAlt.Right),
		"both" => Result.ok(OptionAsAlt.Both),
		_ => Result.err(`optionAsAlt: "${name}" must be neither, left, right or both`),
	};
}

function dividerStyleOf(name: string): Result<DividerStyle, string> {
	return match (name) {
		"cell" => Result.ok(DividerStyle.Cell),
		"line" => Result.ok(DividerStyle.Line),
		_ => Result.err(`dividerStyle: "${name}" must be cell or line`),
	};
}

function paneTitleOf(name: string): Result<PaneTitle, string> {
	return match (name) {
		"border" => Result.ok(PaneTitle.Border),
		"none" => Result.ok(PaneTitle.None),
		_ => Result.err(`paneTitle: "${name}" must be border or none`),
	};
}

function sidebarSideOf(name: string): Result<SidebarSide, string> {
	return match (name) {
		"left" => Result.ok(SidebarSide.Left),
		"right" => Result.ok(SidebarSide.Right),
		_ => Result.err(`sidebarPosition: "${name}" must be left or right`),
	};
}

function predictingOf(name: string): Result<Predicting, string> {
	return match (name) {
		"auto" => Result.ok(Predicting.Auto),
		"on" => Result.ok(Predicting.On),
		"off" => Result.ok(Predicting.Off),
		_ => Result.err(`remotePrediction: "${name}" must be auto, on or off`),
	};
}

function paneCwdOf(name: string): Result<PaneCwd, string> {
	return match (name) {
		"focused" => Result.ok(PaneCwd.Focused),
		"start" => Result.ok(PaneCwd.Start),
		_ => Result.err(`newPaneCwd: "${name}" must be focused or start`),
	};
}

function readWhole(
	v: JsonValue,
	key: string,
	min: int64,
	max: int64,
	unit: string,
): Result<int64, string> {
	if (v.kind != JsonKind.Int || v.intVal < min || v.intVal > max) {
		return Result.err(`${key} must be a whole number of ${unit} from ${min} to ${max}`);
	}
	return Result.ok(v.intVal);
}

function readKeybind(v: JsonValue, key: string): Result<Keybind, string> {
	if (v.kind != JsonKind.Object) {
		return Result.err(`${key} must be { keys, text } or { keys, action }`);
	}
	let keys: string | null = null;
	let sends: string | null = null;
	let action: Action | null = null;
	let screen = Screen.Any;
	for (let i = 0; i < v.keys.length; i++) {
		const name = v.keys[i];
		const value = v.values[i];
		const given = value.kind != JsonKind.Null;
		match (name) {
			"keys" => { if (given) { keys = try readString(value, `${key}.keys`); } },
			"text" => { if (given) { sends = try readString(value, `${key}.text`); } },
			"action" => {
				if (given) { action = try actionOf(try readString(value, `${key}.action`), key); }
			},
			"mode" => {
				if (given) { screen = try screenOf(try readString(value, `${key}.mode`), key); }
			},
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
	const b = keybind(keys, sends ?? "", action ?? Action.SendText, screen);
	if (!b.ok) { return Result.err(`${key}: ${b.error}`); }
	return Result.ok(b.value);
}

function readCursor(v: JsonValue, key: string): Result<CursorEffects, string> {
	if (v.kind != JsonKind.Object) { return Result.err(`${key} must be { glitch, trail, dust }`); }
	let effects = defaults().cursor;
	for (let i = 0; i < v.keys.length; i++) {
		const name = v.keys[i];
		const value = v.values[i];
		if (value.kind == JsonKind.Null) { continue; }
		match (name) {
			"glitch" => { effects.glitch = try readBool(value, `${key}.glitch`); },
			"trail" => { effects.trail = try readBool(value, `${key}.trail`); },
			"dust" => {
				effects.dust = try readNumber(value, `${key}.dust`);
				if (effects.dust < 0 || effects.dust > MAX_CURSOR_DUST) {
					return Result.err(
						`${key}.dust ${effects.dust} must be from 0 to ${MAX_CURSOR_DUST} particles a line`,
					);
				}
			},
			_ => {
				return Result.err(`${key}: unknown field "${name}", expected glitch, trail and dust`);
			},
		}
	}
	return Result.ok(effects);
}

function readRemoteHost(v: JsonValue, key: string): Result<RemoteHost, string> {
	if (v.kind != JsonKind.Object) { return Result.err(`${key} must be { label, address }`); }
	let label: string | null = null;
	let address: string | null = null;
	for (let i = 0; i < v.keys.length; i++) {
		const name = v.keys[i];
		const value = v.values[i];
		if (value.kind == JsonKind.Null) { continue; }
		match (name) {
			"label" => { label = try readString(value, `${key}.label`); },
			"address" => {
				const parsed = destinationOf(try readString(value, `${key}.address`));
				if (!parsed.ok) { return Result.err(`${key}.address: ${parsed.error}`); }
				address = parsed.value;
			},
			_ => {
				return Result.err(`${key}: unknown field "${name}", expected label and address`);
			},
		}
	}
	if (label === null || label == "" || address === null) {
		return Result.err(`${key} must give a label and an address`);
	}
	return Result.ok({ label: label, address: address });
}

function readRemoteHosts(v: JsonValue, key: string): Result<Vec<RemoteHost>, string> {
	const hosts = try readEach(try readArray(v, key), key, readRemoteHost);
	for (let i = 0; i < hosts.length; i++) {
		for (let j = 0; j < i; j++) {
			if (hosts[i].label == hosts[j].label) {
				return Result.err(`${key}[${i}]: the label "${hosts[i].label}" is taken by ${key}[${j}]`);
			}
		}
	}
	return Result.ok(hosts);
}

function startDirOf(text: string): StartDir | null {
	if (text.startsWith("~/") || isAbsolute(text)) { return { kind: StartKind.Path, path: text }; }
	return match (text) {
		"inherit" => ({ kind: StartKind.Inherit }),
		"home" => ({ kind: StartKind.Home }),
		_ => null,
	};
}

export function parse(json: string): Result<Config, string> {
	const parsed = JSON.parseValue(json);
	if (!parsed.ok) { return Result.err(`the config is not JSON: ${parsed.error}`); }
	const root = parsed.value;
	if (root.kind != JsonKind.Object) { return Result.err("config must be an object"); }
	let c = defaults();
	for (let i = 0; i < root.keys.length; i++) {
		const key = root.keys[i];
		const v = root.values[i];
		const given = v.kind != JsonKind.Null;
		match (key) {
			"fontFamily" => { if (given) { c.fontFamily = try readFamilies(v, key); } },
			"fontSize" => {
				if (!given) { continue; }
				c.fontSize = try readNumber(v, key);
				if (c.fontSize < MIN_FONT_SIZE || c.fontSize > MAX_FONT_SIZE) {
					return Result.err(
						`fontSize ${c.fontSize} must be from ${MIN_FONT_SIZE} to ` +
							`${MAX_FONT_SIZE} points`,
					);
				}
			},
			"padding" => {
				if (!given) { continue; }
				c.padding = try readNumber(v, key);
				if (c.padding < 0 || c.padding > MAX_PADDING) {
					return Result.err(`padding ${c.padding} must be from 0 to ${MAX_PADDING}`);
				}
			},
			"command" => { if (given) { c.command = try readString(v, key); } },
			"shellIntegration" => { if (given) { c.shellIntegration = try readBool(v, key); } },
			"copyOnSelect" => { if (given) { c.copyOnSelect = try readBool(v, key); } },
			"cursor" => { if (given) { c.cursor = try readCursor(v, key); } },
			"workingDirectory" => {
				if (!given) { continue; }
				const text = try readString(v, key);
				const dir = startDirOf(text);
				if (dir === null) {
					return Result.err(
						`workingDirectory "${text}" must be home, inherit, an absolute path ` +
							"or a path under ~/",
					);
				}
				c.workingDirectory = dir;
			},
			"scrollback" => {
				if (!given) { continue; }
				if (v.kind != JsonKind.Int || v.intVal < 0 || v.intVal > MAX_SCROLLBACK) {
					return Result.err(
						`scrollback must be a whole number of lines from 0 to ${MAX_SCROLLBACK}`,
					);
				}
				c.scrollback = v.intVal;
			},
			"foreground" => { if (given) { c.foreground = try readColor(v, key); } },
			"background" => { if (given) { c.background = try readColor(v, key); } },
			"palette" => {
				if (!given) { continue; }
				const list = try readArray(v, key);
				if (list.length > PALETTE_SIZE) {
					return Result.err(
						`palette has ${list.length} colours, at most ${PALETTE_SIZE}`,
					);
				}
				c.palette = try readEach(list, key, readColor);
			},
			"keybinds" => {
				if (given) { c.keybinds = try readEach(try readArray(v, key), key, readKeybind); }
			},
			"optionAsAlt" => {
				if (given) { c.optionAsAlt = try optionAsAltOf(try readString(v, key)); }
			},
			"dividerStyle" => {
				if (given) { c.dividerStyle = try dividerStyleOf(try readString(v, key)); }
			},
			"dividerColor" => { if (given) { c.dividerColor = try readColor(v, key); } },
			"focusedDividerColor" => {
				if (given) { c.focusedDividerColor = try readColor(v, key); }
			},
			"paneGap" => {
				if (!given) { continue; }
				c.paneGap = try readNumber(v, key);
				if (c.paneGap < 0 || c.paneGap > MAX_PANE_GAP) {
					return Result.err(`paneGap ${c.paneGap} must be from 0 to ${MAX_PANE_GAP} pixels`);
				}
			},
			"paneTitle" => { if (given) { c.paneTitle = try paneTitleOf(try readString(v, key)); } },
			"paneResizeStep" => {
				if (given) { c.paneResizeStep = try readWhole(v, key, 1, MAX_PANE_RESIZE_STEP, "cells"); }
			},
			"sidebarPosition" => {
				if (given) { c.sidebarPosition = try sidebarSideOf(try readString(v, key)); }
			},
			"sidebarVisible" => { if (given) { c.sidebarVisible = try readBool(v, key); } },
			"sidebarWidth" => {
				if (given) {
					c.sidebarWidth = try readWhole(v, key, MIN_SIDEBAR_WIDTH, MAX_SIDEBAR_WIDTH, "cells");
				}
			},
			"confirmClose" => { if (given) { c.confirmClose = try readBool(v, key); } },
			"newPaneCwd" => { if (given) { c.newPaneCwd = try paneCwdOf(try readString(v, key)); } },
			"serverTailnet" => { if (given) { c.serverTailnet = try readBool(v, key); } },
			"serverTailnetPort" => {
				if (!given) { continue; }
				if (v.kind != JsonKind.Int || v.intVal < 1 || v.intVal > MAX_PORT) {
					return Result.err(`serverTailnetPort must be a port from 1 to ${MAX_PORT}`);
				}
				c.serverTailnetPort = v.intVal as int32;
			},
			"remoteHosts" => { if (given) { c.remoteHosts = try readRemoteHosts(v, key); } },
			"remotePrediction" => {
				if (given) { c.remotePrediction = try predictingOf(try readString(v, key)); }
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
	assert c.value.fontSize == DEFAULT_FONT_SIZE;
	assert c.value.fontPx() == 14;
	assert c.value.padding == 0;
	assert c.value.command == defaultShell();
	assert c.value.shellIntegration;
	assert !c.value.copyOnSelect;
	assert c.value.cursor.glitch && c.value.cursor.trail && c.value.cursor.dust == PARTICLE_DENSITY;
	assert c.value.scrollback == SCROLLBACK_LINES;
	assert c.value.palette.length == 0;
	assert c.value.keybinds.length == 0;
	assert c.value.optionAsAlt == OptionAsAlt.Neither;
	assert c.value.dividerStyle == DividerStyle.Cell;
	assert c.value.dividerColor === null && c.value.focusedDividerColor === null;
	assert c.value.paneGap == 0;
	assert c.value.paneTitle == PaneTitle.Border;
	assert c.value.paneResizeStep == 10;
	assert c.value.sidebarPosition == SidebarSide.Left;
	assert c.value.sidebarVisible;
	assert c.value.sidebarWidth == 24;
	assert c.value.confirmClose;
	assert c.value.newPaneCwd == PaneCwd.Focused;
}

test "the pane, sidebar and close fields a config gives replace the defaults" {
	const c = parse(
		`{"dividerStyle":"line","dividerColor":"#414868","focusedDividerColor":"#7aa2f7",` +
			`"paneGap":4,"paneTitle":"none","paneResizeStep":5,"sidebarPosition":"right",` +
			`"sidebarVisible":false,"sidebarWidth":30,"confirmClose":false,"newPaneCwd":"start"}`,
	);
	assert c.ok;
	const divider: Rgb = { r: 65, g: 72, b: 104 };
	const focused: Rgb = { r: 122, g: 162, b: 247 };
	assert c.value.dividerStyle == DividerStyle.Line;
	assert c.value.dividerColor == divider;
	assert c.value.focusedDividerColor == focused;
	assert c.value.paneGap == 4;
	assert c.value.paneTitle == PaneTitle.None;
	assert c.value.paneResizeStep == 5;
	assert c.value.sidebarPosition == SidebarSide.Right;
	assert !c.value.sidebarVisible;
	assert c.value.sidebarWidth == 30;
	assert !c.value.confirmClose;
	assert c.value.newPaneCwd == PaneCwd.Start;
}

test "remote prediction is auto unless the config turns it on or off" {
	const unset = parse("{}");
	assert unset.ok && unset.value.remotePrediction == Predicting.Auto;
	const on = parse(`{"remotePrediction":"on"}`);
	assert on.ok && on.value.remotePrediction == Predicting.On;
	const off = parse(`{"remotePrediction":"off"}`);
	assert off.ok && off.value.remotePrediction == Predicting.Off;
	assert refusal(`{"remotePrediction":"always"}`) == `remotePrediction: "always" must be auto, on or off`;
}

test "the server listens on the tailnet only when the config turns it on, at its port" {
	const off = parse("{}");
	assert off.ok && !off.value.serverTailnet && off.value.serverTailnetPort == SERVER_TAILNET_PORT;
	const on = parse(`{"serverTailnet":true,"serverTailnetPort":9001}`);
	assert on.ok && on.value.serverTailnet && on.value.serverTailnetPort == 9001;
	assert refusal(`{"serverTailnetPort":0}`) ==
		"serverTailnetPort must be a port from 1 to 65535";
	assert refusal(`{"serverTailnetPort":65536}`) ==
		"serverTailnetPort must be a port from 1 to 65535";
	assert refusal(`{"serverTailnet":"yes"}`) != "";
}

test "a remote host is a label and the ssh destination that reaches it" {
	const none = parse("{}");
	assert none.ok && none.value.remoteHosts.length == 0;
	const two = parse(
		`{"remoteHosts":[{"label":"build","address":"build.example.ts.net"},` +
			`{"label":"gpu","address":"me@gpu"}]}`,
	);
	assert two.ok;
	if (two.ok) {
		const hosts = two.value.remoteHosts;
		assert hosts.length == 2;
		assert hosts[0].label == "build" && hosts[0].address == "build.example.ts.net";
		assert hosts[1].label == "gpu" && hosts[1].address == "me@gpu";
	}
}

test "a remote host without a label or with a bad address or a taken label is refused by name" {
	assert refusal(`{"remoteHosts":{}}`) == "remoteHosts must be an array";
	assert refusal(`{"remoteHosts":["box"]}`) == "remoteHosts[0] must be { label, address }";
	assert refusal(`{"remoteHosts":[{"address":"box"}]}`) ==
		"remoteHosts[0] must give a label and an address";
	assert refusal(`{"remoteHosts":[{"label":"","address":"box"}]}`) ==
		"remoteHosts[0] must give a label and an address";
	assert refusal(`{"remoteHosts":[{"label":"b","address":"-x"}]}`) ==
		`remoteHosts[0].address: "-x" starts with -, which ssh reads as an option`;
	assert refusal(`{"remoteHosts":[{"label":"b","address":"box","port":1}]}`) ==
		`remoteHosts[0]: unknown field "port", expected label and address`;
	assert refusal(
		`{"remoteHosts":[{"label":"b","address":"x"},{"label":"b","address":"y"}]}`,
	) == `remoteHosts[1]: the label "b" is taken by remoteHosts[0]`;
}

test "a pane, sidebar or close field the config cannot use is refused by name" {
	assert refusal(`{"dividerStyle":"dashed"}`) == `dividerStyle: "dashed" must be cell or line`;
	assert refusal(`{"dividerColor":"blue"}`) == `dividerColor: "blue" is not a #rrggbb colour`;
	assert refusal(`{"focusedDividerColor":1}`) == "focusedDividerColor must be a string";
	assert refusal(`{"paneGap":-1}`) == "paneGap -1 must be from 0 to 64 pixels";
	assert refusal(`{"paneGap":65}`) == "paneGap 65 must be from 0 to 64 pixels";
	assert refusal(`{"paneGap":64}`) == "";
	assert refusal(`{"paneTitle":"top"}`) == `paneTitle: "top" must be border or none`;
	assert refusal(`{"paneResizeStep":0}`) ==
		"paneResizeStep must be a whole number of cells from 1 to 1000";
	assert refusal(`{"paneResizeStep":2.5}`) ==
		"paneResizeStep must be a whole number of cells from 1 to 1000";
	assert refusal(`{"sidebarPosition":"top"}`) == `sidebarPosition: "top" must be left or right`;
	assert refusal(`{"sidebarVisible":"yes"}`) == "sidebarVisible must be true or false";
	assert refusal(`{"sidebarWidth":7}`) ==
		"sidebarWidth must be a whole number of cells from 8 to 200";
	assert refusal(`{"sidebarWidth":201}`) ==
		"sidebarWidth must be a whole number of cells from 8 to 200";
	assert refusal(`{"confirmClose":0}`) == "confirmClose must be true or false";
	assert refusal(`{"newPaneCwd":"home"}`) == `newPaneCwd: "home" must be focused or start`;
}

test "the fields a config gives replace the defaults" {
	const c = parse(
		`{"fontFamily":"Operator Saigon","fontSize":10.8,"padding":6,"command":"cmd.exe",` +
			`"shellIntegration":false,"copyOnSelect":true,` +
			`"cursor":{"glitch":false,"trail":false,"dust":0},` +
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
	assert !c.value.shellIntegration;
	assert c.value.copyOnSelect;
	assert !c.value.cursor.glitch && !c.value.cursor.trail && c.value.cursor.dust == 0;
	assert c.value.scrollback == 50000;
	const background: Rgb = { r: 26, g: 27, b: 38 };
	const foreground: Rgb = { r: 169, g: 177, b: 214 };
	const red: Rgb = { r: 247, g: 118, b: 142 };
	assert c.value.background == background;
	assert c.value.foreground == foreground;
	assert c.value.palette.length == 2;
	assert c.value.palette[1] == red;
	assert c.value.keybinds[0].code == "Enter";
	assert c.value.keybinds[0].mods == modSet(KeyMod.Shift);
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
	assert c.value.keybinds[0].action == Action.SendText;
	assert c.value.keybinds[0].text == "\x1b[119;9u";
	assert c.value.keybinds[0].screen == Screen.Alternate;
	assert c.value.keybinds[1].action == Action.CloseWindow;
	assert c.value.keybinds[1].screen == Screen.Primary;
}

test "a keybind can name every built-in action by its snake_case name" {
	const names = ["copy", "paste", "scroll_line_up", "scroll_line_down", "scroll_page_up",
		"scroll_page_down", "scroll_to_top", "scroll_to_bottom", "prompt_up", "prompt_down",
		"close_window", "split_right", "close_pane", "goto_tab_3", "toggle_sidebar"];
	for (const name of names) {
		assert refusal(`{"keybinds":[{"keys":"super+j","action":"${name}"}]}`) == "";
	}
	const c = parse(`{"keybinds":[{"keys":"super+j","action":"scroll_to_top","mode":"~alt"}]}`);
	assert c.ok;
	assert c.value.keybinds[0].action == Action.Top;
	assert c.value.keybinds[0].screen == Screen.Primary;
}

test "a font size steps by the given points and stays within the sizes a config may name" {
	assert steppedFont(14, 1) == 15;
	assert steppedFont(10.5, -1) == 9.5;
	assert steppedFont(MIN_FONT_SIZE, -1) == MIN_FONT_SIZE;
	assert steppedFont(MAX_FONT_SIZE, 1) == MAX_FONT_SIZE;
	const c = parse("{}");
	assert c.ok;
	assert pxOf(DEFAULT_FONT_SIZE) == c.value.fontPx();
}

test "a field msc prints as null is a field the config left out" {
	const c = parse(
		`{"fontSize":null,"keybinds":[` +
			`{"keys":"super+w","text":"x","action":null,"mode":null}]}`,
	);
	assert c.ok;
	assert c.value.fontSize == DEFAULT_FONT_SIZE;
	assert c.value.keybinds[0].action == Action.SendText;
	assert c.value.keybinds[0].screen == Screen.Any;
}

test "Option acts as Alt on the sides the config names" {
	const sides = (name: string): OptionAsAlt | null => {
		const c = parse(`{"optionAsAlt":"${name}"}`);
		return c.ok ? c.value.optionAsAlt : null;
	};
	assert sides("neither") == OptionAsAlt.Neither;
	assert sides("left") == OptionAsAlt.Left;
	assert sides("right") == OptionAsAlt.Right;
	assert sides("both") == OptionAsAlt.Both;
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
	assert refusal(`{"fontsize":null}`) == `unknown config field "fontsize"`;
	assert refusal(`{"keybinds":[{"keys":"a","text":"x","txt":null}]}`) ==
		`keybinds[0]: unknown field "txt", expected keys, text, action and mode`;
	assert refusal(`{"fontSize":"10"}`) == "fontSize must be a number";
	assert refusal(`{"shellIntegration":"no"}`) == "shellIntegration must be true or false";
	assert refusal(`{"copyOnSelect":1}`) == "copyOnSelect must be true or false";
	assert refusal(`{"cursor":{"glitch":"on"}}`) == "cursor.glitch must be true or false";
	assert refusal(`{"cursor":{"dust":-1}}`) == "cursor.dust -1 must be from 0 to 10 particles a line";
	assert refusal(`{"cursor":{"dust":11}}`) == "cursor.dust 11 must be from 0 to 10 particles a line";
	assert refusal(`{"cursor":{"blink":true}}`) ==
		`cursor: unknown field "blink", expected glitch, trail and dust`;
	assert refusal(`{"cursor":true}`) == "cursor must be { glitch, trail, dust }";
	assert refusal(`{"fontSize":0}`) == "fontSize 0 must be from 1 to 255 points";
	assert refusal(`{"fontSize":0.5}`) == "fontSize 0.5 must be from 1 to 255 points";
	assert refusal(`{"fontSize":256}`) == "fontSize 256 must be from 1 to 255 points";
	assert refusal(`{"padding":"6"}`) == "padding must be a number";
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
		`keybinds[0].action: "quit" is not an action; ${actionNames()} are`;
	assert refusal(`{"keybinds":[{"keys":"a","text":"x","mode":"Alt"}]}`) ==
		`keybinds[0].mode: "Alt" must be alt or ~alt`;
	assert refusal(`{"scrollback":100001}`) ==
		"scrollback must be a whole number of lines from 0 to 100000";
	assert refusal(`{"scrollback":1.5}`) ==
		"scrollback must be a whole number of lines from 0 to 100000";
	assert refusal(`{"optionAsAlt":"true"}`) ==
		`optionAsAlt: "true" must be neither, left, right or both`;
	assert refusal(`{"optionAsAlt":true}`) == "optionAsAlt must be a string";
	assert refusal("[]") == "config must be an object";
}

test "a padding beyond the cap is refused by name" {
	assert refusal(`{"padding":-1}`) == "padding -1 must be from 0 to 512";
	assert refusal(`{"padding":513}`) == "padding 513 must be from 0 to 512";
	assert refusal(`{"padding":512}`) == "";
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

test "start directories are equal by kind and, for a path, by path" {
	const home: StartDir = { kind: StartKind.Home };
	const inherit: StartDir = { kind: StartKind.Inherit };
	const here: StartDir = { kind: StartKind.Path, path: "/a" };
	const same: StartDir = { kind: StartKind.Path, path: "/a" };
	const other: StartDir = { kind: StartKind.Path, path: "/b" };
	assert here == same;
	assert here != other;
	assert home != here;
	assert home != inherit;
	assert home == home;
}
