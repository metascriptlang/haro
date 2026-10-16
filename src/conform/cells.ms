import { readFile } from "std/fs";
import { Screen } from "./screen";

const GRAPHEMES_ON = "\x1b[?2027h";

function run(cols: int32, rows: int32, bytes: string): Screen | null {
	const opened = Screen.open(cols, rows);
	if (!opened.ok) { return null; }
	const s = opened.value;
	if (!s.feed(bytes)) {
		s.close();
		return null;
	}
	return s;
}

function cursorAt(s: Screen, x: int32, y: int32): boolean {
	const c = s.cursor;
	return c !== null && c.x == x && c.y == y;
}

function blanks(n: int32): string {
	return " ".repeat(n);
}

test "a wide character is one unit of text on two cells and moves the cursor two columns" {
	const s = run(6, 2, "\u{1F600}a");
	assert s !== null;
	if (s !== null) {
		assert s.text(0) == "\u{1F600}a";
		assert cursorAt(s, 3, 0);
		s.close();
	}
	const narrow = run(6, 2, "中a");
	assert narrow !== null;
	if (narrow !== null) {
		assert narrow.raw(0) == "中a" + blanks(3);
		assert cursorAt(narrow, 3, 0);
		narrow.close();
	}
}

test "a wide character that does not fit the last column wraps whole and leaves a blank behind" {
	const s = run(10, 3, "\x1b[1;10H\u{1F600}");
	assert s !== null;
	if (s !== null) {
		assert s.raw(0) == blanks(10);
		assert s.text(1) == "\u{1F600}";
		assert cursorAt(s, 2, 1);
		s.close();
	}
}

test "a narrow character over half a wide one blanks the other half" {
	const head = run(80, 2, "\u{1F600}\x1b[1;1HA");
	const tail = run(5, 5, "橋\x1b[1;2HX");
	assert head !== null && tail !== null;
	if (head !== null && tail !== null) {
		assert head.text(0) == "A";
		assert cursorAt(head, 1, 0);
		assert tail.text(0) == " X";
		head.close();
		tail.close();
	}
}

test "overwriting a wide character at the start of a row leaves the row above whole" {
	const s = run(10, 3, "中".repeat(10) + "\x1b[2;1HA");
	assert s !== null;
	if (s !== null) {
		assert s.text(0) == "中".repeat(5);
		assert s.text(1) == "A 中中中中";
		s.close();
	}
}

test "a wide character cannot be drawn in a one-column terminal" {
	const s = run(1, 2, "\u{1F600}");
	assert s !== null;
	if (s !== null) {
		assert s.text(0) == "";
		assert cursorAt(s, 0, 0);
		s.close();
	}
}

test "with wraparound off a wide character that does not fit is dropped" {
	const oneSpace = run(5, 5, "\x1b[?7lAAAA\u{1F6A8}");
	const noSpace = run(5, 5, "\x1b[?7lAAAAA\u{1F6A8}");
	assert oneSpace !== null && noSpace !== null;
	if (oneSpace !== null && noSpace !== null) {
		assert oneSpace.text(0) == "AAAA";
		assert cursorAt(oneSpace, 4, 0);
		assert noSpace.text(0) == "AAAAA";
		assert cursorAt(noSpace, 4, 0);
		oneSpace.close();
		noSpace.close();
	}
}

test "a combining mark joins its base in text and in the cursor column" {
	const s = run(5, 5, GRAPHEMES_ON + "o\u{300}");
	assert s !== null;
	if (s !== null) {
		assert s.text(0) == "o\u{300}";
		assert cursorAt(s, 1, 0);
		s.close();
	}
	const pending = run(2, 2, "xå\u{332}");
	assert pending !== null;
	if (pending !== null) {
		assert pending.text(0) == "xå\u{332}";
		pending.close();
	}
}

test "a zero-width joiner with nothing before it is ignored" {
	const s = run(80, 4, "\u{200D}");
	assert s !== null;
	if (s !== null) {
		assert s.text(0) == "";
		assert cursorAt(s, 0, 0);
		s.close();
	}
}

test "a family of emoji joined by ZWJ is one wide cell with grapheme clustering on, six cells off" {
	const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
	const on = run(80, 2, GRAPHEMES_ON + family);
	const off = run(80, 2, family);
	assert on !== null && off !== null;
	if (on !== null && off !== null) {
		assert on.text(0) == family;
		assert cursorAt(on, 2, 0);
		assert off.text(0) == family;
		assert cursorAt(off, 6, 0);
		on.close();
		off.close();
	}
}

test "a skin tone modifier joins an emoji base and stays apart from a quote" {
	const hand = "\u{1F44B}";
	const tone = "\u{1F3FF}";
	const on = run(5, 3, GRAPHEMES_ON + hand + "\r\n" + hand + tone);
	const quoted = run(80, 2, GRAPHEMES_ON + "\"" + tone + "\"");
	const off = run(5, 3, hand + "\r\n" + hand + tone);
	assert on !== null && quoted !== null && off !== null;
	if (on !== null && quoted !== null && off !== null) {
		assert on.text(0) == hand && on.text(1) == hand + tone && on.text(2) == "";
		assert cursorAt(on, 2, 1);
		assert quoted.text(0) == "\"" + tone + "\"";
		assert cursorAt(quoted, 4, 0);
		assert off.text(1) == hand + tone;
		assert cursorAt(off, 4, 1);
		on.close();
		quoted.close();
		off.close();
	}
}

test "a flag, a ZWJ sequence with a variation selector and a Hangul jamo run keep every codepoint" {
	const pirate = "\u{1F3F4}\u{200D}☠\u{FE0F}";
	const hangul = "ᄒ\u{1161}\u{11AB}";
	const s = run(5, 2, GRAPHEMES_ON + pirate + "\r\n" + hangul);
	const off = run(5, 2, pirate + "\r\n" + hangul);
	assert s !== null && off !== null;
	if (s !== null && off !== null) {
		assert s.text(0) == pirate && s.text(1) == hangul;
		assert off.text(0) == pirate && off.text(1) == hangul;
		s.close();
		off.close();
	}
}

test "VS15 narrows a wide symbol back to one cell" {
	const opened = Screen.open(5, 5);
	assert opened.ok;
	if (opened.ok) {
		const s = opened.value;
		assert s.feed(GRAPHEMES_ON + "☔");
		assert cursorAt(s, 2, 0);
		assert s.feed("\u{FE0E}");
		assert cursorAt(s, 1, 0);
		assert s.text(0) == "☔\u{FE0E}";
		s.close();
	}
}

test "VS16 widens a narrow symbol at the last column onto the next row" {
	const s = run(3, 5, GRAPHEMES_ON + "\x1b[2C#\u{FE0F}");
	assert s !== null;
	if (s !== null) {
		assert s.raw(0) == blanks(3);
		assert s.text(1) == "#\u{FE0F}";
		assert cursorAt(s, 2, 1);
		s.close();
	}
}

test "a Devanagari conjunct is one wide cell, also when it widens at the last column" {
	const conjunct = "क\u{94D}\u{200D}ष";
	const plain = run(5, 5, GRAPHEMES_ON + conjunct);
	const edge = run(3, 5, GRAPHEMES_ON + "\x1b[2Cक\u{94D}\u{200D}ष");
	assert plain !== null && edge !== null;
	if (plain !== null && edge !== null) {
		assert plain.text(0) == conjunct;
		assert cursorAt(plain, 2, 0);
		assert edge.text(0) == "";
		assert edge.text(1) == conjunct;
		assert cursorAt(edge, 2, 1);
		plain.close();
		edge.close();
	}
}

test "a cell keeps at most 64 marks after its base and the frame still paints" {
	const s = run(10, 2, "A" + "\u{301}".repeat(100) + "B");
	assert s !== null;
	if (s !== null) {
		assert s.text(0) == "A" + "\u{301}".repeat(64) + "B";
		assert s.sameAsFreshRead();
		s.close();
	}
}

test "Ghostty's glitch text paints as eight capped graphemes whole and in small frames" {
	const input = readFile("fixtures/conform/ghostty/glitch.txt");
	const expected = readFile("fixtures/conform/ghostty/glitchRow.txt");
	assert input.ok && expected.ok;
	if (input.ok && expected.ok) {
		const whole = run(30, 30, input.value);
		assert whole !== null;
		if (whole !== null) {
			assert whole.text(0) == expected.value;
			assert whole.sameAsFreshRead();
			whole.close();
		}
		const opened = Screen.open(30, 30);
		assert opened.ok;
		if (opened.ok) {
			const s = opened.value;
			assert s.feedChunks(input.value, 7);
			assert s.text(0) == expected.value;
			assert s.sameAsFreshRead();
			s.close();
		}
	}
}

test "text wraps at the right margin and scrolls from the last row" {
	const wrapped = run(5, 40, "helloworldabc12");
	const soft = run(3, 80, "hello");
	const scrolled = run(1, 5, "abcdef");
	assert wrapped !== null && soft !== null && scrolled !== null;
	if (wrapped !== null && soft !== null && scrolled !== null) {
		assert wrapped.text(0) == "hello" && wrapped.text(1) == "world" && wrapped.text(2) == "abc12";
		assert cursorAt(wrapped, 4, 2);
		assert soft.text(0) == "hel" && soft.text(1) == "lo";
		assert cursorAt(soft, 2, 1);
		assert scrolled.lines() == "b\nc\nd\ne\nf";
		assert cursorAt(scrolled, 0, 4);
		wrapped.close();
		soft.close();
		scrolled.close();
	}
}

test "with wraparound off the last column is overwritten, with it on the text wraps" {
	const s = run(10, 5, "\x1b[?7l\x1b[2;2Hhello, world!");
	assert s !== null;
	if (s !== null) {
		assert s.text(1) == " hello, w!";
		assert s.feed("\x1b[?7h\x1b[1J\x1b[2;2Hhello, world!");
		assert s.text(1) == " hello, wo";
		assert s.text(2) == "rld!";
		s.close();
	}
}

test "DEC special graphics maps the line-drawing range, SO and SI switch sets" {
	const g0 = run(50, 2, "\x1b(0ABCabcdefghijklmnopqrstuvwxyzDEF\r\n\x1b(Bhello");
	const shifted = run(50, 2, "\x1b)0\x0eSO-ABCabcdefghijklmnopqrstuvwxyzDEF\r\n\x0fSI-hello");
	const drawing = "▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥";
	assert g0 !== null && shifted !== null;
	if (g0 !== null && shifted !== null) {
		assert g0.text(0) == "ABC" + drawing + "DEF" && g0.text(1) == "hello";
		assert shifted.text(0) == "SO-ABC" + drawing + "DEF" && shifted.text(1) == "SI-hello";
		g0.close();
		shifted.close();
	}
}

test "bytes that are not UTF-8 show as replacement characters and the text after them is intact" {
	const opened = Screen.open(20, 2);
	assert opened.ok;
	if (opened.ok) {
		const s = opened.value;
		assert s.feedBytes([0xF0, 0x9F, 0xF0, 0x9F, 0x98, 0x84, 0xED, 0xA0, 0x80, 0x61]);
		assert s.text(0) == "\uFFFD\u{1F604}\uFFFD\uFFFD\uFFFDa";
		assert s.feedBytes([0xFF, 0x62, 0xC3]);
		assert s.feedBytes([0xA9]);
		assert s.text(0) == "\uFFFD\u{1F604}\uFFFD\uFFFD\uFFFDa\uFFFDb\u00e9";
		assert s.mismatch() == "";
		s.close();
	}
}
