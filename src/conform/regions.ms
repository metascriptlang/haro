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
		assert s.step("abc
def
ghi
111
222
a");
		assert everything(s) == "abc
def
ghi
111
222
a";
		assert s.step("[3J");
		assert everything(s) == "111
222
a";
		assert s.step("b");
		assert everything(s) == "111
222
ab";
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
		assert s.step("1
M
");
		assert s.lines() == "1

";
		assert top.step("a
b
c" + cup(0, 0) + "M");
		assert top.lines() == "
a
b";
		s.close();
		top.close();
	}
}

test "output scrolls the screen and keeps the lines in scrollback" {
	const s = open(1, 2);
	assert s !== null;
	if (s !== null) {
		for (let i = 1; i <= 8; i++) { assert s.step(`${i}
`); }
		assert s.lines() == "8
";
		assert everything(s) == "1
2
3
4
5
6
7
8
";
		s.close();
	}
}

test "a region that starts on the first row pushes its top line into scrollback" {
	const s = open(1, 3);
	assert s !== null;
	if (s !== null) {
		assert s.step("1
2
3
4
");
		assert s.lines() == "3
4
";
		assert everything(s) == "1
2
3
4
";
		assert s.step(region(0, 1) + "z
");
		assert s.lines() == "z
4
";
		assert s.step("a
");
		assert s.lines() == "a

";
		assert everything(s) == "1
2
z
a

";
		assert s.step(cup(0, 1) + "W
");
		assert s.lines() == "W

";
		assert everything(s) == "1
2
z
a
W

";
		s.close();
	}
}

test "a region below the first row scrolls in place and never touches scrollback" {
	const s = open(1, 5);
	assert s !== null;
	if (s !== null) {
		assert s.step("1
2
3
4
5");
		assert s.step(region(1, 2) + cup(0, 2) + "
a");
		assert s.lines() == "1
3
a
4
5";
		assert everything(s) == "1
3
a
4
5";
		assert s.step(region(0, 1) + cup(0, 1) + "
b");
		assert s.lines() == "3
b
a
4
5";
		assert everything(s) == "1
3
b
a
4
5";
		assert s.step(cup(0, 1) + "[3M");
		assert s.lines() == "3

a
4
5";
		assert everything(s) == "1
3

a
4
5";
		assert s.step(region(0, 4) + cup(0, 4) + "
X");
		assert s.lines() == "
a
4
5
X";
		assert everything(s) == "1
3

a
4
5
X";
		s.close();
	}
}

test "the alternate screen scrolls without scrollback and gives the main screen back" {
	const s = open(1, 5);
	assert s !== null;
	if (s !== null) {
		assert s.step("M
o
n
k
e
y");
		assert s.lines() == "o
n
k
e
y";
		assert s.step("[?1049h1
2
3
4
5");
		assert s.lines() == "1
2
3
4
5";
		assert s.step(region(1, 2) + cup(0, 2) + "
a");
		assert s.lines() == "1
3
a
4
5";
		assert s.step(region(0, 1) + cup(0, 1) + "
b");
		assert s.lines() == "3
b
a
4
5";
		assert s.step(region(0, 4) + cup(0, 4) + "
X");
		assert s.lines() == "b
a
4
5
X";
		assert s.step("[?1049l");
		assert s.lines() == "o
n
k
e
y";
		assert everything(s) == "M
o
n
k
e
y";
		s.close();
	}
}

test "DECCOLM with mode 40 on resizes the terminal and the rows follow" {
	const s = open(5, 5);
	assert s !== null;
	if (s !== null) {
		assert s.step("ABCDE[?3l");
		assert s.raw(0).length == 5;
		assert s.step("[?40h[?3l");
		assert s.raw(0).length == 80;
		assert s.lines() == "



";
		assert cursorAt(s, 0, 0);
		assert s.step("x");
		assert s.text(0) == "x";
		s.close();
	}
}
