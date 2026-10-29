import { LineRun } from "../grid/lines";
import { Style } from "../../../neon/src/render/style";
import { CellFlag, Rgb, Underline } from "../vt/vt";
import { cssHex, defaultIndexed, rgb } from "./palette";
import { Screen } from "./screen";

struct Look {
	run: LineRun;
	style: Style;
	defaultFg: Rgb;
	defaultBg: Rgb;
	text: string;
}

function look(sgr: string): Look | null {
	const opened = Screen.open(4, 1);
	if (!opened.ok) { return null; }
	const s = opened.value;
	let found: Look | null = null;
	if (s.feed("\x1b[" + sgr + "mX").ok) {
		const colors = s.vt.palette();
		const spans = s.spans(0);
		if (colors.ok && spans.length > 0 && spans[0].style !== undefined) {
			found = {
				run: s.runs(0)[0],
				style: spans[0].style!,
				defaultFg: colors.value.fg,
				defaultBg: colors.value.bg,
				text: spans[0].text,
			};
		}
	}
	s.close();
	return found;
}

function withinOne(a: uint8, b: int32): boolean {
	const d = (a as int32) - b;
	return d >= -1 && d <= 1;
}

test "SGR 30-37 and 40-47 pick the eight named colours, 90-97 and 100-107 the bright ones" {
	for (let n = 0; n < 8; n++) {
		const fg = look(`${30 + n}`);
		const bg = look(`${40 + n}`);
		const brightFg = look(`${90 + n}`);
		const brightBg = look(`${100 + n}`);
		assert fg !== null && bg !== null && brightFg !== null && brightBg !== null;
		if (fg !== null && bg !== null && brightFg !== null && brightBg !== null) {
			assert fg.run.fg == defaultIndexed(n as uint8);
			assert fg.run.bg == fg.defaultBg;
			assert bg.run.bg == defaultIndexed(n as uint8);
			assert bg.run.fg == bg.defaultFg;
			assert brightFg.run.fg == defaultIndexed((8 + n) as uint8);
			assert brightBg.run.bg == defaultIndexed((8 + n) as uint8);
		}
	}
}

test "SGR 39 and 49 return to the terminal's defaults, 0 clears everything" {
	const fg = look("31;39");
	const bg = look("41;49");
	const all = look("1;3;4;9;31;42;0");
	assert fg !== null && bg !== null && all !== null;
	if (fg !== null && bg !== null && all !== null) {
		assert fg.run.fg == fg.defaultFg;
		assert bg.run.bg == bg.defaultBg;
		assert all.run.fg == all.defaultFg && all.run.bg == all.defaultBg;
		assert !all.run.flags.has(CellFlag.Bold) &&
			!all.run.flags.has(CellFlag.Italic) &&
			!all.run.flags.has(CellFlag.Strikethrough);
		assert all.run.underline == Underline.None;
	}
}

test "256-colour SGR picks the palette entry, with semicolons or colons" {
	const a = look("38;5;161;48;5;236");
	const b = look("38:5:161;48:5:236");
	const cube = look("38;5;16;48;5;231");
	const gray = look("38;5;232;48;5;255");
	assert a !== null && b !== null && cube !== null && gray !== null;
	if (a !== null && b !== null && cube !== null && gray !== null) {
		assert a.run.fg == defaultIndexed(161) && a.run.bg == defaultIndexed(236);
		assert b.run.fg == a.run.fg && b.run.bg == a.run.bg;
		assert cube.run.fg == rgb(0, 0, 0) && cube.run.bg == rgb(255, 255, 255);
		assert gray.run.fg == rgb(8, 8, 8) && gray.run.bg == rgb(238, 238, 238);
	}
}

test "truecolour SGR skips the optional colour space only after a colon" {
	const colon = look("38:2:0:1:2:3;48:2:0:4:5:6");
	const empty = look("38:2::7:8:9;48:2::10:11:12");
	const semicolon = look("38;2;0;1;2;48;2;0;1;2");
	assert colon !== null && empty !== null && semicolon !== null;
	if (colon !== null && empty !== null && semicolon !== null) {
		assert colon.run.fg == rgb(1, 2, 3) && colon.run.bg == rgb(4, 5, 6);
		assert empty.run.fg == rgb(7, 8, 9) && empty.run.bg == rgb(10, 11, 12);
		assert semicolon.run.fg == rgb(0, 1, 2) && semicolon.run.bg == rgb(0, 1, 2);
	}
}

test "bold, italic and strikethrough set and reset on their own codes" {
	const on = look("1;3;9");
	const noBold = look("1;3;9;22");
	const noItalic = look("1;3;9;23");
	const noStrike = look("1;3;9;29");
	assert on !== null && noBold !== null && noItalic !== null && noStrike !== null;
	if (on !== null && noBold !== null && noItalic !== null && noStrike !== null) {
		assert on.run.flags.has(CellFlag.Bold) &&
			on.run.flags.has(CellFlag.Italic) &&
			on.run.flags.has(CellFlag.Strikethrough);
		assert !noBold.run.flags.has(CellFlag.Bold) &&
			noBold.run.flags.has(CellFlag.Italic) &&
			noBold.run.flags.has(CellFlag.Strikethrough);
		assert noItalic.run.flags.has(CellFlag.Bold) &&
			!noItalic.run.flags.has(CellFlag.Italic) &&
			noItalic.run.flags.has(CellFlag.Strikethrough);
		assert noStrike.run.flags.has(CellFlag.Bold) &&
			noStrike.run.flags.has(CellFlag.Italic) &&
			!noStrike.run.flags.has(CellFlag.Strikethrough);
		assert on.style.fontWeight == "bold" && on.style.fontStyle == "italic";
		assert on.style.textDecorationLine == "line-through";
		assert noBold.style.fontWeight == "normal";
	}
}

struct UnderlineCase { sgr: string; underline: Underline; }

test "underline kinds follow SGR 4, 4:n, 21 and 24, and only curly is drawn wavy" {
	const cases: UnderlineCase[] = [
		{ sgr: "4", underline: Underline.Single },
		{ sgr: "4:0", underline: Underline.None },
		{ sgr: "4:1", underline: Underline.Single },
		{ sgr: "4:2", underline: Underline.Double },
		{ sgr: "4:3", underline: Underline.Curly },
		{ sgr: "4:4", underline: Underline.Dotted },
		{ sgr: "4:5", underline: Underline.Dashed },
		{ sgr: "21", underline: Underline.Double },
		{ sgr: "4;24", underline: Underline.None },
		{ sgr: "4:3;24", underline: Underline.None },
	];
	for (const c of cases) {
		const l = look(c.sgr);
		assert l !== null;
		if (l !== null) {
			assert l.run.underline == c.underline;
			assert (l.style.textDecorationLine == "underline") == (c.underline != Underline.None);
			assert (l.style.textDecorationStyle == "wavy") == (c.underline == Underline.Curly);
		}
	}
}

test "an underline with a strikethrough shares one decoration line" {
	const l = look("4;9");
	assert l !== null;
	if (l !== null) { assert l.style.textDecorationLine == "underline line-through"; }
}

test "a later underline code replaces an earlier kind" {
	const l = look("4:3;21");
	assert l !== null;
	if (l !== null) { assert l.run.underline == Underline.Double; }
}

test "an SGR parameter with too many colons is dropped and the next one still applies" {
	const l = look("4:2:3;1");
	const colour = look("38:2:0:1:2:3:4;1");
	assert l !== null && colour !== null;
	if (l !== null && colour !== null) {
		assert l.run.underline == Underline.None && l.run.flags.has(CellFlag.Bold);
		assert colour.run.fg == colour.defaultFg && colour.run.flags.has(CellFlag.Bold);
	}
}

test "inverse swaps the foreground and background, including the defaults" {
	const plain = look("7");
	const coloured = look("31;42;7");
	const off = look("7;27");
	assert plain !== null && coloured !== null && off !== null;
	if (plain !== null && coloured !== null && off !== null) {
		assert plain.run.fg == plain.defaultBg && plain.run.bg == plain.defaultFg;
		assert plain.style.color == cssHex(plain.defaultBg);
		assert plain.style.backgroundColor == cssHex(plain.defaultFg);
		assert coloured.run.fg == defaultIndexed(2) && coloured.run.bg == defaultIndexed(1);
		assert off.run.fg == off.defaultFg && off.run.bg == off.defaultBg;
	}
}

test "faint blends the foreground half way into the background" {
	const l = look("38;2;200;100;0;48;2;0;0;100;2");
	assert l !== null;
	if (l !== null) {
		assert withinOne(l.run.fg.r, 100) && withinOne(l.run.fg.g, 50) && withinOne(l.run.fg.b, 50);
		assert l.run.bg == rgb(0, 0, 100);
	}
}

test "SGR 22 clears faint along with bold" {
	const l = look("2;22");
	assert l !== null;
	if (l !== null) { assert l.run.fg == l.defaultFg && !l.run.flags.has(CellFlag.Bold); }
}

test "a background equal to the terminal's is left to the window, any other is a span background" {
	const same = look("48;2;1;2;3;49");
	const other = look("41");
	assert same !== null && other !== null;
	if (same !== null && other !== null) {
		assert same.style.backgroundColor === undefined;
		assert other.style.backgroundColor == cssHex(defaultIndexed(1));
	}
}

function sameLook(a: Look, b: Look): boolean {
	return a.style.color == b.style.color &&
		a.style.backgroundColor == b.style.backgroundColor &&
		a.style.textDecorationLine == b.style.textDecorationLine &&
		a.style.textDecorationStyle == b.style.textDecorationStyle &&
		a.style.fontWeight == b.style.fontWeight &&
		a.style.fontStyle == b.style.fontStyle;
}

test "known gap: blink does not reach the span" {
	const plain = look("0");
	const blink = look("5");
	assert plain !== null && blink !== null;
	if (plain !== null && blink !== null) { assert sameLook(blink, plain); }
}

test "SGR 53 overlines the span, alone and beside an underline, and 55 ends it" {
	const over = look("53");
	const both = look("4;53");
	const ended = look("53;55");
	assert over !== null && both !== null && ended !== null;
	if (over !== null && both !== null && ended !== null) {
		assert over.style.textDecorationLine == "overline";
		assert both.style.textDecorationLine == "underline overline";
		assert ended.style.textDecorationLine == "none";
	}
}

test "concealed text reaches the span as blanks in the plain look" {
	const plain = look("0");
	const hidden = look("8");
	assert plain !== null && hidden !== null;
	if (plain !== null && hidden !== null) {
		assert sameLook(hidden, plain) && !hidden.text.startsWith("X");
	}
}
