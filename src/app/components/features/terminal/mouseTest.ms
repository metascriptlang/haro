import { selected } from "../../../../input/pointer";
import { View, fitRows, open, paint } from "../../../frame";
import { bounds } from "../../../../select/select";
import { Term, pumpFrame, releaseHeldKey, sendKey } from "./term";
import { Controls, Hit } from "./controls";
import { keyDown } from "./keyboard";
import {
	autoscrollTick,
	endDrag,
	pointerDown,
	pointerMove,
	pointerUp,
	roll,
	syncSelection,
} from "./mouse";
import { CLIPBOARD_MODS, CTRL, SHIFT } from "../../../../input/bindings";
import {
	Sink,
	at,
	boardOf,
	settled,
	drag,
	handled,
	hitAt,
	hitWith,
	key,
	lines,
	offsetOf,
	onTerm,
} from "./terminalRig";

test "while a paste is held the wheel, the buttons and the pointer do nothing" {
	assert onTerm(lines(30), (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("a\nb");
		const bottom = offsetOf(t);
		assert handled(settled(clip, c, t, c.keyDown(t, key("KeyV", CLIPBOARD_MODS))));
		assert !handled(c.roll(t, 1, hitAt(0, 0)));
		assert offsetOf(t) == bottom;
		assert !handled(settled(clip, c, t, c.pointerDown(t, 1, hitAt(0, 0), 0)));
		assert !c.pointer.dragging;
		assert !handled(settled(clip, c, t, c.pointerDown(t, 2, hitAt(0, 0), 0)));
		assert clip.reads == 1 && clip.copied == "";
	}).ok;
}

test "wheel arrows on the alternate screen tap each key and leave the held key to be released" {
	assert onTerm("\x1b[?1049h\x1b[>11u", (ctrl: Term, ctrlSink: Sink): void => {
		const c = Controls.open();
		assert ctrl.sendKey(key("ControlLeft", CTRL)).ok;
		ctrlSink.sent = "";
		assert c.roll(ctrl, 1, hitAt(0, 0)).ok;
		assert ctrlSink.sent == "\x1b[1;1:1A\x1b[1;1:3A\x1b[1;1:1A\x1b[1;1:3A\x1b[1;1:1A\x1b[1;1:3A";
		ctrlSink.sent = "";
		assert ctrl.releaseHeldKey().ok;
		assert ctrlSink.sent == "\x1b[57442;5:3u\x1b[57448;1:3u";
	}).ok;
	assert onTerm("\x1b[?1049h\x1b[>3u", (letter: Term, letterSink: Sink): void => {
		const c = Controls.open();
		const a = key("KeyA", 0);
		a.text = "a";
		a.unshifted = 0x61;
		assert letter.sendKey(a).ok;
		assert c.roll(letter, -1, hitAt(0, 0)).ok;
		letterSink.sent = "";
		assert letter.releaseHeldKey().ok;
		assert letterSink.sent == "\x1b[97;1:3u";
	}).ok;
}

test "the wheel scrolls three rows a notch on the primary screen and accumulates fractions" {
	assert onTerm(lines(30), (t: Term, sink: Sink): void => {
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
	}).ok;
}

test "on the alternate screen the wheel is arrow keys, in the cursor key mode the program set" {
	assert onTerm("\x1b[?1049h", (a: Term, normal: Sink): void => {
		const c = Controls.open();
		assert !handled(c.roll(a, 1, hitAt(0, 0)));
		assert normal.sent == "\x1b[A\x1b[A\x1b[A";
		assert !handled(c.roll(a, -1, hitAt(0, 0)));
		assert normal.sent == "\x1b[A\x1b[A\x1b[A\x1b[B\x1b[B\x1b[B";
	}).ok;
	assert onTerm("\x1b[?1049h\x1b[?1h", (b: Term, app: Sink): void => {
		const c = Controls.open();
		assert !handled(c.roll(b, 1, hitAt(0, 0)));
		assert app.sent == "\x1bOA\x1bOA\x1bOA";
	}).ok;
	assert onTerm("\x1b[?1049h\x1b[?1007l", (d: Term, off: Sink): void => {
		const c = Controls.open();
		assert c.roll(d, 1, hitAt(0, 0)).ok;
		assert off.sent == "";
	}).ok;
}

test "an app that tracks the mouse gets presses, releases and wheel notches as its own reports" {
	assert onTerm(lines(30) + "\x1b[?1000h\x1b[?1006h", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("x");
		const bottom = offsetOf(t);
		assert handled(settled(clip, c, t, c.pointerDown(t, 1, hitAt(2, 1), 0)));
		assert !c.pointer.dragging;
		assert sink.sent == "\x1b[<0;3;2M";
		assert handled(c.pointerUp(t, 1, hitAt(2, 1)));
		assert sink.sent == "\x1b[<0;3;2M\x1b[<0;3;2m";
		assert !handled(c.roll(t, 1, hitAt(0, 0)));
		assert offsetOf(t) == bottom;
		assert sink.sent == "\x1b[<0;3;2M\x1b[<0;3;2m\x1b[<64;1;1M\x1b[<64;1;1M\x1b[<64;1;1M";
		assert !handled(c.pointerUp(t, 1, hitAt(0, 0)));
	}).ok;
}

test "motion is reported only in the modes that ask for it, and the held button rides along" {
	assert onTerm("\x1b[?1002h\x1b[?1006h", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("x");
		assert !handled(c.pointerMove(t, hitAt(1, 1), false));
		assert sink.sent == "";
		assert handled(settled(clip, c, t, c.pointerDown(t, 1, hitAt(1, 1), 0)));
		assert !handled(c.pointerMove(t, hitAt(4, 1), true));
		assert sink.sent == "\x1b[<0;2;2M\x1b[<32;5;2M";
	}).ok;
}

test "shift hands the mouse back from an app that tracks it, and a wheel reported to the app drops the selection" {
	assert onTerm(lines(30) + "\x1b[?1000h\x1b[?1006h", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("x");
		const bottom = offsetOf(t);
		assert handled(settled(clip, c, t, c.pointerDown(t, 1, hitWith(0, 1, SHIFT), 0)));
		assert c.pointer.dragging;
		assert handled(c.pointerMove(t, hitWith(5, 1, SHIFT), true));
		assert c.pointer.selected();
		assert sink.sent == "";
		assert handled(c.roll(t, 1, hitWith(0, 0, SHIFT)));
		assert offsetOf(t) == bottom - 3;
		assert c.pointer.selected();
		assert handled(c.roll(t, 1, hitAt(0, 0)));
		assert !c.pointer.selected();
		assert sink.sent == "\x1b[<64;1;1M\x1b[<64;1;1M\x1b[<64;1;1M";
	}).ok;
}

test "a ctrl click on an http link opens it, on a link to a program or on text it does not" {
	const text = "\x1b]8;;https://example.com/a\x07link\x1b]8;;\x07 " +
		"\x1b]8;;file:///c:/x.exe\x07bad\x1b]8;;\x07 plain";
	assert onTerm(text, (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const board = boardOf("");
		const clip = board;
		assert handled(settled(clip, c, t, c.pointerDown(t, 1, hitWith(1, 0, CTRL), 0)));
		assert board.opened == "https://example.com/a";
		board.opened = "";
		assert handled(settled(clip, c, t, c.pointerDown(t, 1, hitWith(6, 0, CTRL), 0)));
		assert board.opened == "";
		assert handled(settled(clip, c, t, c.pointerDown(t, 1, hitWith(12, 0, CTRL), 10000)));
		assert board.opened == "";
		assert handled(settled(clip, c, t, c.pointerDown(t, 1, hitWith(1, 0, 0), 20000)));
		assert board.opened == "";
	}, 30, 5).ok;
}

test "a right click copies a selection and otherwise pastes" {
	assert onTerm("alpha beta", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const board = boardOf("pasted");
		const clip = board;
		assert !handled(settled(clip, c, t, c.pointerDown(t, 2, hitAt(0, 0), 0)));
		assert sink.sent == "pasted";
		assert drag(c, t, clip, at(0, 0), at(4, 0));
		assert handled(settled(clip, c, t, c.pointerDown(t, 2, hitAt(0, 0), 1000)));
		assert board.copied == "alpha";
		assert sink.sent == "pasted";
		assert !c.pointer.selected();
	}).ok;
}

test "a move that finds the button released ends the drag, and a wheel while dragging extends it" {
	assert onTerm(lines(30), (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("");
		assert settled(clip, c, t, c.pointerDown(t, 1, hitAt(0, 4), 0)).ok;
		assert handled(c.pointerMove(t, hitAt(3, 4), true));
		assert handled(c.roll(t, 1, hitAt(0, 0)));
		const kept = c.pointer.sel;
		assert kept !== null;
		if (kept !== null) { assert kept.bounds().start.row < kept.bounds().end.row; }
		assert !handled(c.pointerMove(t, hitAt(5, 4), false));
		assert !c.pointer.dragging;
	}).ok;
}

test "a drag selects cells that the next frame draws with their colours swapped" {
	assert onTerm("alpha beta\r\ngamma", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("");
		assert drag(c, t, clip, at(2, 0), at(3, 1));
		const view = View.open();
		view.fitRows(t.shown.length as int32);
		const frame = t.pumpFrame();
		assert frame.ok;
		if (frame.ok) {
			const rows = frame.value.rows;
			if (rows !== null) { view.paint(rows); }
		}
		const top = view.grid.at(0).line;
		assert top.runs.length == 2;
		assert top.runs[1].units == 18;
		assert top.runs[1].bg == top.runs[0].fg;
		const bottom = view.grid.at(1).line;
		assert bottom.runs[0].units == 4;
		assert bottom.runs[0].bg == bottom.runs[1].fg;
		const dropped = c.syncSelection(t);
		assert dropped.ok;
		if (dropped.ok) { assert !dropped.value; }
	}).ok;
}

test "a drag held past the top edge scrolls back a row per tick, and the release stops it" {
	assert onTerm(lines(30), (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("");
		const bottom = offsetOf(t);
		assert settled(clip, c, t, c.pointerDown(t, 1, hitAt(3, 2), 0)).ok;
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
	}).ok;
}

test "losing focus mid-drag ends the drag and its scrolling, and keeps the selection" {
	assert onTerm(lines(30), (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("");
		const bottom = offsetOf(t);
		assert settled(clip, c, t, c.pointerDown(t, 1, hitAt(3, 2), 0)).ok;
		const above: Hit = { ...hitAt(3, 0), y: -12 };
		assert c.pointerMove(t, above, true).ok;
		c.endDrag();
		assert !handled(c.autoscrollTick(t));
		assert offsetOf(t) == bottom;
		assert !c.pointer.dragging;
		assert c.pointer.selected();
	}).ok;
}

test "a press in the padding reaches a tracking app as the nearest cell" {
	assert onTerm("\x1b[?1000h\x1b[?1006h", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("");
		const base = hitAt(0, 0);
		const padded: Hit = {
			...base,
			x: -6,
			y: -6,
			cell: { ...base.cell, width: 180, height: 100, padLeft: 10, padTop: 10, padRight: 10, padBottom: 10 },
		};
		assert handled(settled(clip, c, t, c.pointerDown(t, 1, padded, 0)));
		assert sink.sent == "\x1b[<0;1;1M";
	}).ok;
}
