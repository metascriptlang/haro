import { KeyMod, NO_MODS, modSet, modsMask } from "../keys/keys";

export enum Action {
	SendText,
	CloseWindow,
	Copy,
	Paste,
	SelectAll,
	ClearScrollback,
	LineUp,
	LineDown,
	PageUp,
	PageDown,
	Top,
	Bottom,
	PromptUp,
	PromptDown,
	IncreaseFontSize,
	DecreaseFontSize,
	ResetFontSize,
	OpenConfig,
	ReloadConfig,
}

const SHIFT = modSet(KeyMod.Shift);
const CTRL = modSet(KeyMod.Ctrl);
const ALT = modSet(KeyMod.Alt);
const SUPER = modSet(KeyMod.Super);
const CHORD = SHIFT | CTRL | ALT | SUPER;

export function chordOf(mods: BitSet<KeyMod>): BitSet<KeyMod> {
	return mods.intersection(CHORD);
}

export enum Screen {
	Any,
	Alternate,
	Primary,
}

struct Binding {
	code: string;
	mods: BitSet<KeyMod>;
	action: Action;
	screen: Screen;
}

when (macos) {
	export const CLIPBOARD_MODS: BitSet<KeyMod> = SUPER;
	export const APP_MODS: BitSet<KeyMod> = SUPER;
	const OS_CHORDS: Vec<Binding> = [];
} else when (windows) {
	export const CLIPBOARD_MODS: BitSet<KeyMod> = CTRL | SHIFT;
	export const APP_MODS: BitSet<KeyMod> = CTRL;
	const OS_CHORDS: Vec<Binding> = [
		{ code: "Insert", mods: CTRL, action: Action.Copy, screen: Screen.Any },
		{ code: "Insert", mods: SHIFT, action: Action.Paste, screen: Screen.Any },
		{ code: "Enter", mods: NO_MODS, action: Action.Copy, screen: Screen.Any },
	];
} else {
	export const CLIPBOARD_MODS: BitSet<KeyMod> = CTRL | SHIFT;
	export const APP_MODS: BitSet<KeyMod> = CTRL;
	const OS_CHORDS: Vec<Binding> = [
		{ code: "Insert", mods: CTRL, action: Action.Copy, screen: Screen.Any },
		{ code: "Insert", mods: SHIFT, action: Action.Paste, screen: Screen.Any },
	];
}

const BINDINGS: Vec<Binding> = [
	{ code: "KeyC", mods: CLIPBOARD_MODS, action: Action.Copy, screen: Screen.Any },
	{ code: "KeyV", mods: CLIPBOARD_MODS, action: Action.Paste, screen: Screen.Any },
	{ code: "KeyA", mods: CLIPBOARD_MODS, action: Action.SelectAll, screen: Screen.Any },
	{ code: "KeyK", mods: CLIPBOARD_MODS, action: Action.ClearScrollback, screen: Screen.Any },
	{ code: "Equal", mods: APP_MODS, action: Action.IncreaseFontSize, screen: Screen.Any },
	{ code: "Equal", mods: APP_MODS | SHIFT, action: Action.IncreaseFontSize, screen: Screen.Any },
	{ code: "Minus", mods: APP_MODS, action: Action.DecreaseFontSize, screen: Screen.Any },
	{ code: "Digit0", mods: APP_MODS, action: Action.ResetFontSize, screen: Screen.Any },
	{ code: "Comma", mods: APP_MODS, action: Action.OpenConfig, screen: Screen.Any },
	{ code: "Comma", mods: APP_MODS | SHIFT, action: Action.ReloadConfig, screen: Screen.Any },
	{ code: "ArrowUp", mods: CTRL | SHIFT, action: Action.LineUp, screen: Screen.Any },
	{ code: "ArrowDown", mods: CTRL | SHIFT, action: Action.LineDown, screen: Screen.Any },
	{ code: "PageUp", mods: CTRL | SHIFT, action: Action.PageUp, screen: Screen.Any },
	{ code: "PageDown", mods: CTRL | SHIFT, action: Action.PageDown, screen: Screen.Any },
	{ code: "Home", mods: CTRL | SHIFT, action: Action.Top, screen: Screen.Any },
	{ code: "End", mods: CTRL | SHIFT, action: Action.Bottom, screen: Screen.Any },
	{ code: "ArrowUp", mods: CTRL | ALT, action: Action.PromptUp, screen: Screen.Any },
	{ code: "ArrowDown", mods: CTRL | ALT, action: Action.PromptDown, screen: Screen.Any },
	{ code: "PageUp", mods: SHIFT, action: Action.PageUp, screen: Screen.Primary },
	{ code: "PageDown", mods: SHIFT, action: Action.PageDown, screen: Screen.Primary },
];

export struct Keybind {
	code: string;
	mods: BitSet<KeyMod>;
	text: string;
	action: Action;
	screen: Screen;
}

struct Named {
	name: string;
	action: Action;
}

const NAMED: Vec<Named> = [
	{ name: "close_window", action: Action.CloseWindow },
	{ name: "copy", action: Action.Copy },
	{ name: "paste", action: Action.Paste },
	{ name: "select_all", action: Action.SelectAll },
	{ name: "clear_scrollback", action: Action.ClearScrollback },
	{ name: "scroll_line_up", action: Action.LineUp },
	{ name: "scroll_line_down", action: Action.LineDown },
	{ name: "scroll_page_up", action: Action.PageUp },
	{ name: "scroll_page_down", action: Action.PageDown },
	{ name: "scroll_to_top", action: Action.Top },
	{ name: "scroll_to_bottom", action: Action.Bottom },
	{ name: "prompt_up", action: Action.PromptUp },
	{ name: "prompt_down", action: Action.PromptDown },
	{ name: "increase_font_size", action: Action.IncreaseFontSize },
	{ name: "decrease_font_size", action: Action.DecreaseFontSize },
	{ name: "reset_font_size", action: Action.ResetFontSize },
	{ name: "open_config", action: Action.OpenConfig },
	{ name: "reload_config", action: Action.ReloadConfig },
];

export function actionNamed(name: string): Action | null {
	for (const n of NAMED) {
		if (n.name == name) { return n.action; }
	}
	return null;
}

export function actionNames(): string {
	return NAMED.map((n: Named): string => n.name).join(", ");
}

function modOf(name: string): KeyMod | null {
	return match (name) {
		"shift" => KeyMod.Shift,
		"ctrl" | "control" => KeyMod.Ctrl,
		"alt" | "opt" | "option" => KeyMod.Alt,
		"super" | "cmd" | "command" => KeyMod.Super,
		_ => null,
	};
}

const KEY_NAMES: Vec<string> = [
	"backquote", "backslash", "bracket_left", "bracket_right", "comma", "equal", "minus",
	"period", "quote", "semicolon", "slash", "backspace", "enter", "space", "tab", "escape",
	"delete", "end", "home", "insert", "page_down", "page_up", "arrow_down", "arrow_left",
	"arrow_right", "arrow_up", "numpad_add", "numpad_decimal", "numpad_divide", "numpad_enter",
	"numpad_multiply", "numpad_subtract",
];

function pascalCase(snake: string): string {
	let out = "";
	for (const part of snake.split("_")) {
		if (part.length > 0) { out += part[0].toUpperCase() + part.slice(1); }
	}
	return out;
}

function codeOf(name: string): string | null {
	if (name.length == 1 && name >= "a" && name <= "z") { return `Key${name.toUpperCase()}`; }
	if (name.length == 1 && name >= "0" && name <= "9") { return `Digit${name}`; }
	if (name.startsWith("key_") && name.length == 5 && name[4] >= "a" && name[4] <= "z") {
		return codeOf(name.slice(4));
	}
	if (name.startsWith("digit_") && name.length == 7 && name[6] >= "0" && name[6] <= "9") {
		return codeOf(name.slice(6));
	}
	if (name.startsWith("numpad_") && name.length == 8 && name[7] >= "0" && name[7] <= "9") {
		return pascalCase(name);
	}
	if (name.length >= 2 && name.length <= 3 && name[0] == "f") {
		const n = name.slice(1).parseInt();
		if (n >= 1 && n <= 24 && `f${n}` == name) { return `F${n}`; }
	}
	return KEY_NAMES.includes(name) ? pascalCase(name) : null;
}

export function keybind(
	keys: string,
	text: string,
	action: Action,
	screen: Screen,
): Result<Keybind, string> {
	let mods = NO_MODS;
	let code: string | null = null;
	for (const part of keys.split("+")) {
		const mod = modOf(part);
		if (mod !== null) {
			if (mods.has(mod)) { return Result.err(`"${keys}" names ${part} twice`); }
			mods = mods.incl(mod);
			continue;
		}
		if (code !== null) { return Result.err(`"${keys}" names more than one key`); }
		code = codeOf(part);
		if (code === null) {
			return Result.err(`"${keys}": "${part}" is not a key or modifier name`);
		}
	}
	if (code === null) { return Result.err(`"${keys}" names no key`); }
	return Result.ok({ code: code, mods: mods, text: text, action: action, screen: screen });
}

function appliesOn(screen: Screen, altScreen: boolean): boolean {
	return screen == Screen.Any || screen == (altScreen ? Screen.Alternate : Screen.Primary);
}

export function bindFor(
	binds: Readonly<Span<Keybind>>,
	code: string,
	mods: BitSet<KeyMod>,
	altScreen: boolean,
): Keybind | null {
	const held = chordOf(mods);
	for (const b of binds) {
		if (b.code == code && b.mods == held && appliesOn(b.screen, altScreen)) { return { ...b }; }
	}
	return null;
}

function lookup(
	table: Readonly<Span<Binding>>,
	code: string,
	held: BitSet<KeyMod>,
	altScreen: boolean,
): Action | null {
	for (const b of table) {
		if (b.code == code && b.mods == held && appliesOn(b.screen, altScreen)) { return b.action; }
	}
	return null;
}

export function resolve(code: string, mods: BitSet<KeyMod>, altScreen: boolean): Action | null {
	const held = chordOf(mods);
	const found = lookup(BINDINGS, code, held, altScreen);
	return found !== null ? found : lookup(OS_CHORDS, code, held, altScreen);
}

const CAPS_LOCK = modSet(KeyMod.CapsLock);
const NUM_LOCK = modSet(KeyMod.NumLock);
const SHIFT_RIGHT = modSet(KeyMod.ShiftRight);

test "copy and paste take cmd on macos, and ctrl shift or the insert pair elsewhere" {
	assert resolve("KeyC", CLIPBOARD_MODS, false) == Action.Copy;
	assert resolve("KeyV", CLIPBOARD_MODS, false) == Action.Paste;
	when (macos) {
		assert resolve("KeyV", CTRL | SHIFT, false) === null;
		assert resolve("KeyC", CTRL | SHIFT, false) === null;
		assert resolve("Insert", SHIFT, false) === null;
		assert resolve("Insert", CTRL, false) === null;
	} else {
		assert resolve("KeyV", SUPER, false) === null;
		assert resolve("Insert", CTRL, false) == Action.Copy;
		assert resolve("Insert", SHIFT, false) == Action.Paste;
	}
}

test "select all takes cmd a on macos and ctrl shift a elsewhere" {
	assert resolve("KeyA", CLIPBOARD_MODS, false) == Action.SelectAll;
	assert resolve("KeyA", CLIPBOARD_MODS, true) == Action.SelectAll;
	assert resolve("KeyA", NO_MODS, false) === null;
	assert resolve("KeyA", CTRL, false) === null;
}

test "clear scrollback takes cmd k on macos and ctrl shift k elsewhere" {
	assert resolve("KeyK", CLIPBOARD_MODS, false) == Action.ClearScrollback;
	assert resolve("KeyK", NO_MODS, false) === null;
}

test "font size keys take cmd on macos and ctrl elsewhere, with or without shift for plus" {
	assert resolve("Equal", APP_MODS, false) == Action.IncreaseFontSize;
	assert resolve("Equal", APP_MODS | SHIFT, true) == Action.IncreaseFontSize;
	assert resolve("Minus", APP_MODS, false) == Action.DecreaseFontSize;
	assert resolve("Digit0", APP_MODS, false) == Action.ResetFontSize;
	assert resolve("Minus", NO_MODS, false) === null;
	assert resolve("Digit0", SHIFT, false) === null;
}

test "the config keys take cmd comma to open and cmd shift comma to reload, ctrl elsewhere" {
	assert resolve("Comma", APP_MODS, false) == Action.OpenConfig;
	assert resolve("Comma", APP_MODS | SHIFT, true) == Action.ReloadConfig;
	assert resolve("Comma", NO_MODS, false) === null;
}

test "ctrl shift with an arrow, a page key, home or end scrolls the scrollback" {
	assert resolve("ArrowUp", CTRL | SHIFT, false) == Action.LineUp;
	assert resolve("ArrowDown", CTRL | SHIFT, false) == Action.LineDown;
	assert resolve("PageUp", CTRL | SHIFT, false) == Action.PageUp;
	assert resolve("PageDown", CTRL | SHIFT, false) == Action.PageDown;
	assert resolve("Home", CTRL | SHIFT, false) == Action.Top;
	assert resolve("End", CTRL | SHIFT, false) == Action.Bottom;
}

test "a chord needs exactly its modifiers" {
	assert resolve("KeyC", CTRL, false) === null;
	assert resolve("KeyC", SHIFT, false) === null;
	assert resolve("KeyC", SHIFT | CTRL | ALT, false) === null;
	assert resolve("KeyV", CTRL, false) === null;
	assert resolve("Enter", SHIFT, false) === null;
	assert resolve("ArrowUp", NO_MODS, false) === null;
	assert resolve("ArrowUp", SHIFT, false) === null;
}

test "lock and side bits do not change the chord" {
	assert resolve("ArrowUp", CTRL | SHIFT | NUM_LOCK, false) == Action.LineUp;
	assert resolve("ArrowUp", CTRL | SHIFT | SHIFT_RIGHT, false) == Action.LineUp;
	assert resolve("KeyV", CLIPBOARD_MODS | NUM_LOCK, false) == Action.Paste;
	assert resolve("KeyC", CLIPBOARD_MODS | CAPS_LOCK, false) == Action.Copy;
}

test "enter copies a selection on windows only" {
	when (windows) {
		assert resolve("Enter", NO_MODS, false) == Action.Copy;
		assert resolve("Enter", CAPS_LOCK, false) == Action.Copy;
	} else {
		assert resolve("Enter", NO_MODS, false) === null;
	}
}

test "shift page keys scroll the primary screen and reach a full-screen app on the alternate" {
	assert resolve("PageUp", SHIFT, false) == Action.PageUp;
	assert resolve("PageDown", SHIFT, false) == Action.PageDown;
	assert resolve("PageUp", SHIFT, true) === null;
	assert resolve("PageUp", CTRL | SHIFT, true) == Action.PageUp;
}

test "ctrl alt up and down jump between prompts, ctrl shift up and down scroll by line" {
	assert resolve("ArrowUp", CTRL | ALT, false) == Action.PromptUp;
	assert resolve("ArrowDown", CTRL | ALT, false) == Action.PromptDown;
	assert resolve("ArrowUp", CTRL | SHIFT, false) == Action.LineUp;
	assert resolve("ArrowUp", ALT, false) === null;
	assert resolve("ArrowUp", CTRL, false) === null;
}

test "a key with no binding resolves to nothing" {
	assert resolve("KeyA", NO_MODS, false) === null;
	assert resolve("KeyC", NO_MODS, false) === null;
	assert resolve("", NO_MODS, false) === null;
}

function bound(keys: string): string {
	const b = keybind(keys, "x", Action.SendText, Screen.Any);
	if (!b.ok) { return b.error; }
	return `${b.value.code} ${modsMask(b.value.mods)}`;
}

test "a keybind names its modifiers and one key, joined by plus signs" {
	assert bound("shift+enter") == "Enter 1";
	assert bound("ctrl+shift+h") == "KeyH 3";
	assert bound("control+key_h") == "KeyH 2";
	assert bound("alt+digit_1") == "Digit1 4";
	assert bound("super+arrow_up") == "ArrowUp 8";
	assert bound("page_down") == "PageDown 0";
	assert bound("f12") == "F12 0";
	assert bound("numpad_7") == "Numpad7 0";
}

test "a keybind that is not a trigger is refused by name" {
	assert bound("shift+entre") == `"shift+entre": "entre" is not a key or modifier name`;
	assert bound("ctrl+ctrl+a") == `"ctrl+ctrl+a" names ctrl twice`;
	assert bound("a+b") == `"a+b" names more than one key`;
	assert bound("ctrl+shift") == `"ctrl+shift" names no key`;
	assert bound("key_5") == `"key_5": "key_5" is not a key or modifier name`;
	assert bound("digit_a") == `"digit_a": "digit_a" is not a key or modifier name`;
	assert !keybind("f25", "x", Action.SendText, Screen.Any).ok;
	assert !keybind("f01", "x", Action.SendText, Screen.Any).ok;
}

test "a keybind's text answers exactly its chord, side and lock bits aside" {
	const binds: Vec<Keybind> = [
		{ code: "Enter", mods: SHIFT, text: "a", action: Action.SendText, screen: Screen.Any },
		{
			code: "KeyH",
			mods: CTRL | SHIFT,
			text: "b",
			action: Action.SendText,
			screen: Screen.Any,
		},
	];
	assert bindFor(binds, "Enter", SHIFT, false)?.text == "a";
	assert bindFor(binds, "Enter", SHIFT | SHIFT_RIGHT | NUM_LOCK, true)?.text == "a";
	assert bindFor(binds, "Enter", NO_MODS, false) === null;
	assert bindFor(binds, "Enter", SHIFT | CTRL, false) === null;
	assert bindFor(binds, "KeyH", CTRL | SHIFT, false)?.text == "b";
}

test "a keybind for one screen answers only on that screen" {
	const binds: Vec<Keybind> = [
		{
			code: "KeyW",
			mods: SUPER,
			text: "\x1b[119;9u",
			action: Action.SendText,
			screen: Screen.Alternate,
		},
		{
			code: "KeyW",
			mods: SUPER,
			text: "",
			action: Action.CloseWindow,
			screen: Screen.Primary,
		},
	];
	const inApp = bindFor(binds, "KeyW", SUPER, true);
	assert inApp !== null;
	if (inApp !== null) {
		assert inApp.action == Action.SendText && inApp.text == "\x1b[119;9u";
	}
	const atShell = bindFor(binds, "KeyW", SUPER, false);
	assert atShell !== null;
	if (atShell !== null) { assert atShell.action == Action.CloseWindow; }
}
