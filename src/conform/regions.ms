import { defaultIndexed } from "./palette";
import { Screen, joined } from "./screen";

function open(cols: int32, rows: int32): Screen | null {
	const opened = Screen.open(cols, rows);
	if (!opened.ok) { return null; }
	return opened.value;
}

function cursorAt(s: Screen, x: int32, y: int32): boolean {
	const c = s.cursor;
	return c !== null && c.x == x && c.y == y;
}

function cup(col: int32, row: int32): string {
	return `\x1b[${row + 1};${col + 1}H`;
}

function region(top: int32, bottom: int32): string {
	return `\x1b[${top + 1};${bottom + 1}r`;
}

function margins(left: int32, right: int32): string {
	return `\x1b[${left + 1};${right + 1}s`;
}

function everything(s: Screen): string {
	const h = s.history();
	if (h === null) { return "<no history>"; }
	return joined(h);
}

test "CUP clamps to the screen and treats 0 as 1" {
	const s = open(80, 80);
	const small = open(5, 5);
	assert s !== null && small !== null;
	if (s !== null && small !== null) {
		assert s.step("\x1b[0;0H") && cursorAt(s, 0, 0);
		assert s.step("\x1b[81;81H") && cursorAt(s, 79, 79);
		assert small.step("\x1b[500;500HX");
		assert small.text(4) == "    X";
		assert small.text(0) == "";
		s.close();
		small.close();
	}
}

test "CUP, HVP, CHA and VPA move the cursor to one-based places" {
	const s = open(4, 3);
	assert s !== null;
	if (s !== null) {
		assert s.step(cup(1, 1)) && cursorAt(s, 1, 1);
		assert s.step("\x1b[3;3f") && cursorAt(s, 2, 2);
		assert s.step("\x1b[G") && cursorAt(s, 0, 2);
		assert s.step("\x1b[2G") && cursorAt(s, 1, 2);
		assert s.step("\x1b[0G") && cursorAt(s, 0, 2);
		assert s.step("\x1b[100G") && cursorAt(s, 3, 2);
		assert s.step("\x1b[d") && cursorAt(s, 3, 0);
		assert s.step("\x1b[2d") && cursorAt(s, 3, 1);
		s.close();
	}
}

test "REP repeats the last character, IRM inserts instead of overwriting" {
	const rep = open(4, 3);
	const irm = open(8, 3);
	assert rep !== null && irm !== null;
	if (rep !== null && irm !== null) {
		assert rep.step("h" + cup(1, 0) + "\x1b[2ba");
		assert rep.text(0) == "hhha";
		assert irm.step("foo" + cup(0, 0) + "\x1b[4hBAR");
		assert irm.text(0) == "BARfoo";
		rep.close();
		irm.close();
	}
}

test "ICH, ECH and DCH shift or blank cells from the cursor" {
	const ich = open(4, 3);
	const ech = open(4, 3);
	const dch = open(12, 1);
	assert ich !== null && ech !== null && dch !== null;
	if (ich !== null && ech !== null && dch !== null) {
		assert ich.step("hey!wat?" + cup(1, 0) + "\x1b[2@");
		assert ich.text(0) == "h  e" && ich.text(1) == "wat?";
		assert ich.step("\x1b[12@");
		assert ich.text(0) == "h" && ich.text(1) == "wat?";
		assert ech.step("hey!wat?" + cup(1, 0) + "\x1b[2X");
		assert ech.text(0) == "h  !" && ech.text(1) == "wat?";
		assert ech.step("\x1b[12X");
		assert ech.text(0) == "h" && ech.text(1) == "wat?";
		assert dch.step("hello world" + cup(1, 0) + "\x1b[P");
		assert dch.text(0) == "hllo world";
		assert dch.step(cup(4, 0) + "\x1b[2P");
		assert dch.text(0) == "hlloorld";
		ich.close();
		ech.close();
		dch.close();
	}
}

test "deleting characters fills the vacated cells with the current background" {
	const s = open(8, 1);
	assert s !== null;
	if (s !== null) {
		assert s.step("\x1b[40m\x1b[Kfoo\x1b[2P");
		assert s.text(0) == "foo";
		assert s.runs(0).length == 1;
		assert s.runs(0)[0].units == 8;
		assert s.runs(0)[0].bg == defaultIndexed(0);
		s.close();
	}
}

test "ED erases below the cursor, and 2J fills the whole screen with the current background" {
	const s = open(3, 3);
	assert s !== null;
	if (s !== null) {
		assert s.step("abc\r\ndef\r\nghi" + cup(1, 2) + "\x1b[J");
		assert s.lines() == "abc\ndef\ng";
		assert s.step("\x1b[44m\x1b[2J");
		for (let y = 0; y < 3; y++) {
			assert s.text(y) == "";
			assert s.runs(y).length == 1;
			assert s.runs(y)[0].units == 3 && s.runs(y)[0].bg == defaultIndexed(4);
		}
		s.close();
	}
}

test "ED 3 erases the scrollback and the viewport is all that is left" {
	const s = open(3, 3);
	assert s !== null;
	if (s !== null) {
		assert s.step("abc\r\ndef\r\nghi\r\n111\r\n222\r\na");
		assert everything(s) == "abc\ndef\nghi\n111\n222\na";
		assert s.step("\x1b[3J");
		assert everything(s) == "111\n222\na";
		assert s.step("b");
		assert everything(s) == "111\n222\nab";
		s.close();
	}
}

test "inserting and deleting lines inside left and right margins moves only the margin columns" {
	const up = open(5, 5);
	const down = open(5, 5);
	assert up !== null && down !== null;
	if (up !== null && down !== null) {
		const rows = "111\r\n222\r\n333\r\n44444\r\n555";
		assert up.step(rows);
		assert up.lines() == "111\n222\n333\n44444\n555";
		assert up.step("\x1b[?69h" + margins(1, 4) + region(2, 4) + cup(1, 4) + "\n");
		assert up.lines() == "111\n222\n34444\n455\n5";
		assert down.step(rows);
		assert down.step("\x1b[?69h" + margins(1, 4) + region(2, 5) + cup(1, 2) + "\x1b[L");
		assert down.lines() == "111\n222\n3\n433\n54444";
		up.close();
		down.close();
	}
}

test "DL inside shrinking and growing scroll regions" {
	const s = open(3, 5);
	assert s !== null;
	if (s !== null) {
		assert s.step("111\r\n222\r\n333\r\n444\r\n555");
		assert s.step(cup(0, 1) + "\x1b[2M");
		assert s.lines() == "111\n444\n555\n\n";
		assert s.step(cup(0, 3) + "aaa\r\nbbb");
		assert s.lines() == "111\n444\n555\naaa\nbbb";
		assert s.step(region(1, 3) + cup(0, 1) + "\x1b[2M");
		assert s.lines() == "111\naaa\n\n\nbbb";
		assert s.step(region(0, 4) + "\x1b[1M");
		assert s.lines() == "aaa\n\n\nbbb\n";
		s.close();
	}
}

test "DL on a one-column screen deletes from the cursor row" {
	const s = open(1, 3);
	assert s !== null;
	if (s !== null) {
		assert s.step("a\r\nb\r\nc" + cup(0, 1) + "\x1b[M");
		assert s.lines() == "a\nc\n";
		assert cursorAt(s, 0, 1);
		assert s.step(cup(0, 0) + "\x1b[2M");
		assert s.lines() == "\n\n";
		s.close();
	}
}

test "reverse index moves up, and scrolls the screen down at the top row" {
	const s = open(1, 3);
	const top = open(1, 3);
	assert s !== null && top !== null;
	if (s !== null && top !== null) {
		assert s.step("1\n\x1bM\n");
		assert s.lines() == "1\n\n";
		assert top.step("a\nb\nc" + cup(0, 0) + "\x1bM");
		assert top.lines() == "\na\nb";
		s.close();
		top.close();
	}
}

test "output scrolls the screen and keeps the lines in scrollback" {
	const s = open(1, 2);
	assert s !== null;
	if (s !== null) {
		for (let i = 1; i <= 8; i++) { assert s.step(`${i}\n`); }
		assert s.lines() == "8\n";
		assert everything(s) == "1\n2\n3\n4\n5\n6\n7\n8\n";
		s.close();
	}
}

test "a region that starts on the first row pushes its top line into scrollback" {
	const s = open(1, 3);
	assert s !== null;
	if (s !== null) {
		assert s.step("1\n2\n3\n4\n");
		assert s.lines() == "3\n4\n";
		assert everything(s) == "1\n2\n3\n4\n";
		assert s.step(region(0, 1) + "z\n");
		assert s.lines() == "z\n4\n";
		assert s.step("a\n");
		assert s.lines() == "a\n\n";
		assert everything(s) == "1\n2\nz\na\n\n";
		assert s.step(cup(0, 1) + "W\n");
		assert s.lines() == "W\n\n";
		assert everything(s) == "1\n2\nz\na\nW\n\n";
		s.close();
	}
}

test "a region below the first row scrolls in place and never touches scrollback" {
	const s = open(1, 5);
	assert s !== null;
	if (s !== null) {
		assert s.step("1\n2\n3\n4\n5");
		assert s.step(region(1, 2) + cup(0, 2) + "\na");
		assert s.lines() == "1\n3\na\n4\n5";
		assert everything(s) == "1\n3\na\n4\n5";
		assert s.step(region(0, 1) + cup(0, 1) + "\nb");
		assert s.lines() == "3\nb\na\n4\n5";
		assert everything(s) == "1\n3\nb\na\n4\n5";
		assert s.step(cup(0, 1) + "\x1b[3M");
		assert s.lines() == "3\n\na\n4\n5";
		assert everything(s) == "1\n3\n\na\n4\n5";
		assert s.step(region(0, 4) + cup(0, 4) + "\nX");
		assert s.lines() == "\na\n4\n5\nX";
		assert everything(s) == "1\n3\n\na\n4\n5\nX";
		s.close();
	}
}

test "the alternate screen scrolls without scrollback and gives the main screen back" {
	const s = open(1, 5);
	assert s !== null;
	if (s !== null) {
		assert s.step("M\no\nn\nk\ne\ny");
		assert s.lines() == "o\nn\nk\ne\ny";
		assert s.step("\x1b[?1049h1\n2\n3\n4\n5");
		assert s.lines() == "1\n2\n3\n4\n5";
		assert s.step(region(1, 2) + cup(0, 2) + "\na");
		assert s.lines() == "1\n3\na\n4\n5";
		assert s.step(region(0, 1) + cup(0, 1) + "\nb");
		assert s.lines() == "3\nb\na\n4\n5";
		assert s.step(region(0, 4) + cup(0, 4) + "\nX");
		assert s.lines() == "b\na\n4\n5\nX";
		assert s.step("\x1b[?1049l");
		assert s.lines() == "o\nn\nk\ne\ny";
		assert everything(s) == "M\no\nn\nk\ne\ny";
		s.close();
	}
}

test "DECCOLM with mode 40 on resizes the terminal and the rows follow" {
	const s = open(5, 5);
	assert s !== null;
	if (s !== null) {
		assert s.step("ABCDE\x1b[?3l");
		assert s.raw(0).length == 5;
		assert s.step("\x1b[?40h\x1b[?3l");
		assert s.raw(0).length == 80;
		assert s.lines() == "\n\n\n\n";
		assert cursorAt(s, 0, 0);
		assert s.step("x");
		assert s.text(0) == "x";
		s.close();
	}
}

function numbered(from: int32, to: int32): string {
	let out = "";
	for (let i = from; i <= to; i++) { out += `line ${i}\r\n`; }
	return out;
}

test "a flood past the scrollback limit leaves the last rows right and the frames in step" {
	const s = open(40, 24);
	assert s !== null;
	if (s !== null) {
		const lines = 120000;
		let at = 1;
		while (at <= lines) {
			const to = at + 3999 < lines ? at + 3999 : lines;
			assert s.feedChunks(numbered(at, to), 0);
			assert s.mismatch() == "";
			at = to + 1;
		}
		let want = "";
		for (let i = lines - 22; i <= lines; i++) { want += `line ${i}\n`; }
		assert s.lines() == want;
		s.close();
	}
}

test "widening and narrowing reflows a wrapped line and keeps hard breaks" {
	const s = open(4, 8);
	assert s !== null;
	if (s !== null) {
		assert s.step("111\r\n2222aa\r\n333\r\n");
		assert s.lines() == "111\n2222\naa\n333\n\n\n\n";
		assert s.resize(5, 8) && s.mismatch() == "";
		assert s.lines() == "111\n2222a\na\n333\n\n\n\n";
		assert s.resize(6, 8) && s.mismatch() == "";
		assert s.lines() == "111\n2222aa\n333\n\n\n\n\n";
		assert s.resize(8, 8) && s.mismatch() == "";
		assert s.lines() == "111\n2222aa\n333\n\n\n\n\n";
		assert s.resize(6, 8) && s.lines() == "111\n2222aa\n333\n\n\n\n\n";
		assert s.resize(5, 8) && s.lines() == "111\n2222a\na\n333\n\n\n\n";
		assert s.resize(4, 8) && s.lines() == "111\n2222\naa\n333\n\n\n\n";
		assert s.mismatch() == "";
		s.close();
	}
}

test "a line that fills the width survives being widened, and rows can shrink and grow around it" {
	const s = open(20, 4);
	assert s !== null;
	if (s !== null) {
		assert s.step("some long long text");
		assert s.resize(18, 4) && s.mismatch() == "";
		assert s.lines() == "some long long tex\nt\n\n";
		assert s.resize(20, 3) && s.mismatch() == "";
		assert s.lines() == "some long long text\n\n";
		assert s.resize(20, 4) && s.mismatch() == "";
		assert s.lines() == "some long long text\n\n\n";
		assert s.resize(19, 4) && s.lines() == "some long long text\n\n\n";
		s.close();
	}
}

test "a drawing character set, a hidden cursor and a reset before a wrap do not stop the reflow" {
	const draw = open(4, 4);
	const hidden = open(4, 4);
	const reset = open(4, 4);
	assert draw !== null && hidden !== null && reset !== null;
	if (draw !== null && hidden !== null && reset !== null) {
		assert draw.step("\x1b(0qqqq\x1b(B\r\nSS\r\n") && draw.resize(6, 4);
		assert draw.lines() == "\u2500\u2500\u2500\u2500\nSS\n\n";
		assert hidden.step("\x1b[?25l====\x1b[?25h\r\nSS\r\n") && hidden.resize(6, 4);
		assert hidden.lines() == "====\nSS\n\n";
		assert reset.step("====\x1b[0m\r\nSS\r\n") && reset.resize(6, 4);
		assert reset.lines() == "====\nSS\n\n";
		assert draw.mismatch() == "" && hidden.mismatch() == "" && reset.mismatch() == "";
		draw.close();
		hidden.close();
		reset.close();
	}
}
