import { readFile } from "std/fs";
import { Screen, blankScreen } from "./screen";

const GRAPHEMES_ON = "\x1b[?2027h";
const GRAPHEMES_OFF = "\x1b[?2027l";

function screenAfter(cols: int32, rows: int32, bytes: string): Screen | null {
	const s = blankScreen(cols, rows);
	if (s === null) { return null; }
	if (!s.feed(bytes).ok) {
		s.close();
		return null;
	}
	return s;
}

test "a wide character is one unit of text on two cells and moves the cursor two columns" {
	const s = screenAfter(6, 2, "\u{1F600}a");
	assert s !== null;
	defer s.close();
	assert s.text(0) == "\u{1F600}a";
	assert s.cursorAt(3, 0);
	const narrow = screenAfter(6, 2, "中a\x1b[1;6Hz\x1b[1;4H");
	assert narrow !== null;
	defer narrow.close();
	assert narrow.untrimmedText(0) == "中a  z";
	assert narrow.cursorAt(3, 0);
}

test "a wide character that does not fit the last column wraps whole and leaves a blank behind" {
	const s = screenAfter(10, 3, "\x1b[1;10H\u{1F600}");
	assert s !== null;
	defer s.close();
	assert s.untrimmedText(0) == "";
	assert s.text(1) == "\u{1F600}";
	assert s.cursorAt(2, 1);
}

test "a narrow character over half a wide one blanks the other half" {
	const head = screenAfter(80, 2, "\u{1F600}\x1b[1;1HA");
	const tail = screenAfter(5, 5, "橋\x1b[1;2HX");
	assert head !== null && tail !== null;
	defer head.close();
	defer tail.close();
	assert head.text(0) == "A";
	assert head.cursorAt(1, 0);
	assert tail.text(0) == " X";
}

test "overwriting a wide character at the start of a row leaves the row above whole" {
	const s = screenAfter(10, 3, "中".repeat(10) + "\x1b[2;1HA");
	assert s !== null;
	defer s.close();
	assert s.text(0) == "中".repeat(5);
	assert s.text(1) == "A 中中中中";
}

test "a wide character cannot be drawn in a one-column terminal" {
	const s = screenAfter(1, 2, "\u{1F600}");
	assert s !== null;
	defer s.close();
	assert s.text(0) == "";
	assert s.cursorAt(0, 0);
}

test "with wraparound off a wide character that does not fit is dropped" {
	const oneSpace = screenAfter(5, 5, "\x1b[?7lAAAA\u{1F6A8}");
	const noSpace = screenAfter(5, 5, "\x1b[?7lAAAAA\u{1F6A8}");
	assert oneSpace !== null && noSpace !== null;
	defer oneSpace.close();
	defer noSpace.close();
	assert oneSpace.text(0) == "AAAA";
	assert oneSpace.cursorAt(4, 0);
	assert noSpace.text(0) == "AAAAA";
	assert noSpace.cursorAt(4, 0);
}

test "a combining mark joins its base in text and in the cursor column" {
	const s = screenAfter(5, 5, GRAPHEMES_ON + "o\u{300}");
	assert s !== null;
	defer s.close();
	assert s.text(0) == "o\u{300}";
	assert s.cursorAt(1, 0);
	const pending = screenAfter(2, 2, "xå\u{332}");
	assert pending !== null;
	defer pending.close();
	assert pending.text(0) == "xå\u{332}";
}

test "a zero-width joiner with nothing before it is ignored" {
	const s = screenAfter(80, 4, "\u{200D}");
	assert s !== null;
	defer s.close();
	assert s.text(0) == "";
	assert s.cursorAt(0, 0);
}

test "a family of emoji joined by ZWJ is one wide cell with grapheme clustering on, six cells off" {
	const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
	const on = screenAfter(80, 2, GRAPHEMES_ON + family);
	const off = screenAfter(80, 2, GRAPHEMES_OFF + family);
	assert on !== null && off !== null;
	defer on.close();
	defer off.close();
	assert on.text(0) == family;
	assert on.cursorAt(2, 0);
	assert off.text(0) == family;
	assert off.cursorAt(6, 0);
}

test "a skin tone modifier joins an emoji base and stays apart from a quote" {
	const hand = "\u{1F44B}";
	const tone = "\u{1F3FF}";
	const on = screenAfter(5, 3, GRAPHEMES_ON + hand + "\r\n" + hand + tone);
	const quoted = screenAfter(80, 2, GRAPHEMES_ON + "\"" + tone + "\"");
	const off = screenAfter(5, 3, GRAPHEMES_OFF + hand + "\r\n" + hand + tone);
	assert on !== null && quoted !== null && off !== null;
	defer on.close();
	defer quoted.close();
	defer off.close();
	assert on.text(0) == hand && on.text(1) == hand + tone && on.text(2) == "";
	assert on.cursorAt(2, 1);
	assert quoted.text(0) == "\"" + tone + "\"";
	assert quoted.cursorAt(4, 0);
	assert off.text(1) == hand + tone;
	assert off.cursorAt(4, 1);
}

test "a flag, a ZWJ sequence with a variation selector and a Hangul jamo run keep every codepoint" {
	const pirate = "\u{1F3F4}\u{200D}☠\u{FE0F}";
	const hangul = "ᄒ\u{1161}\u{11AB}";
	const s = screenAfter(5, 2, GRAPHEMES_ON + pirate + "\r\n" + hangul);
	const off = screenAfter(5, 2, pirate + "\r\n" + hangul);
	assert s !== null && off !== null;
	defer s.close();
	defer off.close();
	assert s.text(0) == pirate && s.text(1) == hangul;
	assert off.text(0) == pirate && off.text(1) == hangul;
}

test "VS15 narrows a wide symbol back to one cell" {
	const opened = Screen.open(5, 5);
	assert opened.ok;
	if (opened.ok) {
		const s = opened.value;
		assert s.feed(GRAPHEMES_ON + "☔").ok;
		assert s.cursorAt(2, 0);
		assert s.feed("\u{FE0E}").ok;
		assert s.cursorAt(1, 0);
		assert s.text(0) == "☔\u{FE0E}";
		s.close();
	}
}

test "VS16 widens a narrow symbol at the last column onto the next row" {
	const s = screenAfter(3, 5, GRAPHEMES_ON + "\x1b[2C#\u{FE0F}");
	assert s !== null;
	defer s.close();
	assert s.untrimmedText(0) == "";
	assert s.text(1) == "#\u{FE0F}";
	assert s.cursorAt(2, 1);
}

test "a Devanagari conjunct is one wide cell, also when it widens at the last column" {
	const conjunct = "क\u{94D}\u{200D}ष";
	const plain = screenAfter(5, 5, GRAPHEMES_ON + conjunct);
	const edge = screenAfter(3, 5, GRAPHEMES_ON + "\x1b[2Cक\u{94D}\u{200D}ष");
	assert plain !== null && edge !== null;
	defer plain.close();
	defer edge.close();
	assert plain.text(0) == conjunct;
	assert plain.cursorAt(2, 0);
	assert edge.text(0) == "";
	assert edge.text(1) == conjunct;
	assert edge.cursorAt(2, 1);
}

test "a cell keeps at most 64 marks after its base and the frame still paints" {
	const s = screenAfter(10, 2, "A" + "\u{301}".repeat(100) + "B");
	assert s !== null;
	defer s.close();
	assert s.text(0) == "A" + "\u{301}".repeat(64) + "B";
	assert s.sameAsFreshRead();
}

test "the glitch text fixture paints as eight capped graphemes whole and in small frames" {
	const input = readFile("fixtures/conform/ghostty/glitch.txt");
	const expected = readFile("fixtures/conform/ghostty/glitchRow.txt");
	assert input.ok && expected.ok;
	if (input.ok && expected.ok) {
		const whole = screenAfter(30, 30, input.value);
		assert whole !== null;
		defer whole.close();
		assert whole.text(0) == expected.value;
		assert whole.sameAsFreshRead();
		const opened = Screen.open(30, 30);
		assert opened.ok;
		if (opened.ok) {
			const s = opened.value;
			assert s.feedChunks(input.value, 7).ok;
			assert s.text(0) == expected.value;
			assert s.sameAsFreshRead();
			s.close();
		}
	}
}

test "text wraps at the right margin and scrolls from the last row" {
	const wrapped = screenAfter(5, 40, "helloworldabc12");
	const soft = screenAfter(3, 80, "hello");
	const scrolled = screenAfter(1, 5, "abcdef");
	assert wrapped !== null && soft !== null && scrolled !== null;
	defer wrapped.close();
	defer soft.close();
	defer scrolled.close();
	assert wrapped.text(0) == "hello" && wrapped.text(1) == "world" &&
		wrapped.text(2) == "abc12";
	assert wrapped.cursorAt(4, 2);
	assert soft.text(0) == "hel" && soft.text(1) == "lo";
	assert soft.cursorAt(2, 1);
	assert scrolled.lines() == "b\nc\nd\ne\nf";
	assert scrolled.cursorAt(0, 4);
}

test "with wraparound off the last column is overwritten, with it on the text wraps" {
	const s = screenAfter(10, 5, "\x1b[?7l\x1b[2;2Hhello, world!");
	assert s !== null;
	defer s.close();
	assert s.text(1) == " hello, w!";
	assert s.feed("\x1b[?7h\x1b[1J\x1b[2;2Hhello, world!").ok;
	assert s.text(1) == " hello, wo";
	assert s.text(2) == "rld!";
}

test "DEC special graphics maps the line-drawing range, SO and SI switch sets" {
	const g0 = screenAfter(50, 2, "\x1b(0ABCabcdefghijklmnopqrstuvwxyzDEF\r\n\x1b(Bhello");
	const shifted = screenAfter(
		50,
		2,
		"\x1b)0\x0eSO-ABCabcdefghijklmnopqrstuvwxyzDEF\r\n\x0fSI-hello",
	);
	const drawing = "▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥";
	assert g0 !== null && shifted !== null;
	defer g0.close();
	defer shifted.close();
	assert g0.text(0) == "ABC" + drawing + "DEF" && g0.text(1) == "hello";
	assert shifted.text(0) == "SO-ABC" + drawing + "DEF" && shifted.text(1) == "SI-hello";
}

test "bytes that are not UTF-8 show as replacement characters and the text after them is intact" {
	const opened = Screen.open(20, 2);
	assert opened.ok;
	if (opened.ok) {
		const s = opened.value;
		assert s.feedBytes([0xF0, 0x9F, 0xF0, 0x9F, 0x98, 0x84, 0xED, 0xA0, 0x80, 0x61]).ok;
		assert s.text(0) == "\uFFFD\u{1F604}\uFFFD\uFFFD\uFFFDa";
		assert s.feedBytes([0xFF, 0x62, 0xC3]).ok;
		assert s.feedBytes([0xA9]).ok;
		assert s.text(0) == "\uFFFD\u{1F604}\uFFFD\uFFFD\uFFFDa\uFFFDb\u00e9";
		assert s.mismatch() == "";
		s.close();
	}
}
