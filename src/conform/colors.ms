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

test "known bug: a new default colour (OSC 10, OSC 11, DECSCNM) does not repaint rows already drawn" {
	const fg = open(10, 3);
	const bg = open(10, 3);
	const reverse = open(10, 3);
	assert fg !== null && bg !== null && reverse !== null;
	if (fg !== null && bg !== null && reverse !== null) {
		assert fg.step("abc\r\n");
		assert fg.feed("\x1b]10;rgb:ff/00/00\x07");
		assert colorAt(fg, 0) == "#ffffff";
		assert fg.mismatch() != "";
		assert bg.step("abc\x1b[44mb\x1b[0m");
		assert bg.feed("\x1b]11;rgb:10/10/10\x07");
		assert bg.mismatch() != "";
		assert reverse.step("abc\r\n");
		assert reverse.feed("\x1b[?5h");
		assert colorAt(reverse, 0) == "#ffffff";
		assert reverse.mismatch() != "";
		fg.close();
		bg.close();
		reverse.close();
	}
}
