import {
	GhosttyTerminalData,
	size_t,
} from "../../vendor/ghostty/include/ghostty/vt.h";
import { snapshot } from "./snapshot";
import {
	Vt,
	alternateScreen,
	cursor,
	lines,
	palette,
	modes,
	pwd,
	resize,
	rows,
	setPalette,
	scrollTop,
	size,
	title,
	update,
	write,
	writeText,
} from "./vt";
import { Colors256, checked, terminalGet } from "./vtNative";
import { Rgb, VtError } from "./vtTypes";
import { linefeedLines, withVt } from "./vtRig";

function restoredInto(a: Vt, body: (b: Vt) => void): boolean {
	const shot = a.snapshot();
	if (!shot.ok || !a.update().ok) { return false; }
	const size = a.size();
	if (!size.ok) { return false; }
	let updated = false;
	const made = withVt(size.value[0], size.value[1], (b: Vt): void => {
		b.write(shot.value);
		updated = b.update().ok && a.update().ok;
		if (updated) { body(b); }
	});
	return made && updated;
}

function scrollbackRows(vt: Vt): Result<int32, VtError> {
	let count: size_t = 0;
	const key = GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS;
	try checked(terminalGet(vt.terminal, key, count), VtError.ReadFailed);
	return Result.ok(count as int32);
}

function sameLines(a: Vt, b: Vt): boolean {
	const left = a.lines();
	const right = b.lines();
	if (!left.ok || !right.ok) { return false; }
	if (left.value.length != right.value.length) { return false; }
	for (let i = 0; i < left.value.length; i++) {
		if (left.value[i] != right.value[i]) {
			console.log(`row ${i}: "${left.value[i]}" vs "${right.value[i]}"`);
			return false;
		}
	}
	return true;
}

function sameCells(a: Vt, b: Vt): boolean {
	const left = a.rows();
	const right = b.rows();
	if (!left.ok || !right.ok) { return false; }
	if (left.value.length != right.value.length) { return false; }
	for (let y = 0; y < left.value.length; y++) {
		const l = left.value[y].cells;
		const r = right.value[y].cells;
		if (l.length != r.length) { return false; }
		for (let x = 0; x < l.length; x++) {
			const same = l[x].cp == r[x].cp &&
				l[x].fg == r[x].fg &&
				l[x].bg == r[x].bg &&
				l[x].flags == r[x].flags &&
				l[x].underline == r[x].underline;
			if (!same) {
				console.log(`cell ${x},${y} differs`);
				return false;
			}
		}
	}
	return true;
}

function sameCursor(a: Vt, b: Vt): boolean {
	const left = a.cursor();
	const right = b.cursor();
	if (!left.ok || !right.ok) { return false; }
	const l = left.value;
	const r = right.value;
	if (l === null || r === null) { return l === null && r === null; }
	return l.x == r.x && l.y == r.y;
}

function sameModes(a: Vt, b: Vt): boolean {
	const left = a.modes();
	const right = b.modes();
	if (!left.ok || !right.ok) { return false; }
	const l = left.value;
	const r = right.value;
	return l.focusEvents == r.focusEvents &&
		l.bracketedPaste == r.bracketedPaste &&
		l.altScroll == r.altScroll &&
		l.cursorKeys == r.cursorKeys &&
		l.mouseTracking == r.mouseTracking &&
		l.win32Input == r.win32Input;
}

function topScrollbackLine(vt: Vt): string {
	vt.scrollTop();
	if (!vt.update().ok) { return "<unreadable>"; }
	const shown = vt.lines();
	if (!shown.ok) { return "<unreadable>"; }
	return shown.value[0];
}

const RED_BOLD = "\x1b[1;31mred\x1b[0m";
const TRUE_BG = "\x1b[48;2;10;20;30mbg\x1b[0m";

function scripted(vt: Vt): void {
	vt.writeText(linefeedLines(200));
	vt.writeText(`\r\n${RED_BOLD} ${TRUE_BG} \x1b[4:3;38;5;82mcurly\x1b[0m`);
	vt.writeText(`\r\n${"w".repeat(30)}`);
	vt.writeText("\r\nlast\x1b[2;5H\x1b[?2004h\x1b[?1h\x1b[?1004h");
}

test "a snapshot recreates screen, styles, cursor, scrollback and modes" {
	assert withVt(20, 6, (a: Vt): void => {
		scripted(a);
		assert restoredInto(a, (b: Vt): void => {
			assert sameLines(a, b);
			assert sameCells(a, b);
			assert sameCursor(a, b);
			assert sameModes(a, b);
			const modesB = b.modes();
			assert modesB.ok;
			if (modesB.ok) { assert modesB.value.bracketedPaste; }
			const kept = scrollbackRows(a);
			const restored = scrollbackRows(b);
			assert kept.ok && restored.ok;
			if (kept.ok && restored.ok) {
				assert kept.value > 190;
				assert restored.value == kept.value;
			}
			assert topScrollbackLine(b) == topScrollbackLine(a);
		});
	});
}

test "a soft-wrapped line stays one line after the snapshot" {
	assert withVt(20, 6, (a: Vt): void => {
		a.writeText(`head\r\n${"w".repeat(30)}\r\ntail`);
		assert restoredInto(a, (b: Vt): void => {
			assert a.resize(40, 6).ok;
			assert b.resize(40, 6).ok;
			assert a.update().ok;
			assert b.update().ok;
			assert sameLines(a, b);
			const shown = b.lines();
			assert shown.ok;
			if (shown.ok) { assert shown.value[1] == "w".repeat(30); }
		});
	});
}

test "over the alternate screen the frame travels and the primary under it does not" {
	assert withVt(20, 6, (a: Vt): void => {
		a.writeText(linefeedLines(50));
		a.writeText("\x1b[?1049h\x1b[2J\x1b[H\x1b[7m top bar \x1b[0m");
		a.writeText("\x1b[3;3H\x1b[32mbody\x1b[0m\x1b[6;1H\x1b[44mstatus\x1b[0m");
		a.writeText("\x1b[?1000h\x1b[?1006h\x1b[4;7H");
		assert restoredInto(a, (b: Vt): void => {
			const alt = b.alternateScreen();
			assert alt.ok;
			if (alt.ok) { assert alt.value; }
			assert sameLines(a, b);
			assert sameCells(a, b);
			assert sameCursor(a, b);
			assert sameModes(a, b);
			b.writeText("\x1b[?1049l");
			assert b.update().ok;
			const primary = b.lines();
			assert primary.ok;
			if (primary.ok) { assert primary.value[0] == ""; }
		});
	});
}

test "a title and working directory travel in the snapshot" {
	assert withVt(20, 4, (a: Vt): void => {
		a.writeText("\x1b]2;editing\x07\x1b]7;file://host/tmp/work\x07hi");
		assert restoredInto(a, (b: Vt): void => {
			const named = b.title();
			assert named.ok;
			if (named.ok) { assert named.value == "editing"; }
			const dir = b.pwd();
			assert dir.ok;
			if (dir.ok) { assert dir.value == "file://host/tmp/work"; }
		});
	});
}

test "an empty terminal snapshots to a terminal that matches it" {
	assert withVt(20, 4, (a: Vt): void => {
		assert restoredInto(a, (b: Vt): void => {
			assert sameLines(a, b);
			assert sameCursor(a, b);
			assert sameModes(a, b);
			const restored = scrollbackRows(b);
			assert restored.ok;
			if (restored.ok) { assert restored.value == 0; }
		});
	});
}

test "a terminal resized before the snapshot restores at its new size" {
	assert withVt(20, 6, (a: Vt): void => {
		scripted(a);
		assert a.resize(32, 8).ok;
		a.writeText("\r\nafter resize");
		assert restoredInto(a, (b: Vt): void => {
			const size = b.size();
			assert size.ok;
			if (size.ok) { assert size.value[0] == 32 && size.value[1] == 8; }
			assert sameLines(a, b);
			assert sameCells(a, b);
			assert sameCursor(a, b);
			assert topScrollbackLine(b) == topScrollbackLine(a);
		});
	});
}

function paletteEntry(vt: Vt, index: int32): Rgb {
	let colors: Colors256;
	const key = GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE;
	if (!checked(terminalGet(vt.terminal, key, colors), VtError.ReadFailed).ok) {
		return { r: 1, g: 1, b: 1 };
	}
	const c = colors.c[index];
	return { r: c.r, g: c.g, b: c.b };
}

test "colours a program set travel and the client's own palette stays" {
	assert withVt(20, 4, (a: Vt): void => {
		a.writeText("\x1b]4;1;rgb:12/34/56\x1b\\\x1b]11;rgb:01/02/03\x1b\\x");
		const shot = a.snapshot();
		assert shot.ok;
		if (!shot.ok) { return; }
		assert withVt(20, 4, (b: Vt): void => {
			const theme: Vec<Rgb> = [
				{ r: 0, g: 0, b: 0 },
				{ r: 0, g: 0, b: 0 },
				{ r: 7, g: 8, b: 9 },
			];
			assert b.setPalette(theme).ok;
			b.write(shot.value);
			assert b.update().ok;
			const set: Rgb = { r: 0x12, g: 0x34, b: 0x56 };
			assert paletteEntry(b, 1) == set;
			assert paletteEntry(b, 2) == theme[2];
			const colors = b.palette();
			assert colors.ok;
			const bg: Rgb = { r: 1, g: 2, b: 3 };
			if (colors.ok) { assert colors.value.bg == bg; }
		});
	});
}
