export {
	Cell,
	CellFlag,
	Mouse,
	MouseAction,
	MouseGeometry,
	MouseInput,
	Painted,
	Palette,
	PasteError,
	Rgb,
	Row,
	Underline,
	VtError,
} from "./vtTypes";
export {
	DesktopNotification,
	Effects,
	VtEvents,
} from "./vtEffects";
export {
	SCROLLBACK_LINES,
	Vt,
	answerClipboard,
	clean,
	clipboardAsked,
	create,
	free,
	holdLimit,
	holding,
	linkAt,
	pwd,
	resize,
	setDefaultColors,
	setPalette,
	setPullScrollback,
	setScrollback,
	size,
	takeClipboard,
	takeEvents,
	takeReplies,
	title,
	update,
	write,
	writeText,
} from "./terminal";
export {
	Cursor,
	CursorLook,
	CursorShape,
	Modes,
	cursor,
	cursorLook,
	focusReport,
	modes,
} from "./cursorModes";
export {
	mouseReport,
} from "./mouseReport";
export {
	dirtyRows,
	isUnicodeScalar,
	lines,
	palette,
	rows,
	text,
} from "./render";
export {
	PromptJump,
	alternateScreen,
	anchorTop,
	anchoredRow,
	atBottom,
	jumpToPrompt,
	scrollBottom,
	scrollLines,
	scrollOffset,
	scrollPages,
	scrollTop,
} from "./scroll";
export {
	selectedText,
	selection,
	selectionClear,
	selectionSet,
	unitAt,
} from "./selection";
export {
	Keys,
	KeysError,
	encode,
	freeKeys,
	openKeys,
	pasteBytes,
} from "./keyEncoder";

import {
	KeyAction,
	KeyEvent,
	KeyMod,
	OptionAsAlt,
} from "../keys/keys";
import {
	Marked,
	Point,
	Selection,
	Unit,
} from "../select/select";
import {
	Cursor,
	CursorLook,
	CursorShape,
	cursor,
	cursorLook,
	focusReport,
	modes,
} from "./cursorModes";
import {
	Keys,
	encode,
	freeKeys,
	openKeys,
	pasteBytes,
} from "./keyEncoder";
import { mouseReport } from "./mouseReport";
import {
	dirtyRows,
	lines,
	palette,
	rows,
	text,
} from "./render";
import {
	PromptJump,
	atBottom,
	jumpToPrompt,
	scrollBottom,
	scrollLines,
	scrollOffset,
	scrollPages,
	scrollTop,
} from "./scroll";
import {
	selectedText,
	selection,
	selectionClear,
	selectionSet,
	unitAt,
} from "./selection";
import {
	SCROLLBACK_LINES,
	Vt,
	answerClipboard,
	clean,
	clipboardAsked,
	create,
	free,
	holdLimit,
	holding,
	linkAt,
	pwd,
	resize,
	setDefaultColors,
	setPullScrollback,
	setScrollback,
	size,
	takeClipboard,
	takeEvents,
	takeReplies,
	title,
	update,
	write,
	writeText,
} from "./terminal";
import { NOTIFICATION_BODY_BYTES, NOTIFICATION_TITLE_BYTES } from "./vtEffects";
import { pushAll } from "./vtNative";
import {
	CellFlag,
	MouseAction,
	MouseGeometry,
	MouseInput,
	PasteError,
	Rgb,
	VtError,
} from "./vtTypes";

test "written text lands on the rows the render state reports" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("hello\r\nworld");
		const updated = vt.update();
		assert updated.ok;
		const size = vt.size();
		assert size.ok;
		if (size.ok) {
			assert size.value[0] == 20;
			assert size.value[1] == 4;
		}
		const lines = vt.lines();
		assert lines.ok;
		if (lines.ok) {
			assert lines.value.length == 4;
			assert lines.value[0] == "hello";
			assert lines.value[1] == "world";
		}
	});
}

test "raw bytes keep a multi-byte UTF-8 character whole" {
	assert withVt(10, 2, (vt: Vt): void => {
		let bytes: Vec<uint8> = new Array(4);
		bytes[0] = 0x61;
		bytes[1] = 0xC3;
		bytes[2] = 0xA9;
		bytes[3] = 0x62;
		vt.write(bytes);
		const updated = vt.update();
		assert updated.ok;
		const lines = vt.lines();
		assert lines.ok;
		if (lines.ok) { assert lines.value[0] == "aéb"; }
	});
}

function withVt(cols: int32, rows: int32, body: (vt: Vt) => void): boolean {
	const created = Vt.create(cols, rows);
	if (!created.ok) { return false; }
	body(created.value);
	created.value.free();
	return true;
}

function ascii(bytes: Span<uint8>): string {
	let text = "";
	for (const b of bytes) { text += String.fromCharCode(b as int32); }
	return text;
}

test "a cursor position query is answered with the cursor's place" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("ab\x1b[6n");
		assert pending(vt) == "\x1b[1;3R";
	});
}

test "bells, a title and a pwd reach the host as events once each" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x07a\x07\x1b]2;build: ok\x07\x1b]7;file:///C:/Users/me\x07");
		const first = vt.takeEvents();
		assert first.bells == 2;
		assert first.titleChanged;
		assert first.pwdChanged;
		const title = vt.title();
		assert title.ok;
		if (title.ok) { assert title.value == "build: ok"; }
		const pwd = vt.pwd();
		assert pwd.ok;
		if (pwd.ok) { assert pwd.value == "file:///C:/Users/me"; }
		const second = vt.takeEvents();
		assert second.bells == 0;
		assert !second.titleChanged;
		assert !second.pwdChanged;
	});
}

test "an untitled terminal has an empty title" {
	assert withVt(20, 4, (vt: Vt): void => {
		const title = vt.title();
		assert title.ok;
		if (title.ok) { assert title.value == ""; }
	});
}

test "a desktop notification reaches the host once, by OSC 9 with a body and OSC 777 with a title" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x1b]9;build done\x07");
		const nine = vt.takeEvents().notification;
		assert nine !== null;
		if (nine !== null) {
			assert nine.title == "";
			assert nine.body == "build done";
		}
		vt.writeText("\x1b]777;notify;make;all green\x07");
		const rxvt = vt.takeEvents().notification;
		assert rxvt !== null;
		if (rxvt !== null) {
			assert rxvt.title == "make";
			assert rxvt.body == "all green";
		}
		assert vt.takeEvents().notification === null;
	});
}

test "a notification's text stops at its cap on a character, and bytes that are not UTF-8 read as U+FFFD" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText(`\x1b]777;notify;${"t".repeat(300)};${"中".repeat(400)}\x07`);
		const long = vt.takeEvents().notification;
		assert long !== null;
		if (long !== null) {
			assert long.title == "t".repeat(NOTIFICATION_TITLE_BYTES);
			assert long.body == "中".repeat(NOTIFICATION_BODY_BYTES / 3);
		}
		let bytes: Vec<uint8> = [];
		pushAll(bytes, "\x1b]9;a".asBytes());
		for (const b of [0xff, 0x62, 0xe4, 0xb8, 0x63, 0xed, 0xa0, 0x80, 0x07]) { bytes.push(b as uint8); }
		vt.write(bytes);
		const broken = vt.takeEvents().notification;
		assert broken !== null;
		if (broken !== null) { assert broken.body == "a\u{fffd}b\u{fffd}\u{fffd}c\u{fffd}\u{fffd}\u{fffd}"; }
	});
}

test "ConPTY's request for win32-input-mode is tracked like any other mode" {
	assert withVt(20, 4, (vt: Vt): void => {
		const fresh = vt.modes();
		assert fresh.ok && !fresh.value.win32Input;
		vt.writeText("\x1b[?9001h\x1b[?1004h");
		const asked = vt.modes();
		assert asked.ok && asked.value.win32Input;
		vt.writeText("\x1b[?9001l");
		const ended = vt.modes();
		assert ended.ok && !ended.value.win32Input;
	});
}

test "a program's input modes are readable, and a fresh terminal sets only alternate scroll" {
	assert withVt(20, 4, (vt: Vt): void => {
		const fresh = vt.modes();
		assert fresh.ok;
		if (fresh.ok) {
			assert !fresh.value.focusEvents;
			assert !fresh.value.bracketedPaste;
			assert !fresh.value.cursorKeys;
			assert !fresh.value.mouseTracking;
			assert fresh.value.altScroll;
		}
		vt.writeText("\x1b[?1004h\x1b[?2004h\x1b[?1h\x1b[?1000h\x1b[?1007l");
		const set = vt.modes();
		assert set.ok;
		if (set.ok) {
			assert set.value.focusEvents;
			assert set.value.bracketedPaste;
			assert set.value.cursorKeys;
			assert set.value.mouseTracking;
			assert !set.value.altScroll;
		}
	});
}

test "a focus change is reported only once the program asked for it" {
	assert withVt(20, 4, (vt: Vt): void => {
		let buf: Vec<uint8> = new Array(16);
		const before = vt.focusReport(true, buf);
		assert before.ok;
		if (before.ok) { assert before.value == 0; }
		vt.writeText("\x1b[?1004h");
		const gained = vt.focusReport(true, buf);
		assert gained.ok;
		if (gained.ok) { assert ascii(buf[0..gained.value]) == "\x1b[I"; }
		const lost = vt.focusReport(false, buf);
		assert lost.ok;
		if (lost.ok) { assert ascii(buf[0..lost.value]) == "\x1b[O"; }
	});
}

const GEOMETRY: MouseGeometry = {
	cellWidth: 10,
	cellHeight: 20,
	width: 200,
	height: 80,
	padLeft: 0,
	padTop: 0,
	padRight: 0,
	padBottom: 0,
};

function mouseBytes(
	vt: Vt,
	action: MouseAction,
	button: int32,
	mods: BitSet<KeyMod>,
	anyPressed: boolean,
): string {
	let buf: Vec<uint8> = new Array(32);
	const e: MouseInput = { action: action, button: button, mods: mods, x: 25.0, y: 25.0 };
	const n = vt.mouseReport(e, GEOMETRY, anyPressed, buf);
	if (!n.ok) { return "error"; }
	return ascii(buf[0..n.value]);
}

test "a mouse event is silent until the program turns mouse reporting on" {
	assert withVt(20, 4, (vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		assert mouseBytes(vt, MouseAction.Press, 1, none, true) == "";
	});
}

test "SGR reporting names the cell, the button and the modifiers" {
	assert withVt(20, 4, (vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		vt.writeText("\x1b[?1000h\x1b[?1006h");
		assert mouseBytes(vt, MouseAction.Press, 1, none, true) == "\x1b[<0;3;2M";
		assert mouseBytes(vt, MouseAction.Release, 1, none, false) == "\x1b[<0;3;2m";
		assert mouseBytes(vt, MouseAction.Press, 3, none, true) == "\x1b[<1;3;2M";
		assert mouseBytes(vt, MouseAction.Press, 4, none, false) == "\x1b[<64;3;2M";
		const shift = none.incl(KeyMod.Shift);
		assert mouseBytes(vt, MouseAction.Press, 1, shift, true) == "\x1b[<4;3;2M";
	});
}

function pressAt(vt: Vt, x: float32, y: float32): string {
	const padded: MouseGeometry = { ...GEOMETRY, width: 260, height: 140, padLeft: 30, padTop: 30, padRight: 30, padBottom: 30 };
	const e: MouseInput = { action: MouseAction.Press, button: 1, mods: 0 as BitSet<KeyMod>, x: x, y: y };
	let buf: Vec<uint8> = new Array(32);
	const n = vt.mouseReport(e, padded, true, buf);
	if (!n.ok) { return "error"; }
	return ascii(buf[0..n.value]);
}

test "a press in the padding reports the nearest cell, and the grid starts past the padding" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x1b[?1000h\x1b[?1006h");
		assert pressAt(vt, 5, 5) == "\x1b[<0;1;1M";
		assert pressAt(vt, 45, 55) == "\x1b[<0;2;2M";
		assert pressAt(vt, 255, 135) == "\x1b[<0;20;4M";
	});
}

test "motion is reported only under button or any-event tracking" {
	assert withVt(20, 4, (vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		vt.writeText("\x1b[?1000h\x1b[?1006h");
		assert mouseBytes(vt, MouseAction.Motion, 1, none, true) == "";
		vt.writeText("\x1b[?1002h");
		assert mouseBytes(vt, MouseAction.Motion, 1, none, true) == "\x1b[<32;3;2M";
		vt.writeText("\x1b[?1003h");
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "\x1b[<35;3;2M";
	});
}

test "the same cell is not reported twice for motion, and SGR-pixels reports pixels" {
	assert withVt(20, 4, (vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		vt.writeText("\x1b[?1003h\x1b[?1006h");
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "\x1b[<35;3;2M";
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "";
		vt.writeText("\x1b[?1016h");
		assert mouseBytes(vt, MouseAction.Press, 1, none, true) == "\x1b[<0;25;25M";
	});
}

test "setting a mouse mode that is already on still switches the report format and event" {
	assert withVt(20, 4, (vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		vt.writeText("\x1b[?1000h\x1b[?1006h");
		assert mouseBytes(vt, MouseAction.Press, 1, none, true) == "\x1b[<0;3;2M";
		vt.writeText("\x1b[?1015h");
		assert mouseBytes(vt, MouseAction.Press, 1, none, true) == "\x1b[32;3;2M";
		vt.writeText("\x1b[?1006h");
		assert mouseBytes(vt, MouseAction.Press, 1, none, true) == "\x1b[<0;3;2M";
		vt.writeText("\x1b[?1003h");
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "\x1b[<35;3;2M";
		vt.writeText("\x1b[?1000h");
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "";
	});
}

test "same-cell motion is reported again once after any write, because the encoder rereads its modes" {
	assert withVt(20, 4, (vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		vt.writeText("\x1b[?1003h\x1b[?1006h");
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "\x1b[<35;3;2M";
		vt.writeText("x");
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "\x1b[<35;3;2M";
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "";
	});
}

test "a frame drawn under synchronized output shows only once the program ends the hold" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("one");
		assert vt.update().ok;
		vt.writeText("\x1b[?2026h\x1b[2J\x1b[Hhalf");
		assert vt.holding();
		assert vt.update().ok;
		const held = vt.lines();
		assert held.ok;
		if (held.ok) { assert held.value[0] == "one"; }
		vt.writeText(" drawn\x1b[?2026l");
		assert !vt.holding();
		assert vt.update().ok;
		const shown = vt.lines();
		assert shown.ok;
		if (shown.ok) { assert shown.value[0] == "half drawn"; }
	});
}

test "a hold the program never ends is dropped after its limit" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.holdLimit(0);
		vt.writeText("\x1b[?2026hstuck");
		assert vt.update().ok;
		assert !vt.holding();
		const shown = vt.lines();
		assert shown.ok;
		if (shown.ok) { assert shown.value[0] == "stuck"; }
		vt.writeText("\x1b[?2026h");
		vt.holdLimit(1000);
		assert vt.holding();
	});
}

function lookAfter(input: string): CursorLook | null {
	const created = Vt.create(20, 4);
	if (!created.ok) { return null; }
	const vt = created.value;
	vt.writeText(input);
	const updated = vt.update();
	const look = vt.cursorLook();
	vt.free();
	if (!updated.ok || !look.ok) { return null; }
	const found: CursorLook | null = look.value;
	return found;
}

test "a fresh cursor is a visible blinking block" {
	const blinkingBlock: CursorLook = { visible: true, shape: CursorShape.Block, blinking: true };
	assert lookAfter("") == blinkingBlock;
}

test "DECTCEM hides and shows the cursor" {
	const hidden = lookAfter("\x1b[?25l");
	assert hidden !== null;
	if (hidden !== null) { assert !hidden.visible; }
	const shown = lookAfter("\x1b[?25l\x1b[?25h");
	assert shown !== null;
	if (shown !== null) { assert shown.visible; }
}

test "DECSCUSR picks the cursor's shape and blink" {
	const blinkingBar: CursorLook = { visible: true, shape: CursorShape.Bar, blinking: true };
	const steadyUnderline: CursorLook = {
		visible: true,
		shape: CursorShape.Underline,
		blinking: false,
	};
	const steadyBlock: CursorLook = { visible: true, shape: CursorShape.Block, blinking: false };
	assert lookAfter("\x1b[5 q") == blinkingBar;
	assert lookAfter("\x1b[4 q") == steadyUnderline;
	assert lookAfter("\x1b[6 q\x1b[2 q") == steadyBlock;
}

function replyTo(query: string): string {
	const created = Vt.create(20, 4);
	if (!created.ok) { return "create failed"; }
	const vt = created.value;
	vt.writeText(query);
	const replied = pending(vt);
	vt.free();
	return replied;
}

test "the device attributes and the version name Haro as a VT220 with colour and clipboard" {
	assert replyTo("\x1b[c") == "\x1b[?62;22;52c";
	assert replyTo("\x1b[>c") == "\x1b[>1;10;0c";
	assert replyTo("\x1b[>q") == "\x1bP>|haro\x1b\\";
}

test "the tertiary device attributes carry a zero unit id" {
	assert replyTo("\x1b[=c") == "\x1bP!|00000000\x1b\\";
}

test "a mode report names a mode set, reset and unknown" {
	assert replyTo("\x1b[?2004$p") == "\x1b[?2004;2$y";
	assert replyTo("\x1b[?2004h\x1b[?2004$p") == "\x1b[?2004;1$y";
	assert replyTo("\x1b[?9999$p") == "\x1b[?9999;0$y";
}

test "colour queries answer with the host's defaults, a program's override and the palette" {
	assert replyTo("\x1b]11;?\x07") == "\x1b]11;rgb:0000/0000/0000\x07";
	assert replyTo("\x1b]10;?\x07") == "\x1b]10;rgb:ffff/ffff/ffff\x07";
	assert replyTo("\x1b]11;rgb:10/20/30\x07\x1b]11;?\x07") == "\x1b]11;rgb:1010/2020/3030\x07";
	assert replyTo("\x1b]4;1;?\x07") == "\x1b]4;1;rgb:cccc/6666/6666\x07";
}

test "a theme the host sets is what a colour query reports" {
	assert withVt(20, 4, (vt: Vt): void => {
		assert vt.setDefaultColors({ r: 0x28, g: 0x2c, b: 0x34 }, { r: 0xff, g: 0xff, b: 0xfe }).ok;
		vt.writeText("\x1b]11;?\x1b\\");
		assert pending(vt) == "\x1b]11;rgb:ffff/ffff/fefe\x1b\\";
	});
}

function cursorColorAfter(text: string): Result<Rgb | null, VtError> {
	const vt = try Vt.create(20, 4);
	vt.writeText(text);
	const updated = vt.update();
	const colors = vt.palette();
	vt.free();
	if (!updated.ok || !colors.ok) { return Result.err(VtError.ReadFailed); }
	return Result.ok(colors.value.cursor);
}

test "a program sets the cursor colour with OSC 12 and resets it with OSC 112" {
	const red: Rgb = { r: 255, g: 0, b: 0 };
	const fresh = cursorColorAfter("");
	assert fresh.ok && fresh.value === null;
	const set = cursorColorAfter("\x1b]12;#ff0000\x07");
	assert set.ok && set.value == red;
	const reset = cursorColorAfter("\x1b]12;#ff0000\x07\x1b]112\x07");
	assert reset.ok && reset.value === null;
}

function rowsAfterGrowing(pull: boolean): string {
	const created = Vt.create(10, 3);
	if (!created.ok) { return "create failed"; }
	const vt = created.value;
	vt.setPullScrollback(pull);
	vt.writeText("l1\r\nl2\r\nl3\r\nl4\r\nl5");
	vt.resize(10, 5);
	vt.update();
	const lines = vt.lines();
	vt.free();
	if (!lines.ok) { return "read failed"; }
	return lines.value.join("|");
}

function keptAfter(lines: int32, keep: int64): int32 {
	const created = Vt.create(20, 4);
	if (!created.ok) { return -1; }
	const vt = created.value;
	if (keep != SCROLLBACK_LINES && !vt.setScrollback(keep).ok) { return -1; }
	vt.writeText(numberedLines(lines));
	vt.scrollTop();
	if (!vt.update().ok) { return -1; }
	const oldest = topLine(vt);
	vt.free();
	return lines - (oldest.slice(1).parseInt() as int32);
}

test "scrollback keeps about ten thousand lines by default, and a set limit replaces it" {
	const byDefault = keptAfter(30000, SCROLLBACK_LINES);
	assert byDefault > 7500 && byDefault <= 10000;
	const set = keptAfter(30000, 5000);
	assert set > 2500 && set <= 5000;
}

test "growing the grid reveals scrollback unless the pty keeps its own screen" {
	assert rowsAfterGrowing(true) == "l1|l2|l3|l4|l5";
	assert rowsAfterGrowing(false) == "l3|l4|l5||";
}

test "an OSC 52 write reaches the host once, and only for the standard clipboard" {
	assert withVt(20, 4, (vt: Vt): void => {
		assert vt.takeClipboard() === null;
		vt.writeText("\x1b]52;p;cHJpbWFyeQ==\x07");
		assert vt.takeClipboard() === null;
		vt.writeText("\x1b]52;c;aGVsbG8gd29ybGQ=\x07");
		assert vt.takeClipboard() == "hello world";
		assert vt.takeClipboard() === null;
		vt.writeText("\x1b]52;c;\x07");
		assert vt.takeClipboard() == "";
	});
}

function shown(r: Result<string | null, VtError>): string {
	if (!r.ok) { return "<failed>"; }
	const got = r.value;
	if (got !== null) { return got; }
	return "<none>";
}

test "an OSC 8 link answers for each of its cells and for no others" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x1b]8;;https://example.com/a?b=1\x1b\\link\x1b]8;;\x1b\\ plain");
		assert shown(vt.linkAt(0, 0)) == "https://example.com/a?b=1";
		assert shown(vt.linkAt(3, 0)) == "https://example.com/a?b=1";
		assert shown(vt.linkAt(4, 0)) == "<none>";
		assert shown(vt.linkAt(0, 1)) == "<none>";
		assert shown(vt.linkAt(0, 40)) == "<failed>";
	});
}

function topAfterJump(vt: Vt, toward: PromptJump): string {
	const jumped = vt.jumpToPrompt(toward);
	if (!jumped.ok) { return "<failed>"; }
	if (!jumped.value) { return "<none>"; }
	vt.update();
	return topLine(vt);
}

test "the viewport jumps between OSC 133 prompts" {
	assert withVt(10, 3, (vt: Vt): void => {
		const prompt = "\x1b]133;A\x07";
		vt.writeText(`${prompt}p1\r\nout1\r\nout2\r\n${prompt}p2\r\nout3\r\n${prompt}p3`);
		vt.update();
		assert vt.lines().ok;
		assert topAfterJump(vt, PromptJump.Previous) == "p1";
		assert topAfterJump(vt, PromptJump.Previous) == "<none>";
		assert topAfterJump(vt, PromptJump.Next) == "p2";
	});
}

test "a screen without prompt marks has nothing to jump to" {
	assert withVt(10, 3, (vt: Vt): void => {
		vt.writeText("a\r\nb\r\nc\r\nd\r\ne");
		assert topAfterJump(vt, PromptJump.Previous) == "<none>";
		assert topAfterJump(vt, PromptJump.Next) == "<none>";
	});
}

test "text without a query leaves nothing to reply" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("hello");
		assert vt.takeReplies().length == 0;
	});
}

test "a styled cell carries its colour, flags and underline" {
	assert withVt(20, 2, (vt: Vt): void => {
		vt.writeText("\x1b[1;4;38;2;255;0;0mA\x1b[0mb");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const red: Rgb = { r: 255, g: 0, b: 0 };
			const a = rows.value[0].cells[0];
			assert a.cp == 0x41;
			assert a.fg == red;
			assert a.flags.has(CellFlag.Bold);
			assert !a.flags.has(CellFlag.Italic);
			assert a.underline == Underline.Single;
			const b = rows.value[0].cells[1];
			assert b.cp == 0x62;
			assert b.fg != red;
			assert b.flags.isEmpty();
			assert b.underline == Underline.None;
		}
	});
}

test "an erased line keeps its background on cells without text" {
	assert withVt(10, 2, (vt: Vt): void => {
		vt.writeText("\x1b[48;2;0;0;255m\x1b[K");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const blue: Rgb = { r: 0, g: 0, b: 255 };
			const cell = rows.value[0].cells[5];
			assert cell.cp == 0;
			assert cell.bg == blue;
		}
	});
}

test "a cluster of forty codepoints is one cell that keeps them all" {
	assert withVt(10, 2, (vt: Vt): void => {
		let cluster = "a";
		for (let i = 0; i < 39; i++) { cluster += String.fromCharCode(0x301); }
		vt.writeText(cluster + "b");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const row = rows.value[0];
			assert row.cells[0].cp == 0x61;
			assert row.cells[0].extra == 39;
			assert row.cells[1].cp == 0x62;
			const text = row.text();
			assert text.ok;
			if (text.ok) { assert text.value.startsWith(cluster + "b"); }
		}
	});
}

test "a character above the basic plane reads back whole" {
	assert withVt(10, 2, (vt: Vt): void => {
		vt.writeText("x😀");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			assert rows.value[0].cells[1].cp == 0x1F600;
			const text = rows.value[0].text();
			assert text.ok;
			if (text.ok) { assert text.value.startsWith("x😀"); }
		}
	});
}

test "an underline carries the SGR 58 colour, resolved from the palette when it is an index" {
	assert withVt(10, 2, (vt: Vt): void => {
		vt.writeText("\x1b[4:3m\x1b[58;2;255;80;80ma\x1b[58;5;1mb\x1b[59mc\x1b[24;58;2;1;2;3md");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const cells = rows.value[0].cells;
			const salmon: Rgb = { r: 255, g: 80, b: 80 };
			assert cells[0].underlineColor == salmon;
			const indexed = cells[1].underlineColor;
			assert indexed !== null;
			if (indexed !== null) {
				assert indexed.r > indexed.g && indexed.r > indexed.b && indexed.r != 255;
			}
			assert cells[2].underline == Underline.Curly;
			assert cells[2].underlineColor === null;
			assert cells[3].underline == Underline.None;
			assert cells[3].underlineColor === null;
		}
	});
}

test "a wide character is flagged and its spacer holds no text" {
	assert withVt(10, 2, (vt: Vt): void => {
		vt.writeText("中a");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const cells = rows.value[0].cells;
			assert cells[0].cp == 0x4E2D;
			assert cells[0].flags.has(CellFlag.Wide);
			assert cells[1].cp == 0;
			assert cells[2].cp == 0x61;
			assert !cells[2].flags.has(CellFlag.Wide);
		}
	});
}

test "a combining mark joins its base cell" {
	assert withVt(10, 2, (vt: Vt): void => {
		vt.writeText("éx");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const row = rows.value[0];
			assert row.cells[0].cp == 0x65;
			assert row.cells[0].extra == 1;
			assert row.extra.length == 1;
			assert row.extra[0] == 0x301;
			assert row.cells[1].cp == 0x78;
		}
	});
}

test "a skin-tone emoji is one wide cell, also after a full reset" {
	assert withVt(10, 2, (vt: Vt): void => {
		for (const prefix of ["", "\x1bc"]) {
			vt.writeText(`${prefix}\u{1F44D}\u{1F3FD}x`);
			assert vt.update().ok;
			const rows = vt.rows();
			assert rows.ok;
			if (rows.ok) {
				const row = rows.value[0];
				assert row.cells[0].cp == 0x1F44D;
				assert row.cells[0].flags.has(CellFlag.Wide);
				assert row.cells[0].extra == 1 && row.extra[0] == 0x1F3FD;
				assert row.cells[2].cp == 0x78;
			}
		}
	});
}

function clusterAt(vt: Vt, base: uint32): Vec<uint32> {
	let found: Vec<uint32> = [];
	if (!vt.update().ok) { return found; }
	const rows = vt.rows();
	if (!rows.ok) { return found; }
	for (const row of rows.value) {
		let extraAt = 0;
		for (const cell of row.cells) {
			if (cell.cp == base && cell.flags.has(CellFlag.Wide)) {
				found.push(base);
				for (let k = 0; k < (cell.extra as int32); k++) { found.push(row.extra[extraAt + k]); }
				return found;
			}
			extraAt += cell.extra as int32;
		}
	}
	return found;
}

test "a cluster that widens in the last column wraps with its codepoints, below a scroll region too" {
	const heart = "\u{2764}\u{200D}\u{1F44D}";
	const kssa = "\u{915}\u{94D}\u{937}";
	for (const at of ["\x1b[2;4r\x1b[6;20H", "\x1b[6;20H", "\x1b[2;4r\x1b[4;20H"]) {
		assert withVt(20, 6, (vt: Vt): void => {
			vt.writeText(at + heart);
			const cluster = clusterAt(vt, 0x2764);
			assert cluster.length == 3 && cluster[1] == 0x200D && cluster[2] == 0x1F44D;
		});
		assert withVt(20, 6, (vt: Vt): void => {
			vt.writeText(at + kssa);
			const cluster = clusterAt(vt, 0x915);
			assert cluster.length == 3 && cluster[1] == 0x94D && cluster[2] == 0x937;
		});
	}
}

test "a line's text keeps each cell's combining marks with that cell" {
	assert withVt(10, 2, (vt: Vt): void => {
		vt.writeText("éậx");
		assert vt.update().ok;
		const lines = vt.lines();
		assert lines.ok;
		if (lines.ok) { assert lines.value[0] == "éậx"; }
	});
}

test "a grapheme longer than the inline buffer arrives whole" {
	assert withVt(10, 2, (vt: Vt): void => {
		vt.writeText(`e${"\u0301".repeat(20)}x`);
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const row = rows.value[0];
			assert row.cells[0].cp == 0x65;
			assert row.cells[0].extra == 20;
			assert row.extra.length == 20;
			assert row.extra[19] == 0x301;
			assert row.cells[1].cp == 0x78;
		}
	});
}

test "only rows written since the last clean are dirty" {
	assert withVt(10, 4, (vt: Vt): void => {
		vt.writeText("a\nb");
		assert vt.update().ok;
		vt.clean();
		vt.writeText("c");
		assert vt.update().ok;
		const dirty = vt.dirtyRows();
		assert dirty.ok;
		if (dirty.ok) {
			assert dirty.value.length == 1;
			assert dirty.value[0].y == 1;
			assert dirty.value[0].cells[1].cp == 0x62;
		}
	});
}

function press(key: string, text: string, unshifted: uint32, mods: BitSet<KeyMod>): KeyEvent {
	return {
		action: KeyAction.Press,
		key: key,
		mods: mods,
		consumedMods: 0 as BitSet<KeyMod>,
		unshifted: unshifted,
		text: text,
	};
}

function encoded(k: Keys, vt: Vt, e: KeyEvent): string {
	let buf: Vec<uint8> = new Array(64);
	const r = k.encode(vt, e, buf);
	if (!r.ok) { return ""; }
	return ascii(buf[0..r.value]);
}

function withKeys(body: (k: Keys, vt: Vt) => void): boolean {
	const opened = Keys.openKeys();
	if (!opened.ok) { return false; }
	const k = opened.value;
	const made = withVt(20, 4, (vt: Vt): void => { body(k, vt); });
	k.freeKeys();
	return made;
}

test "AltGr text reaches the program as the text once the consumed Ctrl+Alt is dropped" {
	assert withKeys((k: Keys, vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		const ctrlAlt = none.incl(KeyMod.Ctrl).incl(KeyMod.Alt);
		const brace: KeyEvent = { ...press("Digit7", "{", 0x37, ctrlAlt), consumedMods: ctrlAlt };
		assert encoded(k, vt, brace.withoutAltGr()) == "{";
		const polish: KeyEvent = { ...brace, key: "KeyA", unshifted: 0x61, text: "ą" };
		assert encoded(k, vt, polish.withoutAltGr()) == "Ä";
	});
}

test "enter encodes as a carriage return" {
	assert withKeys((k: Keys, vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		assert encoded(k, vt, press("Enter", "\r", 0x0D, none)) == "\r";
	});
}

test "ctrl+c encodes as ETX even when the platform reports the byte as text" {
	assert withKeys((k: Keys, vt: Vt): void => {
		const ctrl = (0 as BitSet<KeyMod>).incl(KeyMod.Ctrl);
		assert encoded(k, vt, press("KeyC", "\x03", 0x63, ctrl)) == "\x03";
	});
}

test "arrow up follows the cursor key mode the vt is in" {
	assert withKeys((k: Keys, vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		assert encoded(k, vt, press("ArrowUp", "", 0, none)) == "\x1b[A";
		vt.writeText("\x1b[?1h");
		assert encoded(k, vt, press("ArrowUp", "", 0, none)) == "\x1bOA";
	});
}

test "alt prefixes the escape, except macOS Option, whose text the system composes" {
	assert withKeys((k: Keys, vt: Vt): void => {
		const alt = (0 as BitSet<KeyMod>).incl(KeyMod.Alt);
		when (macos) {
			assert encoded(k, vt, press("KeyX", "x", 0x78, alt)) == "x";
		} else {
			assert encoded(k, vt, press("KeyX", "x", 0x78, alt)) == "\x1bx";
		}
	});
}

test "macOS Option sends the escape before the key text the window kept when it acts as Alt" {
	assert withKeys((given: Keys, vt: Vt): void => {
		let k = given;
		const shift = (0 as BitSet<KeyMod>).incl(KeyMod.Shift);
		const left = shift.incl(KeyMod.Alt);
		const asAlt: KeyEvent = { ...press("KeyB", "B", 0x62, left), consumedMods: shift };
		const composed: KeyEvent = { ...press("KeyB", "ı", 0x62, left), consumedMods: left };
		when (macos) {
			k.optionAsAlt = OptionAsAlt.Left;
			assert encoded(k, vt, asAlt) == "\x1bB";
			k.optionAsAlt = OptionAsAlt.Neither;
			assert encoded(k, vt, composed) == "\u00c4\u00b1";
		}
	});
}

test "a consumed alt lets the text through unprefixed" {
	assert withKeys((k: Keys, vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		const alt = none.incl(KeyMod.Alt);
		const e: KeyEvent = { ...press("BracketLeft", "{", 0x5B, alt), consumedMods: alt };
		assert encoded(k, vt, e) == "{";
	});
}

test "ctrl with printable text encodes as fixterms csi u" {
	assert withKeys((k: Keys, vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		const ctrlAlt = none.incl(KeyMod.Ctrl).incl(KeyMod.Alt);
		const e: KeyEvent = { ...press("BracketLeft", "{", 0x5B, ctrlAlt), consumedMods: ctrlAlt };
		assert encoded(k, vt, e) == "\x1b[123;7u";
	});
}

test "a committed grapheme arrives as its utf-8 bytes" {
	assert withKeys((k: Keys, vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		let buf: Vec<uint8> = new Array(64);
		const r = k.encode(vt, press("Unidentified", "ệ", 0, none), buf);
		assert r.ok;
		if (r.ok) {
			assert r.value == 3;
			assert buf[0] == 0xE1;
			assert buf[1] == 0xBB;
			assert buf[2] == 0x87;
		}
	});
}

function cursorAfter(text: string): Cursor | null {
	const created = Vt.create(20, 4);
	if (!created.ok) { return null; }
	const vt = created.value;
	vt.writeText(text);
	const updated = vt.update();
	const at = vt.cursor();
	vt.free();
	if (!updated.ok || !at.ok) { return null; }
	return at.value;
}

test "a cursor on a wide character covers both its cells, from the character or its tail" {
	const wideAtZero: Cursor = { x: 0, y: 0, wide: true };
	const afterWide: Cursor = { x: 2, y: 0, wide: false };
	const second: Cursor = { x: 1, y: 0, wide: false };
	assert cursorAfter("\u4e2d\x1b[1G") == wideAtZero;
	assert cursorAfter("\u4e2d\x1b[2G") == wideAtZero;
	assert cursorAfter("\u4e2d") == afterWide;
	assert cursorAfter("ab\x1b[2G") == second;
}

test "the cursor reports where the next write lands" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("ab");
		assert vt.update().ok;
		const pastText: Cursor = { x: 2, y: 0, wide: false };
		const nextLine: Cursor = { x: 0, y: 1, wide: false };
		const afterText = vt.cursor();
		assert afterText.ok;
		if (afterText.ok) { assert afterText.value == pastText; }
		vt.writeText("\r\n");
		assert vt.update().ok;
		const afterNewline = vt.cursor();
		assert afterNewline.ok;
		if (afterNewline.ok) { assert afterNewline.value == nextLine; }
	});
}

function numberedLines(count: int32): string {
	let text = "r0";
	for (let i = 1; i < count; i++) { text += `\r\nr${i}`; }
	return text;
}

function linefeedLines(count: int32): string {
	let text = "";
	for (let i = 0; i < count; i++) { text += `\nq${i}`; }
	return text;
}

function topLine(vt: Vt): string {
	const lines = vt.lines();
	if (lines.ok) { return lines.value[0]; }
	return "<unreadable>";
}

function at(row: int32, col: int32): Point {
	return { row: row, col: col };
}

function marked(r0: int32, c0: int32, r1: int32, c1: int32): Marked {
	return { range: { start: at(r0, c0), end: at(r1, c1) }, block: false };
}

test "the viewport scrolls by lines, pages, to the top and back to the bottom" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText(numberedLines(10));
		assert vt.update().ok;
		assert topLine(vt) == "r6";
		assert (try vt.atBottom() catch false);
		vt.scrollLines(-2);
		assert vt.update().ok;
		assert topLine(vt) == "r4";
		assert !(try vt.atBottom() catch true);
		assert (try vt.scrollOffset() catch -1) == 4;
		vt.scrollLines(1);
		assert vt.update().ok;
		assert topLine(vt) == "r5";
		vt.scrollTop();
		assert vt.update().ok;
		assert topLine(vt) == "r0";
		vt.scrollLines(-5);
		assert vt.update().ok;
		assert topLine(vt) == "r0";
		assert vt.scrollPages(1).ok;
		assert vt.update().ok;
		assert topLine(vt) == "r4";
		vt.scrollBottom();
		assert vt.update().ok;
		assert topLine(vt) == "r6";
		assert (try vt.atBottom() catch false);
		vt.scrollLines(5);
		assert vt.update().ok;
		assert topLine(vt) == "r6";
		vt.free();
	}
}

test "new output while scrolled up leaves the view where it was" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText(numberedLines(10));
		vt.scrollLines(-3);
		assert vt.update().ok;
		assert topLine(vt) == "r3";
		vt.writeText("\r\nr10\r\nr11\r\nr12\r\nr13\r\nr14");
		assert vt.update().ok;
		assert topLine(vt) == "r3";
		assert !(try vt.atBottom() catch true);
		vt.scrollBottom();
		assert vt.update().ok;
		assert topLine(vt) == "r11";
		vt.free();
	}
}

test "a selection across two wrapped rows copies one logical line" {
	assert withVt(10, 4, (vt: Vt): void => {
		vt.writeText("abcdefghijklmnop\r\nnext");
		assert vt.update().ok;
		assert vt.selectionSet(marked(0, 2, 1, 4)).ok;
		assert shown(vt.selectedText()) == "cdefghijklmno";
		assert vt.selectionSet(marked(0, 0, 2, 3)).ok;
		assert shown(vt.selectedText()) == "abcdefghijklmnop\nnext";
	});
}

test "trailing spaces are trimmed on each copied line" {
	assert withVt(10, 4, (vt: Vt): void => {
		vt.writeText("hi   \r\nthere");
		assert vt.update().ok;
		assert vt.selectionSet(marked(0, 0, 1, 9)).ok;
		assert shown(vt.selectedText()) == "hi\nthere";
	});
}

test "a double click picks the word under the pointer and a triple click the logical line" {
	assert withVt(10, 4, (vt: Vt): void => {
		vt.writeText("foo bar-baz qux again");
		assert vt.update().ok;
		const word = vt.unitAt(Unit.Word, at(0, 5));
		assert word.ok;
		if (word.ok) {
			assert word.value.start == at(0, 4);
			const sel = Selection.press(Unit.Word, word.value, false);
			assert vt.selectionSet(sel.marked()).ok;
			assert shown(vt.selectedText()) == "bar-baz";
		}
		const line = vt.unitAt(Unit.Line, at(1, 3));
		assert line.ok;
		if (line.ok) {
			assert line.value.start == at(0, 0);
			assert vt.selectionSet({ range: line.value, block: false }).ok;
			assert shown(vt.selectedText()) == "foo bar-baz qux again";
		}
	});
}

test "a double click on either half of a wide character picks the whole word, and a blank cell after a word picks only itself" {
	assert withVt(10, 4, (vt: Vt): void => {
		vt.writeText("中文 x");
		assert vt.update().ok;
		for (const col of [0, 1, 2, 3]) {
			const word = vt.unitAt(Unit.Word, at(0, col));
			assert word.ok;
			if (word.ok) {
				assert word.value.start == at(0, 0);
				assert vt.selectionSet({ range: word.value, block: false }).ok;
				assert shown(vt.selectedText()) == "中文";
			}
		}
		const blank = vt.unitAt(Unit.Word, at(0, 6));
		assert blank.ok;
		if (blank.ok) {
			assert blank.value.start == at(0, 6) && blank.value.end == at(0, 6);
		}
	});
}

test "a selection survives five lines of new output" {
	assert withVt(10, 4, (vt: Vt): void => {
		vt.writeText(numberedLines(4));
		assert vt.update().ok;
		assert vt.selectionSet(marked(1, 0, 2, 1)).ok;
		assert shown(vt.selectedText()) == "r1\nr2";
		vt.writeText("\r\nn0\r\nn1\r\nn2\r\nn3\r\nn4");
		assert vt.update().ok;
		const kept = vt.selection();
		assert kept.ok;
		if (kept.ok) {
			const m = kept.value;
			assert m !== null;
			if (m !== null) {
				assert m.range.start == at(1, 0);
				assert m.range.end == at(2, 1);
			}
		}
		assert shown(vt.selectedText()) == "r1\nr2";
	});
}

test "a selection follows its text when scrollback is pruned" {
	const created = Vt.create(80, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		assert vt.setScrollback(1000).ok;
		vt.writeText(numberedLines(6000));
		assert vt.update().ok;
		const row = (try vt.scrollOffset() catch 0) + 3;
		assert vt.selectionSet(marked(row, 0, row, 5)).ok;
		assert shown(vt.selectedText()) == "r5999";
		vt.writeText(linefeedLines(400));
		assert vt.update().ok;
		const kept = vt.selection();
		assert kept.ok;
		if (kept.ok) {
			const m = kept.value;
			assert m !== null;
			if (m !== null) { assert m.range.start.row < row; }
		}
		assert shown(vt.selectedText()) == "r5999";
		vt.free();
	}
}

test "an erased selection is gone from the terminal" {
	assert withVt(10, 4, (vt: Vt): void => {
		vt.writeText("hello");
		assert vt.update().ok;
		assert vt.selectionSet(marked(0, 0, 0, 4)).ok;
		vt.selectionClear();
		const none = vt.selection();
		assert none.ok;
		if (none.ok) { assert none.value === null; }
		assert shown(vt.selectedText()) == "<none>";
	});
}

function pasted(vt: Vt, text: string, allowUnsafe: boolean): string {
	const bytes = vt.pasteBytes(text, allowUnsafe);
	if (bytes.ok) { return ascii(bytes.value); }
	return bytes.error == PasteError.Unsafe ? "<unsafe>" : "<failed>";
}

test "an unbracketed paste turns newlines into carriage returns and refuses them unconfirmed" {
	assert withVt(10, 4, (vt: Vt): void => {
		assert pasted(vt, "hello", false) == "hello";
		assert pasted(vt, "a\nb", false) == "<unsafe>";
		assert pasted(vt, "a\nb", true) == "a\rb";
	});
}

test "a bracketed paste is framed and only its end marker is unsafe" {
	assert withVt(10, 4, (vt: Vt): void => {
		vt.writeText("\x1b[?2004h");
		assert pasted(vt, "a\nb", false) == "\x1b[200~a\nb\x1b[201~";
		assert pasted(vt, "x\x1b[31my", false) == "\x1b[200~x [31my\x1b[201~";
		assert pasted(vt, "evil\x1b[201~rm", false) == "<unsafe>";
		vt.writeText("\x1b[?2004l");
		assert pasted(vt, "plain", false) == "plain";
	});
}

function pending(vt: Vt): string {
	let replies = vt.takeReplies();
	return ascii(replies);
}

test "a size query is answered with the terminal's own cells and pixels, as is the report mode 2048 starts with" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x1b[18t");
		assert pending(vt) == "\x1b[8;4;20t";
		vt.writeText("\x1b[14t\x1b[16t");
		assert pending(vt) == "\x1b[4;0;0t\x1b[6;0;0t";
		vt.writeText("\x1b[?2048h");
		assert pending(vt) == "\x1b[48;4;20;0;0t";
	});
}

test "an OSC 52 read waits for the host and is answered in the frame the program used" {
	assert withVt(20, 4, (vt: Vt): void => {
		assert !vt.clipboardAsked();
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert pending(vt) == "";
		assert vt.clipboardAsked();
		assert !vt.clipboardAsked();
		assert vt.answerClipboard("hello", true).ok;
		assert pending(vt) == "\x1b]52;c;aGVsbG8=\x1b\\";
		assert !vt.answerClipboard("again", true).ok;
		vt.writeText("\x1b]52;c;?\x07");
		assert vt.clipboardAsked();
		assert vt.answerClipboard("secret", false).ok;
		assert pending(vt) == "\x1b]52;c;\x07";
	});
}

test "base64 in an OSC 52 answer pads one and two leftover bytes" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert vt.answerClipboard("ab", true).ok;
		assert pending(vt) == "\x1b]52;c;YWI=\x1b\\";
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert vt.answerClipboard("a", true).ok;
		assert pending(vt) == "\x1b]52;c;YQ==\x1b\\";
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert vt.answerClipboard("", true).ok;
		assert pending(vt) == "\x1b]52;c;\x1b\\";
	});
}

test "an OSC 5522 clipboard read is refused at once rather than waiting for an OSC 52 answer" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x1b]5522;type=read:id=r1;dGV4dC9wbGFpbg==\x1b\\");
		assert !vt.clipboardAsked();
		assert pending(vt) == "\x1b]5522;type=read:status=EPERM:id=r1\x1b\\";
	});
}

test "clipboard writes while a read waits leave the waiting answer intact" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert vt.clipboardAsked();
		vt.writeText("\x1b]52;c;YQ==\x1b\\\x1b]52;c;Yg==\x1b\\");
		assert vt.answerClipboard("hello", true).ok;
		assert pending(vt) == "\x1b]52;c;aGVsbG8=\x1b\\";
	});
}

test "a second read while one waits, and a primary-selection read, get an empty answer at once" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert vt.clipboardAsked();
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert pending(vt) == "\x1b]52;c;\x1b\\";
		assert !vt.clipboardAsked();
		assert vt.answerClipboard("x", true).ok;
		assert pending(vt) == "\x1b]52;c;eA==\x1b\\";
		vt.writeText("\x1b]52;p;?\x1b\\");
		assert pending(vt) == "\x1b]52;p;\x1b\\";
		assert !vt.clipboardAsked();
	});
}

test "the cursor blinks until the program asks for a steady one, and DECSCUSR 0 blinks again" {
	const fresh = lookAfter("");
	assert fresh !== null;
	if (fresh !== null) { assert fresh.blinking; }
	const steady = lookAfter("\x1b[2 q");
	assert steady !== null;
	if (steady !== null) { assert !steady.blinking; }
	const reset = lookAfter("\x1b[2 q\x1b[0 q");
	assert reset !== null;
	if (reset !== null) { assert reset.blinking; }
}
