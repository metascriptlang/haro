import { KeyMod, NO_MODS, modSet, modsMask } from "../keys/keys";

export enum Action {
	None,
	Copy,
	Paste,
	LineUp,
	LineDown,
	PageUp,
	PageDown,
	Top,
	Bottom,
	PromptUp,
	PromptDown,
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
	const OS_CHORDS: Vec<Binding> = [];
} else when (windows) {
	export const CLIPBOARD_MODS: BitSet<KeyMod> = CTRL | SHIFT;
	const OS_CHORDS: Vec<Binding> = [
		{ code: "Insert", mods: CTRL, action: Action.Copy, screen: Screen.Any },
		{ code: "Insert", mods: SHIFT, action: Action.Paste, screen: Screen.Any },
		{ code: "Enter", mods: NO_MODS, action: Action.Copy, screen: Screen.Any },
	];
} else {
	export const CLIPBOARD_MODS: BitSet<KeyMod> = CTRL | SHIFT;
	const OS_CHORDS: Vec<Binding> = [
		{ code: "Insert", mods: CTRL, action: Action.Copy, screen: Screen.Any },
		{ code: "Insert", mods: SHIFT, action: Action.Paste, screen: Screen.Any },
	];
}

const BINDINGS: Vec<Binding> = [
	{ code: "KeyC", mods: CLIPBOARD_MODS, action: Action.Copy, screen: Screen.Any },
	{ code: "KeyV", mods: CLIPBOARD_MODS, action: Action.Paste, screen: Screen.Any },
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

export enum BindAction {
	SendText,
	CloseWindow,
}

export struct Keybind {
	code: string;
	mods: BitSet<KeyMod>;
	text: string;
	action: BindAction;
	screen: Screen;
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
	if (name.startsWith("key_") && name.length == 5) { return codeOf(name.slice(4)); }
	if (name.startsWith("digit_") && name.length == 7) { return codeOf(name.slice(6)); }
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
	action: BindAction,
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
): Action {
	for (const b of table) {
		if (b.code == code && b.mods == held && appliesOn(b.screen, altScreen)) { return b.action; }
	}
	return Action.None;
}

export function resolve(code: string, mods: BitSet<KeyMod>, altScreen: boolean): Action {
	const held = chordOf(mods);
	const found = lookup(BINDINGS, code, held, altScreen);
	return found != Action.None ? found : lookup(OS_CHORDS, code, held, altScreen);
}

const CAPS_LOCK = modSet(KeyMod.CapsLock);
const NUM_LOCK = modSet(KeyMod.NumLock);
const SHIFT_RIGHT = modSet(KeyMod.ShiftRight);

test "copy and paste take cmd on macos, and ctrl shift or the insert pair elsewhere" {
	assert resolve("KeyC", CLIPBOARD_MODS, false) == Action.Copy;
	assert resolve("KeyV", CLIPBOARD_MODS, false) == Action.Paste;
	when (macos) {
		assert resolve("KeyV", CTRL | SHIFT, false) == Action.None;
		assert resolve("KeyC", CTRL | SHIFT, false) == Action.None;
		assert resolve("Insert", SHIFT, false) == Action.None;
		assert resolve("Insert", CTRL, false) == Action.None;
	} else {
		assert resolve("KeyV", SUPER, false) == Action.None;
		assert resolve("Insert", CTRL, false) == Action.Copy;
		assert resolve("Insert", SHIFT, false) == Action.Paste;
	}
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
	assert resolve("KeyC", CTRL, false) == Action.None;
	assert resolve("KeyC", SHIFT, false) == Action.None;
	assert resolve("KeyC", SHIFT | CTRL | ALT, false) == Action.None;
	assert resolve("KeyV", CTRL, false) == Action.None;
	assert resolve("Enter", SHIFT, false) == Action.None;
	assert resolve("ArrowUp", NO_MODS, false) == Action.None;
	assert resolve("ArrowUp", SHIFT, false) == Action.None;
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
		assert resolve("Enter", NO_MODS, false) == Action.None;
	}
}

test "shift page keys scroll the primary screen and reach a full-screen app on the alternate" {
	assert resolve("PageUp", SHIFT, false) == Action.PageUp;
	assert resolve("PageDown", SHIFT, false) == Action.PageDown;
	assert resolve("PageUp", SHIFT, true) == Action.None;
	assert resolve("PageUp", CTRL | SHIFT, true) == Action.PageUp;
}

test "ctrl alt up and down jump between prompts, ctrl shift up and down scroll by line" {
	assert resolve("ArrowUp", CTRL | ALT, false) == Action.PromptUp;
	assert resolve("ArrowDown", CTRL | ALT, false) == Action.PromptDown;
	assert resolve("ArrowUp", CTRL | SHIFT, false) == Action.LineUp;
	assert resolve("ArrowUp", ALT, false) == Action.None;
	assert resolve("ArrowUp", CTRL, false) == Action.None;
}

test "a key with no binding resolves to nothing" {
	assert resolve("KeyA", NO_MODS, false) == Action.None;
	assert resolve("KeyC", NO_MODS, false) == Action.None;
	assert resolve("", NO_MODS, false) == Action.None;
}

function bound(keys: string): string {
	const b = keybind(keys, "x", BindAction.SendText, Screen.Any);
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
	assert !keybind("f25", "x", BindAction.SendText, Screen.Any).ok;
	assert !keybind("f01", "x", BindAction.SendText, Screen.Any).ok;
}

test "a keybind's text answers exactly its chord, side and lock bits aside" {
	const binds: Vec<Keybind> = [
		{ code: "Enter", mods: SHIFT, text: "a", action: BindAction.SendText, screen: Screen.Any },
		{
			code: "KeyH",
			mods: CTRL | SHIFT,
			text: "b",
			action: BindAction.SendText,
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
			action: BindAction.SendText,
			screen: Screen.Alternate,
		},
		{
			code: "KeyW",
			mods: SUPER,
			text: "",
			action: BindAction.CloseWindow,
			screen: Screen.Primary,
		},
	];
	const inApp = bindFor(binds, "KeyW", SUPER, true);
	assert inApp !== null;
	if (inApp !== null) {
		assert inApp.action == BindAction.SendText && inApp.text == "\x1b[119;9u";
	}
	const atShell = bindFor(binds, "KeyW", SUPER, false);
	assert atShell !== null;
	if (atShell !== null) { assert atShell.action == BindAction.CloseWindow; }
}
