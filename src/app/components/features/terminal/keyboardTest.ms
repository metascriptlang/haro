import { NeonEvent } from "../../../../../../neon/src/render/event";
import { selected } from "../../../../input/pointer";
import { Term, releaseHeldKey, sendKey } from "./term";
import { Controls, holding } from "./controls";
import { closeKey, keyDown, keyUp } from "./keyboard";
import { Warning } from "../../../../input/paste";
import {
	ALT,
	BindAction,
	CLIPBOARD_MODS,
	CTRL,
	Keybind,
	NUM_LOCK,
	SHIFT,
	SUPER,
	Screen,
} from "../../../../input/bindings";
import {
	Sink,
	at,
	atBottomOf,
	boardOf,
	clipOf,
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
		const clip = clipOf(boardOf(""));
		const bottom = offsetOf(t);
		assert bottom > 0;
		assert atBottomOf(t);
		assert handled(c.keyDown(t, key("PageUp", CTRL | SHIFT), clip));
		assert offsetOf(t) == bottom - 5;
		assert handled(c.keyDown(t, key("ArrowUp", CTRL | SHIFT), clip));
		assert offsetOf(t) == bottom - 8;
		assert handled(c.keyDown(t, key("ArrowDown", CTRL | SHIFT), clip));
		assert offsetOf(t) == bottom - 5;
		assert handled(c.keyDown(t, key("Home", CTRL | SHIFT), clip));
		assert offsetOf(t) == 0;
		assert handled(c.keyDown(t, key("PageDown", CTRL | SHIFT), clip));
		assert offsetOf(t) == 5;
		assert handled(c.keyDown(t, key("End", CTRL | SHIFT), clip));
		assert atBottomOf(t);
		assert !handled(c.keyDown(t, key("ArrowUp", 0), clip));
		assert !handled(c.keyDown(t, key("PageUp", 0), clip));
		assert sink.sent == "";
	}).ok;
}

test "the copy chord, and enter on windows, copy the selection to the clipboard and dismiss it" {
	assert onTerm("alpha beta\r\ngamma", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const board = boardOf("");
		const clip = clipOf(board);
		assert !handled(c.keyDown(t, key("KeyC", CLIPBOARD_MODS), clip));
		assert board.copied == "";
		assert drag(c, t, clip, at(0, 0), at(4, 0));
		assert c.pointer.selected();
		assert handled(c.keyDown(t, key("KeyC", CLIPBOARD_MODS), clip));
		assert board.copied == "alpha";
		assert !c.pointer.selected();
		assert !handled(c.keyDown(t, key("KeyC", CLIPBOARD_MODS), clip));
		when (windows) {
			assert !handled(c.keyDown(t, key("Enter", 0), clip));
			assert drag(c, t, clip, at(6, 0), at(9, 0));
			assert handled(c.keyDown(t, key("Enter", 0), clip));
			assert board.copied == "beta";
		}
		when (!macos) {
			assert drag(c, t, clip, at(0, 1), at(4, 1));
			assert handled(c.keyDown(t, key("Insert", CTRL), clip));
			assert board.copied == "gamma";
		}
	}).ok;
}

test "paste sends the clipboard through the terminal's paste encoding" {
	assert onTerm("ready", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const board = boardOf("echo hi\r\n");
		const clip = clipOf(board);
		assert handled(c.keyDown(t, key("KeyV", CLIPBOARD_MODS), clip));
		assert board.reads == 1;
		assert sink.sent == "echo hi";
		when (!macos) {
			assert handled(c.keyDown(t, key("Insert", SHIFT), clip));
			assert sink.sent == "echo hiecho hi";
		}
		const reads = board.reads;
		assert !handled(c.keyDown(t, key("KeyV", CTRL), clip));
		assert board.reads == reads;
	}).ok;
}

test "a paste with a line break waits for an answer and sends nothing meanwhile" {
	assert onTerm("ready", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = clipOf(boardOf("one\r\ntwo"));
		assert handled(c.keyDown(t, key("KeyV", CLIPBOARD_MODS), clip));
		assert c.holding();
		const held = c.held;
		assert held !== null;
		if (held !== null) {
			assert held.warning == Warning.MultiLine;
			assert held.text == "one\ntwo";
		}
		assert sink.sent == "";
		assert handled(c.keyDown(t, key("KeyA", 0), clip));
		assert handled(c.keyDown(t, key("ArrowUp", CTRL | SHIFT), clip));
		assert handled(c.keyDown(t, key("KeyC", CLIPBOARD_MODS), clip));
		assert sink.sent == "";
		assert c.holding();
	}).ok;
}

test "enter confirms a held paste and it goes out through the paste encoding" {
	assert onTerm("ready", (a: Term, plain: Sink): void => {
		const c = Controls.open();
		const clip = clipOf(boardOf("one\r\ntwo"));
		assert handled(c.keyDown(a, key("KeyV", CLIPBOARD_MODS), clip));
		assert handled(c.keyDown(a, key("Enter", 0), clip));
		assert !c.holding();
		assert plain.sent == "one\rtwo";
	}).ok;
	assert onTerm("ready", (b: Term, chord: Sink): void => {
		const c = Controls.open();
		const clip = clipOf(boardOf("one\r\ntwo"));
		assert handled(c.keyDown(b, key("KeyV", CLIPBOARD_MODS), clip));
		assert handled(c.keyDown(b, key("KeyV", CLIPBOARD_MODS), clip));
		assert chord.sent == "one\rtwo";
	}).ok;
}

test "escape drops a held paste and the next key reaches the shell again" {
	assert onTerm("ready", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = clipOf(boardOf("one\r\ntwo"));
		assert handled(c.keyDown(t, key("KeyV", CLIPBOARD_MODS), clip));
		assert handled(c.keyDown(t, key("Escape", 0), clip));
		assert !c.holding();
		assert sink.sent == "";
		assert !handled(c.keyDown(t, key("KeyA", 0), clip));
	}).ok;
}

test "ctrl alt up and down move the viewport between prompts the shell marked" {
	const marked = "\x1b]133;A\x07p1\r\nout1\r\nout2\r\n" +
		"\x1b]133;A\x07p2\r\nout3\r\n\x1b]133;A\x07p3";
	assert onTerm(marked, (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = clipOf(boardOf(""));
		const bottom = offsetOf(t);
		assert handled(c.keyDown(t, key("ArrowUp", CTRL | ALT), clip));
		assert offsetOf(t) < bottom;
		assert handled(c.keyDown(t, key("ArrowDown", CTRL | ALT), clip));
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
				action: BindAction.SendText,
				screen: Screen.Any,
			},
			{
				code: "KeyC",
				mods: CTRL | SHIFT,
				text: "c",
				action: BindAction.SendText,
				screen: Screen.Any,
			},
		];
		const clip = clipOf(boardOf(""));
		assert handled(c.keyDown(t, key("PageUp", CTRL | SHIFT), clip));
		assert handled(c.keyDown(t, key("Enter", SHIFT), clip));
		assert sink.sent == "\x1b[13;2u";
		assert atBottomOf(t);
		assert handled(c.keyDown(t, key("KeyC", CTRL | SHIFT), clip));
		assert sink.sent == "\x1b[13;2uc";
		assert !handled(c.keyDown(t, key("Enter", CTRL), clip));
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
				action: BindAction.SendText,
				screen: Screen.Any,
			},
		];
		const clip = clipOf(boardOf(""));
		const altGr = key("KeyQ", CTRL | ALT);
		altGr.consumedMods = CTRL | ALT;
		altGr.text = "@";
		assert !handled(c.keyDown(t, altGr, clip));
		assert sink.sent == "";
		assert handled(c.keyDown(t, key("KeyQ", CTRL | ALT), clip));
		assert sink.sent == "x";
	}).ok;
}

function released(code: string, unshifted: int32): NeonEvent {
	const up = key(code, 0);
	up.type = "keyup";
	up.unshifted = unshifted;
	return up;
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
		const a = key("KeyA", 0);
		a.unshifted = 0x61;
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
		const clip = clipOf(boardOf(""));
		assert handled(c.keyDown(t, key("PageUp", CTRL | SHIFT), clip));
		assert c.keyUp(released("PageUp", 0));
		assert !c.keyUp(released("KeyA", 0x61));
		assert !handled(c.keyDown(t, key("KeyA", 0), clip));
		assert !c.keyUp(released("PageUp", 0));
	}).ok;
}

test "a keypad digit without NumLock is its navigation key on Windows, which alone reports NumLock" {
	assert onTerm("ready", (t: Term, sink: Sink): void => {
		assert t.sendKey(key("Numpad8", 0)).ok;
		when (windows) {
			assert sink.sent == "\x1b[A";
		} else {
			assert sink.sent == "8";
		}
		sink.sent = "";
		const locked = key("Numpad8", NUM_LOCK);
		locked.text = "8";
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
	assert onTerm("$ ", (shell: Term, atShell: Sink): void => {
		assert onTerm("\x1b[?1049h", (app: Term, inApp: Sink): void => {
			const c = Controls.open();
			c.keybinds = binds;
			const board = boardOf("");
			const clip = clipOf(board);
			assert handled(c.keyDown(app, key("KeyW", SUPER), clip));
			assert inApp.sent == "\x1b[119;9u";
			assert board.closed == 0;
			assert handled(c.keyDown(shell, key("KeyW", SUPER), clip));
			assert atShell.sent == "";
			assert board.closed == 1;
		}).ok;
	}).ok;
}

test "closing while a program runs asks first: escape keeps the window and enter closes it" {
	assert onTerm("$ ", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const board = boardOf("");
		const clip = clipOf(board);
		sink.busy = true;
		assert handled(c.closeKey(t, clip));
		assert c.closing;
		assert c.holding();
		assert board.closed == 0;
		assert handled(c.keyDown(t, key("KeyX", 0), clip));
		assert handled(c.keyDown(t, key("Escape", 0), clip));
		assert !c.closing;
		assert board.closed == 0;
		assert sink.sent == "";
		assert handled(c.closeKey(t, clip));
		assert handled(c.keyDown(t, key("Enter", 0), clip));
		assert !c.closing;
		assert board.closed == 1;
		sink.busy = false;
		assert handled(c.closeKey(t, clip));
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
			action: BindAction.CloseWindow,
			screen: Screen.Any,
		},
	];
	assert onTerm("$ ", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		c.keybinds = binds;
		const board = boardOf("");
		const clip = clipOf(board);
		sink.busy = true;
		assert handled(c.keyDown(t, key("KeyW", SUPER), clip));
		assert c.closing;
		assert board.closed == 0;
		assert handled(c.keyDown(t, key("Enter", 0), clip));
		assert board.closed == 1;
	}).ok;
}

test "close window from the menu runs a super w keybind for this screen and otherwise closes" {
	const binds: Vec<Keybind> = [
		{
			code: "KeyW",
			mods: SUPER,
			text: "\x1b[119;9u",
			action: BindAction.SendText,
			screen: Screen.Alternate,
		},
	];
	assert onTerm("$ ", (shell: Term, atShell: Sink): void => {
		assert onTerm("\x1b[?1049h", (app: Term, inApp: Sink): void => {
			const c = Controls.open();
			c.keybinds = binds;
			const board = boardOf("");
			const clip = clipOf(board);
			assert handled(c.closeKey(app, clip));
			assert inApp.sent == "\x1b[119;9u";
			assert board.closed == 0;
			assert handled(c.closeKey(shell, clip));
			assert atShell.sent == "";
			assert board.closed == 1;
			c.keybinds = [];
			assert handled(c.closeKey(app, clip));
			assert inApp.sent == "\x1b[119;9u";
			assert board.closed == 2;
		}).ok;
	}).ok;
}
