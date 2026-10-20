import { LineRun } from "../grid/lines";
import { Style } from "../../../neon/src/render/style";
import { Rgb, Underline } from "../vt/vt";
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
			assert fg.run.fg == defaultIndexed(n);
			assert fg.run.bg == fg.defaultBg;
			assert bg.run.bg == defaultIndexed(n);
			assert bg.run.fg == bg.defaultFg;
			assert brightFg.run.fg == defaultIndexed(8 + n);
			assert brightBg.run.bg == defaultIndexed(8 + n);
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
		assert !all.run.bold && !all.run.italic && !all.run.strikethrough;
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
		assert on.run.bold && on.run.italic && on.run.strikethrough;
		assert !noBold.run.bold && noBold.run.italic && noBold.run.strikethrough;
		assert noItalic.run.bold && !noItalic.run.italic && noItalic.run.strikethrough;
		assert noStrike.run.bold && noStrike.run.italic && !noStrike.run.strikethrough;
		assert on.style.fontWeight == "bold" && on.style.fontStyle == "italic";
		assert on.style.textDecorationLine == "line-through";
		assert noBold.style.fontWeight == "normal";
	}
}

test "underline kinds follow SGR 4, 4:n, 21 and 24, and only curly is drawn wavy" {
	const kinds: string[] = ["4", "4:0", "4:1", "4:2", "4:3", "4:4", "4:5", "21", "4;24", "4:3;24"];
	const want: Underline[] = [
		Underline.Single, Underline.None, Underline.Single, Underline.Double, Underline.Curly,
		Underline.Dotted, Underline.Dashed, Underline.Double, Underline.None, Underline.None,
	];
	for (let i = 0; i < kinds.length; i++) {
		const l = look(kinds[i]);
		assert l !== null;
		if (l !== null) {
			assert l.run.underline == want[i];
			assert (l.style.textDecorationLine == "underline") == (want[i] != Underline.None);
			assert (l.style.textDecorationStyle == "wavy") == (want[i] == Underline.Curly);
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
		assert l.run.underline == Underline.None && l.run.bold;
		assert colour.run.fg == colour.defaultFg && colour.run.bold;
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
	if (l !== null) { assert l.run.fg == l.defaultFg && !l.run.bold; }
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

test "known gap: blink and overline do not reach the span" {
	const plain = look("0");
	const blink = look("5");
	const over = look("53");
	assert plain !== null && blink !== null && over !== null;
	if (plain !== null && blink !== null && over !== null) {
		assert sameLook(blink, plain);
		assert sameLook(over, plain);
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
