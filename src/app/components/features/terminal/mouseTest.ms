import { selected } from "../../../../input/pointer";
import { bounds } from "../../../../select/select";
import { releaseHeldKey, sendKey, shutdown } from "./term";
import { Sink, termOf } from "./termTest";
import { Controls, Hit } from "./controls";
import { keyDown } from "./keyboard";
import { autoscrollTick, focusLost, pointerDown, pointerMove, pointerUp, roll, shades } from "./mouse";
import { CLIPBOARD_MODS, CTRL } from "../../../../input/bindings";
import {
	at,
	boardOf,
	clipOf,
	drag,
	handled,
	hitAt,
	hitWith,
	key,
	lines,
	offsetOf,
} from "./controlsTest";

test "while a paste is held the wheel, the buttons and the pointer do nothing" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30), 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("a\nb"));
		const bottom = offsetOf(t);
		assert handled(c.keyDown(t, key("KeyV", CLIPBOARD_MODS), clip));
		assert !handled(c.roll(t, 1, hitAt(0, 0)));
		assert offsetOf(t) == bottom;
		assert !handled(c.pointerDown(t, clip, 1, hitAt(0, 0), 0));
		assert !c.pointer.dragging;
		assert !handled(c.pointerDown(t, clip, 2, hitAt(0, 0), 0));
		assert clip.write !== null;
		t.shutdown();
	}
}

test "wheel arrows on the alternate screen tap each key and leave the held key to be released" {
	const ctrlSink: Sink = { sent: "" };
	const ctrl = termOf("\x1b[?1049h\x1b[>11u", 20, 5, ctrlSink);
	assert ctrl !== null;
	if (ctrl !== null) {
		const c = Controls.open();
		assert ctrl.sendKey(key("ControlLeft", CTRL)).ok;
		ctrlSink.sent = "";
		assert c.roll(ctrl, 1, hitAt(0, 0)).ok;
		assert ctrlSink.sent == "\x1b[1;1:1A\x1b[1;1:3A\x1b[1;1:1A\x1b[1;1:3A\x1b[1;1:1A\x1b[1;1:3A";
		ctrlSink.sent = "";
		assert ctrl.releaseHeldKey().ok;
		assert ctrlSink.sent == "\x1b[57442;5:3u\x1b[57448;1:3u";
		ctrl.shutdown();
	}
	const letterSink: Sink = { sent: "" };
	const letter = termOf("\x1b[?1049h\x1b[>3u", 20, 5, letterSink);
	assert letter !== null;
	if (letter !== null) {
		const c = Controls.open();
		const a = key("KeyA", 0);
		a.text = "a";
		a.unshifted = 0x61;
		assert letter.sendKey(a).ok;
		assert c.roll(letter, -1, hitAt(0, 0)).ok;
		letterSink.sent = "";
		assert letter.releaseHeldKey().ok;
		assert letterSink.sent == "\x1b[97;1:3u";
		letter.shutdown();
	}
}

test "the wheel scrolls three rows a notch on the primary screen and accumulates fractions" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30), 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const bottom = offsetOf(t);
		assert handled(c.roll(t, 1, hitAt(0, 0)));
		assert offsetOf(t) == bottom - 3;
		assert handled(c.roll(t, 2, hitAt(0, 0)));
		assert offsetOf(t) == bottom - 9;
		assert handled(c.roll(t, -1, hitAt(0, 0)));
		assert offsetOf(t) == bottom - 6;
		assert !handled(c.roll(t, 0.25, hitAt(0, 0)));
		assert handled(c.roll(t, 0.25, hitAt(0, 0)));
		assert offsetOf(t) == bottom - 7;
		assert sink.sent == "";
		t.shutdown();
	}
}

test "on the alternate screen the wheel is arrow keys, in the cursor key mode the program set" {
	const normal: Sink = { sent: "" };
	const a = termOf("\x1b[?1049h", 20, 5, normal);
	assert a !== null;
	if (a !== null) {
		const c = Controls.open();
		assert !handled(c.roll(a, 1, hitAt(0, 0)));
		assert normal.sent == "\x1b[A\x1b[A\x1b[A";
		assert !handled(c.roll(a, -1, hitAt(0, 0)));
		assert normal.sent == "\x1b[A\x1b[A\x1b[A\x1b[B\x1b[B\x1b[B";
		a.shutdown();
	}
	const app: Sink = { sent: "" };
	const b = termOf("\x1b[?1049h\x1b[?1h", 20, 5, app);
	assert b !== null;
	if (b !== null) {
		const c = Controls.open();
		assert !handled(c.roll(b, 1, hitAt(0, 0)));
		assert app.sent == "\x1bOA\x1bOA\x1bOA";
		b.shutdown();
	}
	const off: Sink = { sent: "" };
	const d = termOf("\x1b[?1049h\x1b[?1007l", 20, 5, off);
	assert d !== null;
	if (d !== null) {
		const c = Controls.open();
		assert c.roll(d, 1, hitAt(0, 0)).ok;
		assert off.sent == "";
		d.shutdown();
	}
}

test "an app that tracks the mouse gets presses, releases and wheel notches as its own reports" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30) + "\x1b[?1000h\x1b[?1006h", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("x"));
		const bottom = offsetOf(t);
		assert handled(c.pointerDown(t, clip, 1, hitAt(2, 1), 0));
		assert !c.pointer.dragging;
		assert sink.sent == "\x1b[<0;3;2M";
		assert handled(c.pointerUp(t, 1, hitAt(2, 1)));
		assert sink.sent == "\x1b[<0;3;2M\x1b[<0;3;2m";
		assert !handled(c.roll(t, 1, hitAt(0, 0)));
		assert offsetOf(t) == bottom;
		assert sink.sent == "\x1b[<0;3;2M\x1b[<0;3;2m\x1b[<64;1;1M\x1b[<64;1;1M\x1b[<64;1;1M";
		assert !handled(c.pointerUp(t, 1, hitAt(0, 0)));
		t.shutdown();
	}
}

test "motion is reported only in the modes that ask for it, and the held button rides along" {
	const sink: Sink = { sent: "" };
	const t = termOf("\x1b[?1002h\x1b[?1006h", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("x"));
		assert !handled(c.pointerMove(t, hitAt(1, 1), false));
		assert sink.sent == "";
		assert handled(c.pointerDown(t, clip, 1, hitAt(1, 1), 0));
		assert !handled(c.pointerMove(t, hitAt(4, 1), true));
		assert sink.sent == "\x1b[<0;2;2M\x1b[<32;5;2M";
		t.shutdown();
	}
}

test "shift hands the mouse back from an app that tracks it, and a wheel reported to the app drops the selection" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30) + "\x1b[?1000h\x1b[?1006h", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("x"));
		const bottom = offsetOf(t);
		assert handled(c.pointerDown(t, clip, 1, hitWith(0, 1, 1), 0));
		assert c.pointer.dragging;
		assert handled(c.pointerMove(t, hitWith(5, 1, 1), true));
		assert c.pointer.selected();
		assert sink.sent == "";
		assert handled(c.roll(t, 1, hitWith(0, 0, 1)));
		assert offsetOf(t) == bottom - 3;
		assert c.pointer.selected();
		assert handled(c.roll(t, 1, hitAt(0, 0)));
		assert !c.pointer.selected();
		assert sink.sent == "[<64;1;1M[<64;1;1M[<64;1;1M";
		t.shutdown();
	}
}

test "a ctrl click on an http link opens it, on any other link or text it does not" {
	const sink: Sink = { sent: "" };
	const text = "\x1b]8;;https://example.com/a\x07link\x1b]8;;\x07 " +
		"\x1b]8;;file:///c:/x.exe\x07bad\x1b]8;;\x07 plain";
	const t = termOf(text, 30, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const board = boardOf("");
		const clip = clipOf(board);
		assert handled(c.pointerDown(t, clip, 1, hitWith(1, 0, 2), 0));
		assert board.opened == "https://example.com/a";
		board.opened = "";
		assert handled(c.pointerDown(t, clip, 1, hitWith(6, 0, 2), 0));
		assert board.opened == "";
		assert handled(c.pointerDown(t, clip, 1, hitWith(12, 0, 2), 10000));
		assert board.opened == "";
		assert handled(c.pointerDown(t, clip, 1, hitWith(1, 0, 0), 20000));
		assert board.opened == "";
		t.shutdown();
	}
}

test "a right click copies a selection and otherwise pastes" {
	const sink: Sink = { sent: "" };
	const t = termOf("alpha beta", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const board = boardOf("pasted");
		const clip = clipOf(board);
		assert !handled(c.pointerDown(t, clip, 2, hitAt(0, 0), 0));
		assert sink.sent == "pasted";
		assert drag(c, t, clip, at(0, 0), at(4, 0));
		assert handled(c.pointerDown(t, clip, 2, hitAt(0, 0), 1000));
		assert board.copied == "alpha";
		assert sink.sent == "pasted";
		assert !c.pointer.selected();
		t.shutdown();
	}
}

test "a move that finds the button released ends the drag, and a wheel while dragging extends it" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30), 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf(""));
		assert c.pointerDown(t, clip, 1, hitAt(0, 4), 0).ok;
		assert handled(c.pointerMove(t, hitAt(3, 4), true));
		assert handled(c.roll(t, 1, hitAt(0, 0)));
		const kept = c.pointer.sel;
		assert kept !== null;
		if (kept !== null) { assert kept.bounds().start.row < kept.bounds().end.row; }
		assert !handled(c.pointerMove(t, hitAt(5, 4), false));
		assert !c.pointer.dragging;
		t.shutdown();
	}
}

test "the shades are the highlight rectangles of the viewport" {
	const sink: Sink = { sent: "" };
	const t = termOf("alpha beta\r\ngamma", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf(""));
		const none = c.shades(t);
		assert none.ok;
		if (none.ok) { assert none.value.length == 0; }
		assert drag(c, t, clip, at(2, 0), at(3, 1));
		const drawn = c.shades(t);
		assert drawn.ok;
		if (drawn.ok) {
			assert drawn.value.length == 2;
			assert drawn.value[0].row == 0 && drawn.value[0].col == 2 && drawn.value[0].cols == 18;
			assert drawn.value[1].row == 1 && drawn.value[1].col == 0 && drawn.value[1].cols == 4;
		}
		t.shutdown();
	}
}

test "a drag held past the top edge scrolls back a row per tick, and the release stops it" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30), 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf(""));
		const bottom = offsetOf(t);
		assert c.pointerDown(t, clip, 1, hitAt(3, 2), 0).ok;
		const above: Hit = { ...hitAt(3, 0), y: -12 };
		assert c.pointerMove(t, above, true).ok;
		assert c.autoscroll == -1;
		assert handled(c.autoscrollTick(t));
		assert handled(c.autoscrollTick(t));
		assert offsetOf(t) == bottom - 2;
		const kept = c.pointer.sel;
		assert kept !== null;
		if (kept !== null) { assert kept.bounds().start.row == bottom - 2; }
		assert c.pointerUp(t, 1, above).ok;
		assert !handled(c.autoscrollTick(t));
		assert offsetOf(t) == bottom - 2;
		t.shutdown();
	}
}

test "losing focus mid-drag ends the drag and its scrolling, and keeps the selection" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30), 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf(""));
		const bottom = offsetOf(t);
		assert c.pointerDown(t, clip, 1, hitAt(3, 2), 0).ok;
		const above: Hit = { ...hitAt(3, 0), y: -12 };
		assert c.pointerMove(t, above, true).ok;
		c.focusLost();
		assert !handled(c.autoscrollTick(t));
		assert offsetOf(t) == bottom;
		assert !c.pointer.dragging;
		assert c.pointer.selected();
		t.shutdown();
	}
}

test "a press in the padding reaches a tracking app as the nearest cell" {
	const sink: Sink = { sent: "" };
	const t = termOf("[?1000h[?1006h", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf(""));
		const base = hitAt(0, 0);
		const padded: Hit = {
			...base,
			x: -6,
			y: -6,
			cell: { ...base.cell, width: 180, height: 100, padLeft: 10, padTop: 10, padRight: 10, padBottom: 10 },
		};
		assert handled(c.pointerDown(t, clip, 1, padded, 0));
		assert sink.sent == "[<0;1;1M";
		t.shutdown();
	}
}
