import { GhosttyPointTag, GhosttyTrackedGridRef } from "../../vendor/ghostty/include/ghostty/vt.h";
import {
	Rgb,
	SCROLLBACK_LINES,
	Vt,
	VtError,
	create,
	free,
	holdLimit,
	holding,
	lines,
	resize,
	scrollTop,
	setPalette,
	setPullScrollback,
	setScrollback,
	size,
	takeReplies,
	title,
	update,
	write,
	writeText,
} from "./vt";
import { ok, vtTrack } from "./vtNative";
import {
	numberedLines,
	topLine,
	withVt,
	writeBroken,
} from "./vtRig";

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

test "an untitled terminal has an empty title" {
	assert withVt(20, 4, (vt: Vt): void => {
		const title = vt.title();
		assert title.ok;
		if (title.ok) { assert title.value == ""; }
	});
}

test "a pwd with invalid UTF-8 reads back as well-formed text" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeBroken("\x1b]7;file:///a", "b\x07");
		const pwd = vt.pwd();
		assert pwd.ok;
		if (pwd.ok) { assert pwd.value == "file:///a\u{fffd}b"; }
	});
}

test "a title with invalid UTF-8 reads back as well-formed text" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeBroken("\x1b]2;a", "b\x07");
		const title = vt.title();
		assert title.ok;
		if (title.ok) { assert title.value == "" || title.value == "a\u{fffd}b"; }
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

function rowsAfterGrowing(pull: boolean): string {
	const created = Vt.create(10, 3);
	if (!created.ok) { return "create failed"; }
	const vt = created.value;
	defer vt.free();
	vt.setPullScrollback(pull);
	vt.writeText("l1\r\nl2\r\nl3\r\nl4\r\nl5");
	vt.resize(10, 5);
	vt.update();
	const lines = vt.lines();
	if (!lines.ok) { return "read failed"; }
	return lines.value.join("|");
}

function keptAfter(lines: int32, keep: int64): int32 {
	const created = Vt.create(20, 4);
	if (!created.ok) { return -1; }
	const vt = created.value;
	defer vt.free();
	if (keep != SCROLLBACK_LINES && !vt.setScrollback(keep).ok) { return -1; }
	vt.writeText(numberedLines(lines));
	vt.scrollTop();
	if (!vt.update().ok) { return -1; }
	const oldest = vt.topLine();
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

test "text without a query leaves nothing to reply" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("hello");
		assert vt.takeReplies().length == 0;
	});
}

test "a grid size outside 1 to 65535 is refused instead of wrapping into another size" {
	assert !Vt.create(0, 24).ok;
	assert !Vt.create(80, 0).ok;
	assert !Vt.create(-1, 24).ok;
	assert !Vt.create(70000, 24).ok;
	assert !Vt.create(80, 65536).ok;
	assert withVt(20, 4, (vt: Vt): void => {
		assert !vt.resize(0, 4).ok;
		assert !vt.resize(20, -3).ok;
		assert !vt.resize(65536, 4).ok;
		assert vt.update().ok;
		const size = vt.size();
		assert size.ok;
		if (size.ok) {
			assert size.value[0] == 20;
			assert size.value[1] == 4;
		}
	});
}

test "a palette of more than 256 colours is refused by its own error" {
	assert withVt(20, 4, (vt: Vt): void => {
		let colors: Vec<Rgb> = [];
		for (let i = 0; i < 257; i++) { colors.push({ r: 1, g: 2, b: 3 }); }
		const refused = vt.setPalette(colors);
		assert !refused.ok;
		if (!refused.ok) { assert refused.error == VtError.PaletteTooLong; }
		assert vt.setPalette(colors[0..256]).ok;
	});
}

