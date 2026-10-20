import { selected } from "../../../../input/pointer";
import { shutdown } from "./term";
import { Sink, termOf } from "./termTest";
import { Controls } from "./controls";
import { closeKey, keyDown } from "./keyboard";
import { Warning } from "../../../../input/paste";
import { BindAction, CLIPBOARD_MODS, Keybind, Screen } from "../../../../input/bindings";
import {
	CTRL,
	SHIFT,
	SUPER,
	at,
	atBottomOf,
	boardOf,
	clipOf,
	drag,
	handled,
	key,
	lines,
	offsetOf,
} from "./controlsTest";

test "ctrl shift page, arrow, home and end keys move the viewport and say they did" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30), 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf(""));
		const bottom = offsetOf(t);
		assert bottom > 0;
		assert atBottomOf(t);
		assert handled(c.keyDown(t, key("PageUp", 3), clip));
		assert offsetOf(t) == bottom - 5;
		assert handled(c.keyDown(t, key("ArrowUp", 3), clip));
		assert offsetOf(t) == bottom - 8;
		assert handled(c.keyDown(t, key("ArrowDown", 3), clip));
		assert offsetOf(t) == bottom - 5;
		assert handled(c.keyDown(t, key("Home", 3), clip));
		assert offsetOf(t) == 0;
		assert handled(c.keyDown(t, key("PageDown", 3), clip));
		assert offsetOf(t) == 5;
		assert handled(c.keyDown(t, key("End", 3), clip));
		assert atBottomOf(t);
		assert !handled(c.keyDown(t, key("ArrowUp", 0), clip));
		assert !handled(c.keyDown(t, key("PageUp", 0), clip));
		assert sink.sent == "";
		t.shutdown();
	}
}

test "the copy chord and enter alike copy the selection to the clipboard and dismiss it" {
	const sink: Sink = { sent: "" };
	const t = termOf("alpha beta\r\ngamma", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const board = boardOf("");
		const clip = clipOf(board);
		assert !handled(c.keyDown(t, key("KeyC", CLIPBOARD_MODS), clip));
		assert !handled(c.keyDown(t, key("Enter", 0), clip));
		assert board.copied == "";
		assert drag(c, t, clip, at(0, 0), at(4, 0));
		assert c.pointer.selected();
		assert handled(c.keyDown(t, key("KeyC", CLIPBOARD_MODS), clip));
		assert board.copied == "alpha";
		assert !c.pointer.selected();
		assert !handled(c.keyDown(t, key("KeyC", CLIPBOARD_MODS), clip));
		assert drag(c, t, clip, at(6, 0), at(9, 0));
		assert handled(c.keyDown(t, key("Enter", 0), clip));
		assert board.copied == "beta";
		when (!macos) {
			assert drag(c, t, clip, at(0, 1), at(4, 1));
			assert handled(c.keyDown(t, key("Insert", 2), clip));
			assert board.copied == "gamma";
		}
		t.shutdown();
	}
}

test "paste sends the clipboard through the terminal's paste encoding" {
	const sink: Sink = { sent: "" };
	const t = termOf("ready", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const board = boardOf("echo hi\r\n");
		const clip = clipOf(board);
		assert handled(c.keyDown(t, key("KeyV", CLIPBOARD_MODS), clip));
		assert board.reads == 1;
		assert sink.sent == "echo hi";
		when (!macos) {
			assert handled(c.keyDown(t, key("Insert", 1), clip));
			assert sink.sent == "echo hiecho hi";
		}
		const reads = board.reads;
		assert !handled(c.keyDown(t, key("KeyV", 2), clip));
		assert board.reads == reads;
		t.shutdown();
	}
}

test "a paste with a line break waits for an answer and sends nothing meanwhile" {
	const sink: Sink = { sent: "" };
	const t = termOf("ready", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
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
		assert handled(c.keyDown(t, key("ArrowUp", 3), clip));
		assert handled(c.keyDown(t, key("KeyC", CLIPBOARD_MODS), clip));
		assert sink.sent == "";
		assert c.holding();
		t.shutdown();
	}
}

test "enter confirms a held paste and it goes out through the paste encoding" {
	const plain: Sink = { sent: "" };
	const a = termOf("ready", 20, 5, plain);
	assert a !== null;
	if (a !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("one\r\ntwo"));
		assert handled(c.keyDown(a, key("KeyV", CLIPBOARD_MODS), clip));
		assert handled(c.keyDown(a, key("Enter", 0), clip));
		assert !c.holding();
		assert plain.sent == "one\rtwo";
		a.shutdown();
	}
	const chord: Sink = { sent: "" };
	const b = termOf("ready", 20, 5, chord);
	assert b !== null;
	if (b !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("one\r\ntwo"));
		assert handled(c.keyDown(b, key("KeyV", CLIPBOARD_MODS), clip));
		assert handled(c.keyDown(b, key("KeyV", CLIPBOARD_MODS), clip));
		assert chord.sent == "one\rtwo";
		b.shutdown();
	}
}

test "escape drops a held paste and the next key reaches the shell again" {
	const sink: Sink = { sent: "" };
	const t = termOf("ready", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("one\r\ntwo"));
		assert handled(c.keyDown(t, key("KeyV", CLIPBOARD_MODS), clip));
		assert handled(c.keyDown(t, key("Escape", 0), clip));
		assert !c.holding();
		assert sink.sent == "";
		assert !handled(c.keyDown(t, key("KeyA", 0), clip));
		t.shutdown();
	}
}

test "ctrl alt up and down move the viewport between prompts the shell marked" {
	const sink: Sink = { sent: "" };
	const marked = "\x1b]133;A\x07p1\r\nout1\r\nout2\r\n" +
		"\x1b]133;A\x07p2\r\nout3\r\n\x1b]133;A\x07p3";
	const t = termOf(marked, 10, 3, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf(""));
		const bottom = offsetOf(t);
		assert handled(c.keyDown(t, key("ArrowUp", 6), clip));
		assert offsetOf(t) < bottom;
		assert handled(c.keyDown(t, key("ArrowDown", 6), clip));
		assert sink.sent == "";
		t.shutdown();
	}
}

test "a configured keybind sends its text, ahead of a built-in chord on the same keys" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30), 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		c.keybinds = [
			{
				code: "Enter",
				mods: SHIFT,
				text: "[13;2u",
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
		assert handled(c.keyDown(t, key("PageUp", 3), clip));
		assert handled(c.keyDown(t, key("Enter", 1), clip));
		assert sink.sent == "[13;2u";
		assert atBottomOf(t);
		assert handled(c.keyDown(t, key("KeyC", 3), clip));
		assert sink.sent == "[13;2uc";
		assert !handled(c.keyDown(t, key("Enter", 2), clip));
		t.shutdown();
	}
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
	const atShell: Sink = { sent: "" };
	const shell = termOf("$ ", 20, 5, atShell);
	const inApp: Sink = { sent: "" };
	const app = termOf("\x1b[?1049h", 20, 5, inApp);
	assert shell !== null && app !== null;
	if (shell !== null && app !== null) {
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
		shell.shutdown();
		app.shutdown();
	}
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
	const atShell: Sink = { sent: "" };
	const shell = termOf("$ ", 20, 5, atShell);
	const inApp: Sink = { sent: "" };
	const app = termOf("\x1b[?1049h", 20, 5, inApp);
	assert shell !== null && app !== null;
	if (shell !== null && app !== null) {
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
		shell.shutdown();
		app.shutdown();
	}
}
