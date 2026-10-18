import { Screen } from "./screen";

function open(cols: int32, rows: int32): Screen | null {
	const opened = Screen.open(cols, rows);
	if (!opened.ok) { return null; }
	return opened.value;
}

function colorAt(s: Screen, y: int32): string {
	const spans = s.spans(y);
	if (spans.length == 0 || spans[0].style === undefined) { return "<none>"; }
	const c = spans[0].style!.color;
	return c === null ? "<default>" : c;
}

test "an OSC 4 palette change repaints the cells that use the entry, OSC 104 puts it back" {
	const s = open(10, 3);
	assert s !== null;
	if (s !== null) {
		assert s.step("\x1b[31mr\x1b[0m\r\n\x1b[41m \x1b[0m");
		assert colorAt(s, 0) == "#cc6666";
		assert s.step("\x1b]4;1;rgb:00/ff/00\x07");
		assert colorAt(s, 0) == "#00ff00";
		assert s.spans(1)[0].style!.backgroundColor == "#00ff00";
		assert s.step("\x1b]104;1\x07");
		assert colorAt(s, 0) == "#cc6666";
		assert s.step("\x1b]4;1;rgb:12/34/56\x07\x1b]104\x07");
		assert colorAt(s, 0) == "#cc6666";
		s.close();
	}
}

test "a new default colour (OSC 10, OSC 11, DECSCNM) repaints rows already drawn" {
	const fg = open(10, 3);
	const bg = open(10, 3);
	const reverse = open(10, 3);
	assert fg !== null && bg !== null && reverse !== null;
	if (fg !== null && bg !== null && reverse !== null) {
		assert fg.step("abc\r\n");
		assert fg.feed("\x1b]10;rgb:ff/00/00\x07");
		assert colorAt(fg, 0) == "#ff0000";
		assert fg.mismatch() == "";
		assert bg.step("abc\x1b[44mb\x1b[0m");
		assert bg.feed("\x1b]11;rgb:10/10/10\x07");
		assert bg.mismatch() == "";
		assert bg.spans(0)[0].style!.backgroundColor === undefined;
		assert reverse.step("abc\r\n");
		assert reverse.feed("\x1b[?5h");
		assert reverse.mismatch() == "";
		fg.close();
		bg.close();
		reverse.close();
	}
}

function redAt(s: Screen, y: int32, unit: int32): boolean {
	let at = 0;
	for (const r of s.runs(y)) {
		if (unit < at + r.units) { return r.bg.r == 255 && r.bg.g == 0 && r.bg.b == 0; }
		at += r.units;
	}
	return false;
}

function red(s: Screen, y: int32, from: int32, units: int32): boolean {
	for (let u = from; u < from + units; u++) {
		if (!redAt(s, y, u)) { return false; }
	}
	return !redAt(s, y, from + units);
}

test "erasing, inserting and deleting fill the vacated cells with the current background" {
	const index = open(5, 5);
	const ech = open(10, 10);
	const ich = open(10, 10);
	const el = open(5, 5);
	const ed = open(5, 5);
	const dl = open(5, 5);
	const bg = "\x1b[48;2;255;0;0m";
	assert index !== null && ech !== null && ich !== null && el !== null && ed !== null && dl !== null;
	if (index !== null && ech !== null && ich !== null && el !== null && ed !== null && dl !== null) {
		assert index.step("\x1b[5;1HA" + bg + "\x1bD");
		assert index.lines() == "\n\n\nA\n";
		assert red(index, 4, 0, 5);
		assert ech.step("ABC\x1b[1;1H" + bg + "\x1b[2X");
		assert ech.text(0) == "  C" && red(ech, 0, 0, 2);
		assert ich.step("ABC\x1b[1;1H" + bg + "\x1b[2@");
		assert ich.text(0) == "  ABC" && red(ich, 0, 0, 2);
		assert el.step("ABCDE\x1b[1;2H" + bg + "\x1b[K");
		assert el.text(0) == "A" && red(el, 0, 1, 4);
		assert ed.step("ABC\r\nDEF\r\nGHI\x1b[2;2H" + bg + "\x1b[J");
		assert ed.lines() == "ABC\nD\n\n\n";
		assert red(ed, 1, 1, 4) && red(ed, 2, 0, 5) && red(ed, 4, 0, 5);
		assert dl.step("ABC\r\nDEF\r\nGHI\x1b[2;2H" + bg + "\x1b[M");
		assert dl.lines() == "ABC\nGHI\n\n\n";
		assert red(dl, 4, 0, 5);
		index.close();
		ech.close();
		ich.close();
		el.close();
		ed.close();
		dl.close();
	}
}
