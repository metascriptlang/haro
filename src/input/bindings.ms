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

const SHIFT: int32 = 1;
export const CTRL: int32 = 2;
const ALT: int32 = 4;
const SUPER: int32 = 8;
const CHORD: int32 = SHIFT | CTRL | ALT | SUPER;

export function chordOf(mods: number): int32 {
	return (mods as int32) & CHORD;
}

struct Binding {
	code: string;
	mods: int32;
	action: Action;
	primaryOnly: boolean;
}

when (macos) {
	export const CLIPBOARD_MODS: int32 = SUPER;
	const INSERT_CHORDS: Vec<Binding> = [];
} else {
	export const CLIPBOARD_MODS: int32 = CTRL | SHIFT;
	const INSERT_CHORDS: Vec<Binding> = [
		{ code: "Insert", mods: CTRL, action: Action.Copy, primaryOnly: false },
		{ code: "Insert", mods: SHIFT, action: Action.Paste, primaryOnly: false },
	];
}

const BINDINGS: Vec<Binding> = [
	{ code: "KeyC", mods: CLIPBOARD_MODS, action: Action.Copy, primaryOnly: false },
	{ code: "Enter", mods: 0, action: Action.Copy, primaryOnly: false },
	{ code: "KeyV", mods: CLIPBOARD_MODS, action: Action.Paste, primaryOnly: false },
	{ code: "ArrowUp", mods: CTRL | SHIFT, action: Action.LineUp, primaryOnly: false },
	{ code: "ArrowDown", mods: CTRL | SHIFT, action: Action.LineDown, primaryOnly: false },
	{ code: "PageUp", mods: CTRL | SHIFT, action: Action.PageUp, primaryOnly: false },
	{ code: "PageDown", mods: CTRL | SHIFT, action: Action.PageDown, primaryOnly: false },
	{ code: "Home", mods: CTRL | SHIFT, action: Action.Top, primaryOnly: false },
	{ code: "End", mods: CTRL | SHIFT, action: Action.Bottom, primaryOnly: false },
	{ code: "ArrowUp", mods: CTRL | ALT, action: Action.PromptUp, primaryOnly: false },
	{ code: "ArrowDown", mods: CTRL | ALT, action: Action.PromptDown, primaryOnly: false },
	{ code: "PageUp", mods: SHIFT, action: Action.PageUp, primaryOnly: true },
	{ code: "PageDown", mods: SHIFT, action: Action.PageDown, primaryOnly: true },
];

export enum BindAction {
	SendText,
	CloseWindow,
}

export enum Screen {
	Any,
	Alternate,
	Primary,
}

export struct Keybind {
	code: string;
	mods: int32;
	text: string;
	action: BindAction;
	screen: Screen;
}

function modOf(name: string): int32 {
	return match (name) {
		"shift" => SHIFT,
		"ctrl" | "control" => CTRL,
		"alt" | "opt" | "option" => ALT,
		"super" | "cmd" | "command" => SUPER,
		_ => 0,
	};
}

const KEY_NAMES: Vec<string> = [
	"backquote", "backslash", "bracket_left", "bracket_right", "comma", "equal", "minus", "period", "quote",
	"semicolon", "slash", "backspace", "enter", "space", "tab", "escape", "delete", "end", "home", "insert",
	"page_down", "page_up", "arrow_down", "arrow_left", "arrow_right", "arrow_up", "numpad_add",
	"numpad_decimal", "numpad_divide", "numpad_enter", "numpad_multiply", "numpad_subtract",
];

function pascal(snake: string): string {
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
	if (name.startsWith("numpad_") && name.length == 8 && name[7] >= "0" && name[7] <= "9") { return pascal(name); }
	if (name.length >= 2 && name.length <= 3 && name[0] == "f") {
		const n = name.slice(1).parseInt();
		if (n >= 1 && n <= 24 && `f${n}` == name) { return `F${n}`; }
	}
	for (const known of KEY_NAMES) {
		if (known == name) { return pascal(name); }
	}
	return null;
}

export function keybind(keys: string, text: string, action: BindAction, screen: Screen): Result<Keybind, string> {
	let mods = 0;
	let code: string | null = null;
	for (const part of keys.split("+")) {
		const mod = modOf(part);
		if (mod != 0) {
			if ((mods & mod) != 0) { return Result.err(`"${keys}" names ${part} twice`); }
			mods = mods | mod;
			continue;
		}
		if (code !== null) { return Result.err(`"${keys}" names more than one key`); }
		code = codeOf(part);
		if (code === null) { return Result.err(`"${keys}": "${part}" is not a key or modifier name`); }
	}
	if (code === null) { return Result.err(`"${keys}" names no key`); }
	return Result.ok({ code: code, mods: mods, text: text, action: action, screen: screen });
}

export function bindFor(binds: Readonly<Span<Keybind>>, code: string, mods: number, altScreen: boolean): Keybind | null {
	const held = chordOf(mods);
	const here = altScreen ? Screen.Alternate : Screen.Primary;
	for (const b of binds) {
		if (b.code == code && b.mods == held && (b.screen == Screen.Any || b.screen == here)) { return b; }
	}
	return null;
}

function lookup(table: Readonly<Span<Binding>>, code: string, held: int32, altScreen: boolean): Action {
	for (const b of table) {
		if (b.code == code && b.mods == held && !(b.primaryOnly && altScreen)) { return b.action; }
	}
	return Action.None;
}

export function resolve(code: string, mods: number, altScreen: boolean): Action {
	const held = chordOf(mods);
	const found = lookup(BINDINGS, code, held, altScreen);
	return found != Action.None ? found : lookup(INSERT_CHORDS, code, held, altScreen);
}

test "copy and paste take cmd on macos, and ctrl shift or the insert pair elsewhere" {
	assert resolve("KeyC", CLIPBOARD_MODS, false) == Action.Copy;
	assert resolve("KeyV", CLIPBOARD_MODS, false) == Action.Paste;
	assert resolve("Enter", 0, false) == Action.Copy;
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
	assert resolve("ArrowUp", 3, false) == Action.LineUp;
	assert resolve("ArrowDown", 3, false) == Action.LineDown;
	assert resolve("PageUp", 3, false) == Action.PageUp;
	assert resolve("PageDown", 3, false) == Action.PageDown;
	assert resolve("Home", 3, false) == Action.Top;
	assert resolve("End", 3, false) == Action.Bottom;
}

test "a chord needs exactly its modifiers" {
	assert resolve("KeyC", 2, false) == Action.None;
	assert resolve("KeyC", 1, false) == Action.None;
	assert resolve("KeyC", 7, false) == Action.None;
	assert resolve("KeyV", 2, false) == Action.None;
	assert resolve("Enter", 1, false) == Action.None;
	assert resolve("ArrowUp", 0, false) == Action.None;
	assert resolve("ArrowUp", 1, false) == Action.None;
}

test "lock and side bits do not change the chord" {
	const numLock = 32;
	const shiftRight = 64;
	const ctrlLeftShiftRight = 2 | shiftRight | 1;
	assert resolve("ArrowUp", 3 | numLock, false) == Action.LineUp;
	assert resolve("ArrowUp", ctrlLeftShiftRight, false) == Action.LineUp;
	assert resolve("KeyV", CLIPBOARD_MODS | numLock, false) == Action.Paste;
	assert resolve("Enter", 16, false) == Action.Copy;
}

test "shift page keys scroll on the primary screen and reach a full-screen app on the alternate one" {
	assert resolve("PageUp", 1, false) == Action.PageUp;
	assert resolve("PageDown", 1, false) == Action.PageDown;
	assert resolve("PageUp", 1, true) == Action.None;
	assert resolve("PageUp", 3, true) == Action.PageUp;
}

test "ctrl alt up and down jump between prompts, leaving ctrl shift up and down to the line scroll" {
	assert resolve("ArrowUp", 6, false) == Action.PromptUp;
	assert resolve("ArrowDown", 6, false) == Action.PromptDown;
	assert resolve("ArrowUp", 3, false) == Action.LineUp;
	assert resolve("ArrowUp", 4, false) == Action.None;
	assert resolve("ArrowUp", 2, false) == Action.None;
}

test "a key with no binding resolves to nothing" {
	assert resolve("KeyA", 0, false) == Action.None;
	assert resolve("KeyC", 0, false) == Action.None;
	assert resolve("", 0, false) == Action.None;
}

function bound(keys: string): string {
	const b = keybind(keys, "x", BindAction.SendText, Screen.Any);
	if (!b.ok) { return b.error; }
	return `${b.value.code} ${b.value.mods}`;
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

function textOf(b: Keybind | null): string | null {
	return b === null ? null : b.text;
}

test "a keybind's text answers exactly its chord, side and lock bits aside" {
	const binds: Vec<Keybind> = [
		{ code: "Enter", mods: SHIFT, text: "a", action: BindAction.SendText, screen: Screen.Any },
		{ code: "KeyH", mods: CTRL | SHIFT, text: "b", action: BindAction.SendText, screen: Screen.Any },
	];
	assert textOf(bindFor(binds, "Enter", SHIFT, false)) == "a";
	assert textOf(bindFor(binds, "Enter", SHIFT | 64 | 32, true)) == "a";
	assert bindFor(binds, "Enter", 0, false) === null;
	assert bindFor(binds, "Enter", SHIFT | CTRL, false) === null;
	assert textOf(bindFor(binds, "KeyH", CTRL | SHIFT, false)) == "b";
}

test "a keybind for one screen answers only on that screen" {
	const binds: Vec<Keybind> = [
		{ code: "KeyW", mods: SUPER, text: "\x1b[119;9u", action: BindAction.SendText, screen: Screen.Alternate },
		{ code: "KeyW", mods: SUPER, text: "", action: BindAction.CloseWindow, screen: Screen.Primary },
	];
	const inApp = bindFor(binds, "KeyW", SUPER, true);
	assert inApp !== null;
	if (inApp !== null) { assert inApp.action == BindAction.SendText && inApp.text == "\x1b[119;9u"; }
	const atShell = bindFor(binds, "KeyW", SUPER, false);
	assert atShell !== null;
	if (atShell !== null) { assert atShell.action == BindAction.CloseWindow; }
}
