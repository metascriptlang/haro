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
}

const SHIFT: int32 = 1;
const CTRL: int32 = 2;
const ALT: int32 = 4;
const SUPER: int32 = 8;
const CHORD: int32 = SHIFT | CTRL | ALT | SUPER;

struct Binding {
	code: string;
	mods: int32;
	action: Action;
	primaryOnly: boolean;
}

const BINDINGS: Vec<Binding> = [
	{ code: "KeyC", mods: CTRL | SHIFT, action: Action.Copy, primaryOnly: false },
	{ code: "Insert", mods: CTRL, action: Action.Copy, primaryOnly: false },
	{ code: "Enter", mods: 0, action: Action.Copy, primaryOnly: false },
	{ code: "KeyV", mods: CTRL | SHIFT, action: Action.Paste, primaryOnly: false },
	{ code: "Insert", mods: SHIFT, action: Action.Paste, primaryOnly: false },
	{ code: "ArrowUp", mods: CTRL | SHIFT, action: Action.LineUp, primaryOnly: false },
	{ code: "ArrowDown", mods: CTRL | SHIFT, action: Action.LineDown, primaryOnly: false },
	{ code: "PageUp", mods: CTRL | SHIFT, action: Action.PageUp, primaryOnly: false },
	{ code: "PageDown", mods: CTRL | SHIFT, action: Action.PageDown, primaryOnly: false },
	{ code: "Home", mods: CTRL | SHIFT, action: Action.Top, primaryOnly: false },
	{ code: "End", mods: CTRL | SHIFT, action: Action.Bottom, primaryOnly: false },
	{ code: "PageUp", mods: SHIFT, action: Action.PageUp, primaryOnly: true },
	{ code: "PageDown", mods: SHIFT, action: Action.PageDown, primaryOnly: true },
];

export function resolve(code: string, mods: number, altScreen: boolean): Action {
	const held = (mods as int32) & CHORD;
	for (const b of BINDINGS) {
		if (b.code == code && b.mods == held && !(b.primaryOnly && altScreen)) { return b.action; }
	}
	return Action.None;
}

test "windows terminal's copy, paste and scrollback chords resolve" {
	assert resolve("KeyC", 3, false) == Action.Copy;
	assert resolve("Insert", 2, false) == Action.Copy;
	assert resolve("Enter", 0, false) == Action.Copy;
	assert resolve("KeyV", 3, false) == Action.Paste;
	assert resolve("Insert", 1, false) == Action.Paste;
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
	assert resolve("KeyV", 3 | numLock, false) == Action.Paste;
	assert resolve("KeyV", ctrlLeftShiftRight, false) == Action.Paste;
	assert resolve("Enter", 16, false) == Action.Copy;
}

test "shift page keys scroll on the primary screen and reach a full-screen app on the alternate one" {
	assert resolve("PageUp", 1, false) == Action.PageUp;
	assert resolve("PageDown", 1, false) == Action.PageDown;
	assert resolve("PageUp", 1, true) == Action.None;
	assert resolve("PageUp", 3, true) == Action.PageUp;
}

test "a key with no binding resolves to nothing" {
	assert resolve("KeyA", 0, false) == Action.None;
	assert resolve("KeyC", 0, false) == Action.None;
	assert resolve("", 0, false) == Action.None;
}
