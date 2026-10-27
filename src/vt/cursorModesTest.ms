import {
	Cursor,
	CursorLook,
	CursorShape,
	Vt,
	create,
	cursor,
	cursorLook,
	focusReport,
	free,
	modes,
	update,
	writeText,
} from "./vt";
import { ascii, withVt } from "./vtRig";

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
