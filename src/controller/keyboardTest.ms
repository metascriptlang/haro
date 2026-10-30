import { KeyAction, KeyEvent, KeyMod, NO_MODS, modSet } from "../keys/keys";
const ALT = modSet(KeyMod.Alt);
const CTRL = modSet(KeyMod.Ctrl);
const NUM_LOCK = modSet(KeyMod.NumLock);
const SHIFT = modSet(KeyMod.Shift);
const SUPER = modSet(KeyMod.Super);
import { selected } from "../input/pointer";
import { Term, releaseHeldKey, sendKey } from "./term";
import { Controls, holding } from "./controls";
import { closeKey, closeWindow, keyDown, keyUp } from "./keyboard";
import { Warning } from "../input/paste";
import { Action, CLIPBOARD_MODS, Keybind, Screen } from "../input/bindings";
import {
	Sink,
	spotAt,
	atBottomOf,
	boardOf,
	settled,
	drag,
	handled,
	key,
	lines,
	offsetOf,
	onTerm,
} from "./terminalRig";

test "ctrl shift page, arrow, home and end keys move the viewport and say they did" {
	assert onTerm(lines(30), (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("");
		const bottom = offsetOf(t);
		assert bottom > 0;
		assert atBottomOf(t);
		assert handled(settled(clip, c, t, c.keyDown(t, key("PageUp", CTRL | SHIFT))));
		assert offsetOf(t) == bottom - 5;
		assert handled(settled(clip, c, t, c.keyDown(t, key("ArrowUp", CTRL | SHIFT))));
		assert offsetOf(t) == bottom - 8;
		assert handled(settled(clip, c, t, c.keyDown(t, key("ArrowDown", CTRL | SHIFT))));
		assert offsetOf(t) == bottom - 5;
		assert handled(settled(clip, c, t, c.keyDown(t, key("Home", CTRL | SHIFT))));
		assert offsetOf(t) == 0;
		assert handled(settled(clip, c, t, c.keyDown(t, key("PageDown", CTRL | SHIFT))));
		assert offsetOf(t) == 5;
		assert handled(settled(clip, c, t, c.keyDown(t, key("End", CTRL | SHIFT))));
		assert atBottomOf(t);
		assert !handled(settled(clip, c, t, c.keyDown(t, key("ArrowUp", NO_MODS))));
		assert !handled(settled(clip, c, t, c.keyDown(t, key("PageUp", NO_MODS))));
		assert sink.sent == "";
	}).ok;
}

test "the copy chord, and enter on windows, copy the selection to the clipboard and dismiss it" {
	assert onTerm("alpha beta\r\ngamma", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const board = boardOf("");
		const clip = board;
		assert !handled(settled(clip, c, t, c.keyDown(t, key("KeyC", CLIPBOARD_MODS))));
		assert board.copied == "";
		assert drag(c, t, clip, spotAt(0, 0), spotAt(4, 0));
		assert c.pointer.selected();
		assert handled(settled(clip, c, t, c.keyDown(t, key("KeyC", CLIPBOARD_MODS))));
		assert board.copied == "alpha";
		assert !c.pointer.selected();
		assert !handled(settled(clip, c, t, c.keyDown(t, key("KeyC", CLIPBOARD_MODS))));
		when (windows) {
			assert !handled(settled(clip, c, t, c.keyDown(t, key("Enter", NO_MODS))));
			assert drag(c, t, clip, spotAt(6, 0), spotAt(9, 0));
			assert handled(settled(clip, c, t, c.keyDown(t, key("Enter", NO_MODS))));
			assert board.copied == "beta";
		}
		when (!macos) {
			assert drag(c, t, clip, spotAt(0, 1), spotAt(4, 1));
			assert handled(settled(clip, c, t, c.keyDown(t, key("Insert", CTRL))));
			assert board.copied == "gamma";
		}
	}).ok;
}

test "paste sends the clipboard through the terminal's paste encoding" {
	assert onTerm("ready", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const board = boardOf("echo hi\r\n");
		const clip = board;
		assert handled(settled(clip, c, t, c.keyDown(t, key("KeyV", CLIPBOARD_MODS))));
		assert board.reads == 1;
		assert sink.sent == "echo hi";
		when (!macos) {
			assert handled(settled(clip, c, t, c.keyDown(t, key("Insert", SHIFT))));
			assert sink.sent == "echo hiecho hi";
		}
		const reads = board.reads;
		assert !handled(settled(clip, c, t, c.keyDown(t, key("KeyV", CTRL))));
		assert board.reads == reads;
	}).ok;
}

test "a paste with a line break waits for an answer and sends nothing meanwhile" {
	assert onTerm("ready", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("one\r\ntwo");
		assert handled(settled(clip, c, t, c.keyDown(t, key("KeyV", CLIPBOARD_MODS))));
		assert c.holding();
		const held = c.held;
		assert held !== null;
		if (held !== null) {
			assert held.warning == Warning.MultiLine;
			assert held.text == "one\ntwo";
		}
		assert sink.sent == "";
		assert handled(settled(clip, c, t, c.keyDown(t, key("KeyA", NO_MODS))));
		assert handled(settled(clip, c, t, c.keyDown(t, key("ArrowUp", CTRL | SHIFT))));
		assert handled(settled(clip, c, t, c.keyDown(t, key("KeyC", CLIPBOARD_MODS))));
		assert sink.sent == "";
		assert c.holding();
	}).ok;
}

test "enter confirms a held paste and it goes out through the paste encoding" {
	assert onTerm("ready", (a: Term, plain: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("one\r\ntwo");
		assert handled(settled(clip, c, a, c.keyDown(a, key("KeyV", CLIPBOARD_MODS))));
		assert handled(settled(clip, c, a, c.keyDown(a, key("Enter", NO_MODS))));
		assert !c.holding();
		assert plain.sent == "one\rtwo";
	}).ok;
	assert onTerm("ready", (b: Term, chord: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("one\r\ntwo");
		assert handled(settled(clip, c, b, c.keyDown(b, key("KeyV", CLIPBOARD_MODS))));
		assert handled(settled(clip, c, b, c.keyDown(b, key("KeyV", CLIPBOARD_MODS))));
		assert chord.sent == "one\rtwo";
	}).ok;
}

test "escape drops a held paste and the next key reaches the shell again" {
	assert onTerm("ready", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("one\r\ntwo");
		assert handled(settled(clip, c, t, c.keyDown(t, key("KeyV", CLIPBOARD_MODS))));
		assert handled(settled(clip, c, t, c.keyDown(t, key("Escape", NO_MODS))));
		assert !c.holding();
		assert sink.sent == "";
		assert !handled(settled(clip, c, t, c.keyDown(t, key("KeyA", NO_MODS))));
	}).ok;
}

test "ctrl alt up and down move the viewport between prompts the shell marked" {
	const marked = "\x1b]133;A\x07p1\r\nout1\r\nout2\r\n" +
		"\x1b]133;A\x07p2\r\nout3\r\n\x1b]133;A\x07p3";
	assert onTerm(marked, (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("");
		const bottom = offsetOf(t);
		assert handled(settled(clip, c, t, c.keyDown(t, key("ArrowUp", CTRL | ALT))));
		assert offsetOf(t) < bottom;
		assert handled(settled(clip, c, t, c.keyDown(t, key("ArrowDown", CTRL | ALT))));
		assert sink.sent == "";
	}, 10, 3).ok;
}

test "a configured keybind sends its text, ahead of a built-in chord on the same keys" {
	assert onTerm(lines(30), (t: Term, sink: Sink): void => {
		const c = Controls.open();
		c.keybinds = [
			{
				code: "Enter",
				mods: SHIFT,
				text: "\x1b[13;2u",
				action: Action.SendText,
				screen: Screen.Any,
			},
			{
				code: "KeyC",
				mods: CTRL | SHIFT,
				text: "c",
				action: Action.SendText,
				screen: Screen.Any,
			},
		];
		const clip = boardOf("");
		assert handled(settled(clip, c, t, c.keyDown(t, key("PageUp", CTRL | SHIFT))));
		assert handled(settled(clip, c, t, c.keyDown(t, key("Enter", SHIFT))));
		assert sink.sent == "\x1b[13;2u";
		assert atBottomOf(t);
		assert handled(settled(clip, c, t, c.keyDown(t, key("KeyC", CTRL | SHIFT))));
		assert sink.sent == "\x1b[13;2uc";
		assert !handled(settled(clip, c, t, c.keyDown(t, key("Enter", CTRL))));
	}).ok;
}

test "a ctrl alt keybind leaves the character AltGr types on the same key to the program" {
	assert onTerm("ready", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		c.keybinds = [
			{
				code: "KeyQ",
				mods: CTRL | ALT,
				text: "x",
				action: Action.SendText,
				screen: Screen.Any,
			},
		];
		const clip = boardOf("");
		const altGr: KeyEvent = { ...key("KeyQ", CTRL | ALT), consumedMods: CTRL | ALT, text: "@" };
		assert !handled(settled(clip, c, t, c.keyDown(t, altGr)));
		assert sink.sent == "";
		assert handled(settled(clip, c, t, c.keyDown(t, key("KeyQ", CTRL | ALT))));
		assert sink.sent == "x";
	}).ok;
}

function released(code: string, unshifted: int32): KeyEvent {
	return { ...key(code, NO_MODS), action: KeyAction.Release, unshifted: unshifted as uint32 };
}

test "a key release reaches a program only once it asks for event types" {
	assert onTerm("ready", (plain: Term, legacy: Sink): void => {
		assert plain.sendKey(released("KeyA", 0x61)).ok;
		assert legacy.sent == "";
	}).ok;
	assert onTerm("\x1b[>3u", (t: Term, kitty: Sink): void => {
		assert t.sendKey(released("KeyA", 0x61)).ok;
		assert kitty.sent == "\x1b[97;1:3u";
	}).ok;
}

test "a focus loss releases the key still held, once, to a program that asks for event types" {
	assert onTerm("\x1b[>3u", (t: Term, sink: Sink): void => {
		const a: KeyEvent = { ...key("KeyA", NO_MODS), unshifted: 0x61 };
		assert t.sendKey(a).ok;
		sink.sent = "";
		assert t.releaseHeldKey().ok;
		assert sink.sent == "\x1b[97;1:3u";
		assert t.releaseHeldKey().ok;
		assert sink.sent == "\x1b[97;1:3u";
		assert t.sendKey(a).ok;
		assert t.sendKey(released("KeyA", 0x61)).ok;
		sink.sent = "";
		assert t.releaseHeldKey().ok;
		assert sink.sent == "";
	}).ok;
}

test "the release of a key a control consumed is consumed too, and any other goes on" {
	assert onTerm(lines(30), (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("");
		assert handled(settled(clip, c, t, c.keyDown(t, key("PageUp", CTRL | SHIFT))));
		assert c.keyUp(released("PageUp", 0));
		assert !c.keyUp(released("KeyA", 0x61));
		assert !handled(settled(clip, c, t, c.keyDown(t, key("KeyA", NO_MODS))));
		assert !c.keyUp(released("PageUp", 0));
	}).ok;
}

test "a keypad digit without NumLock is its navigation key on Windows, which alone reports NumLock" {
	assert onTerm("ready", (t: Term, sink: Sink): void => {
		assert t.sendKey(key("Numpad8", NO_MODS)).ok;
		when (windows) {
			assert sink.sent == "\x1b[A";
		} else {
			assert sink.sent == "8";
		}
		sink.sent = "";
		const locked: KeyEvent = { ...key("Numpad8", NUM_LOCK), text: "8" };
		assert t.sendKey(locked).ok;
		assert sink.sent == "8";
	}).ok;
}

test "a keybind with a mode sends to a full-screen program and closes the window at the shell" {
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
	assert onTerm("$ ", (shell: Term, atShell: Sink): void => {
		assert onTerm("\x1b[?1049h", (app: Term, inApp: Sink): void => {
			const c = Controls.open();
			c.keybinds = binds;
			const board = boardOf("");
			const clip = board;
			assert handled(settled(clip, c, app, c.keyDown(app, key("KeyW", SUPER))));
			assert inApp.sent == "\x1b[119;9u";
			assert board.closed == 0;
			assert handled(settled(clip, c, shell, c.keyDown(shell, key("KeyW", SUPER))));
			assert atShell.sent == "";
			assert board.closed == 1;
		}).ok;
	}).ok;
}

test "closing while a program runs asks first: escape keeps the window and enter closes it" {
	assert onTerm("$ ", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const board = boardOf("");
		const clip = board;
		sink.busy = true;
		assert handled(settled(clip, c, t, c.closeKey(t)));
		assert c.closing;
		assert c.holding();
		assert board.closed == 0;
		assert handled(settled(clip, c, t, c.keyDown(t, key("KeyX", NO_MODS))));
		assert handled(settled(clip, c, t, c.keyDown(t, key("Escape", NO_MODS))));
		assert !c.closing;
		assert board.closed == 0;
		assert sink.sent == "";
		assert handled(settled(clip, c, t, c.closeKey(t)));
		assert handled(settled(clip, c, t, c.keyDown(t, key("Enter", NO_MODS))));
		assert !c.closing;
		assert board.closed == 1;
		sink.busy = false;
		assert handled(settled(clip, c, t, c.closeKey(t)));
		assert !c.closing;
		assert board.closed == 2;
	}).ok;
}

test "a close_window keybind asks first while a program runs, like the menu" {
	const binds: Vec<Keybind> = [
		{
			code: "KeyW",
			mods: SUPER,
			text: "",
			action: Action.CloseWindow,
			screen: Screen.Any,
		},
	];
	assert onTerm("$ ", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		c.keybinds = binds;
		const board = boardOf("");
		const clip = board;
		sink.busy = true;
		assert handled(settled(clip, c, t, c.keyDown(t, key("KeyW", SUPER))));
		assert c.closing;
		assert board.closed == 0;
		assert handled(settled(clip, c, t, c.keyDown(t, key("Enter", NO_MODS))));
		assert board.closed == 1;
	}).ok;
}

test "close window from the menu runs a super w keybind for this screen and otherwise closes" {
	const binds: Vec<Keybind> = [
		{
			code: "KeyW",
			mods: SUPER,
			text: "\x1b[119;9u",
			action: Action.SendText,
			screen: Screen.Alternate,
		},
	];
	assert onTerm("$ ", (shell: Term, atShell: Sink): void => {
		assert onTerm("\x1b[?1049h", (app: Term, inApp: Sink): void => {
			const c = Controls.open();
			c.keybinds = binds;
			const board = boardOf("");
			const clip = board;
			assert handled(settled(clip, c, app, c.closeKey(app)));
			assert inApp.sent == "\x1b[119;9u";
			assert board.closed == 0;
			assert handled(settled(clip, c, shell, c.closeKey(shell)));
			assert atShell.sent == "";
			assert board.closed == 1;
			c.keybinds = [];
			assert handled(settled(clip, c, app, c.closeKey(app)));
			assert inApp.sent == "\x1b[119;9u";
			assert board.closed == 2;
		}).ok;
	}).ok;
}

test "the close button and Quit close the window without running the super w keybind" {
	const binds: Vec<Keybind> = [
		{
			code: "KeyW",
			mods: SUPER,
			text: "\x1b[119;9u",
			action: Action.SendText,
			screen: Screen.Alternate,
		},
	];
	assert onTerm("\x1b[?1049h", (app: Term, inApp: Sink): void => {
		const c = Controls.open();
		c.keybinds = binds;
		const board = boardOf("");
		c.closeWindow(app);
		assert handled(settled(board, c, app, Result.ok(true)));
		assert inApp.sent == "";
		assert board.closed == 1;
		inApp.busy = true;
		c.closeWindow(app);
		assert c.closing;
		assert inApp.sent == "";
	}).ok;
}

test "a keybind that names a built-in action runs it, and for one screen only when its mode says so" {
	assert onTerm(lines(30), (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("");
		c.keybinds = [
			{ code: "KeyJ", mods: SUPER, text: "", action: Action.Top, screen: Screen.Primary },
			{ code: "KeyK", mods: SUPER, text: "", action: Action.Top, screen: Screen.Alternate },
		];
		const bottom = offsetOf(t);
		assert bottom > 0;
		assert !handled(settled(clip, c, t, c.keyDown(t, key("KeyK", SUPER))));
		assert offsetOf(t) == bottom;
		assert handled(settled(clip, c, t, c.keyDown(t, key("KeyJ", SUPER))));
		assert offsetOf(t) == 0;
		assert sink.sent == "";
	}).ok;
}
