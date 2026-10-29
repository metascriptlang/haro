import { rgb } from "./palette";
import { Screen } from "./screen";

function firstSpanColor(s: Screen, y: int32): string {
	const spans = s.spans(y);
	if (spans.length == 0 || spans[0].style === undefined) { return "<none>"; }
	const c = spans[0].style!.color;
	return c === null ? "<default>" : c;
}

test "an OSC 4 palette change repaints the cells that use the entry, OSC 104 puts it back" {
	const sOpened = Screen.open(10, 3);
	assert sOpened.ok;
	const s = sOpened.value;
	defer s.close();
	assert s.feedsInStep("\x1b[31mr\x1b[0m\r\n\x1b[41m \x1b[0m");
	assert firstSpanColor(s, 0) == "#cc6666";
	assert s.feedsInStep("\x1b]4;1;rgb:00/ff/00\x07");
	assert firstSpanColor(s, 0) == "#00ff00";
	assert s.spans(1)[0].style!.backgroundColor == "#00ff00";
	assert s.feedsInStep("\x1b]104;1\x07");
	assert firstSpanColor(s, 0) == "#cc6666";
	assert s.feedsInStep("\x1b]4;1;rgb:12/34/56\x07\x1b]104\x07");
	assert firstSpanColor(s, 0) == "#cc6666";
}

test "a new default colour (OSC 10, OSC 11, DECSCNM) repaints rows already drawn" {
	const fgOpened = Screen.open(10, 3);
	const bgOpened = Screen.open(10, 3);
	const reverseOpened = Screen.open(10, 3);
	assert fgOpened.ok && bgOpened.ok && reverseOpened.ok;
	const fg = fgOpened.value;
	const bg = bgOpened.value;
	const reverse = reverseOpened.value;
	defer fg.close();
	defer bg.close();
	defer reverse.close();
	assert fg.feedsInStep("abc\r\n");
	assert fg.feed("\x1b]10;rgb:ff/00/00\x07").ok;
	assert firstSpanColor(fg, 0) == "#ff0000";
	assert fg.mismatch() == "";
	assert bg.feedsInStep("abc\x1b[44mb\x1b[0m");
	assert bg.feed("\x1b]11;rgb:10/10/10\x07").ok;
	assert bg.mismatch() == "";
	assert bg.spans(0)[0].style!.backgroundColor === undefined;
	assert reverse.feedsInStep("abc\r\n");
	assert reverse.feed("\x1b[?5h").ok;
	assert reverse.mismatch() == "";
}

function isRedAt(s: Screen, y: int32, unit: int32): boolean {
	let at = 0;
	for (const r of s.runs(y)) {
		if (unit < at + r.units) { return r.bg == rgb(255, 0, 0); }
		at += r.units;
	}
	return false;
}

function redExactly(s: Screen, y: int32, from: int32, units: int32): boolean {
	for (let u = from; u < from + units; u++) {
		if (!isRedAt(s, y, u)) { return false; }
	}
	return !isRedAt(s, y, from + units);
}

test "erasing, inserting and deleting fill the vacated cells with the current background" {
	const indexOpened = Screen.open(5, 5);
	const echOpened = Screen.open(10, 10);
	const ichOpened = Screen.open(10, 10);
	const elOpened = Screen.open(5, 5);
	const edOpened = Screen.open(5, 5);
	const dlOpened = Screen.open(5, 5);
	const bg = "\x1b[48;2;255;0;0m";
	assert indexOpened.ok && echOpened.ok && ichOpened.ok &&
		elOpened.ok && edOpened.ok && dlOpened.ok;
	const index = indexOpened.value;
	const ech = echOpened.value;
	const ich = ichOpened.value;
	const el = elOpened.value;
	const ed = edOpened.value;
	const dl = dlOpened.value;
	defer index.close();
	defer ech.close();
	defer ich.close();
	defer el.close();
	defer ed.close();
	defer dl.close();
	assert index.feedsInStep("\x1b[5;1HA" + bg + "\x1bD");
	assert index.lines() == "\n\n\nA\n";
	assert redExactly(index, 4, 0, 5);
	assert ech.feedsInStep("ABC\x1b[1;1H" + bg + "\x1b[2X");
	assert ech.text(0) == "  C" && redExactly(ech, 0, 0, 2);
	assert ich.feedsInStep("ABC\x1b[1;1H" + bg + "\x1b[2@");
	assert ich.text(0) == "  ABC" && redExactly(ich, 0, 0, 2);
	assert el.feedsInStep("ABCDE\x1b[1;2H" + bg + "\x1b[K");
	assert el.text(0) == "A" && redExactly(el, 0, 1, 4);
	assert ed.feedsInStep("ABC\r\nDEF\r\nGHI\x1b[2;2H" + bg + "\x1b[J");
	assert ed.lines() == "ABC\nD\n\n\n";
	assert redExactly(ed, 1, 1, 4) && redExactly(ed, 2, 0, 5) && redExactly(ed, 4, 0, 5);
	assert dl.feedsInStep("ABC\r\nDEF\r\nGHI\x1b[2;2H" + bg + "\x1b[M");
	assert dl.lines() == "ABC\nGHI\n\n\n";
	assert redExactly(dl, 4, 0, 5);
}
