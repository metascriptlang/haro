import { listInsert, listMove, listRemove } from "../../../neon/src/core/list";
import { Vt } from "../vt/vt";
import { Screen } from "./screen";

const WORDS: string[] = ["a", "hello", "x1", "TEST", "abc def", "中", "\u{1F600}", "e\u{301}", "क\u{94D}ष", "\t", "\b", "  "];
const SGRS: string[] = ["0", "1", "2", "3", "4", "4:3", "4:2", "7", "9", "22", "27", "31", "42", "93", "103", "38;5;200", "48;5;17", "38;2;10;200;30", "48;2;250;5;5", "39", "49"];
const MODES: string[] = [
	"\x1b[?7l", "\x1b[?7h", "\x1b[?6h", "\x1b[?6l", "\x1b[4h", "\x1b[4l", "\x1b[20h", "\x1b[20l",
	"\x1b[?2027h", "\x1b[?2027l", "\x1b[?69h", "\x1b[?69l", "\x1b7", "\x1b8", "\x1bH", "\x1b[0g", "\x1b[3g",
	"\x1b(0", "\x1b(B", "\x0e", "\x0f", "\x1b[!p", "\x1bc", "\x1b#8", "\x1b[?47h", "\x1b[?47l", "\x1b[?1047h", "\x1b[?1047l",
	"\x1b[1;3s", "\x1b[?40h", "\x1b[?3l", "\x1b[?3h", "\x1b[?25l", "\x1b[?25h", "\x1b[?2004h", "\x1b[0;1;2;3;4;7;9m",
];
const ERASES: string[] = ["J", "0J", "1J", "2J", "K", "0K", "1K", "2K"];

interface Rng { state: int64; }

function next(this r: Rng, n: int32): int32 {
	r.state = (r.state * 1103515245 + 12345) % 2147483648;
	return ((r.state / 65536) % (n as int64)) as int32;
}

function pick(this r: Rng, list: string[]): string {
	return list[r.next(list.length as int32)];
}

function op(r: Rng, cols: int32, rows: int32): string {
	const kind = r.next(16);
	return match (kind) {
		0 | 1 | 2 => r.pick(WORDS),
		3 => "\r\n",
		4 => "\n",
		5 => `\x1b[${1 + r.next(rows + 2)};${1 + r.next(cols + 2)}H`,
		6 => `\x1b[${r.pick(SGRS)}m`,
		7 => `\x1b[${r.pick(ERASES)}`,
		8 => r.next(3) == 0 ? "\x1b[r" : `\x1b[${1 + r.next(rows)};${1 + r.next(rows)}r`,
		9 => `\x1b[${1 + r.next(3)}${r.next(2) == 0 ? "L" : "M"}`,
		10 => r.pick(["\x1bD", "\x1bM", "\x1bE"]),
		11 => r.next(4) == 0 ? "\x1b[?1049h" : (r.next(3) == 0 ? "\x1b[?1049l" : "z"),
		12 => `\x1b[${1 + r.next(4)}${r.pick(["@", "P", "X", "S", "T"])}`,
		13 => "\r\n".repeat(1 + r.next(rows * 2)),
		14 => `\x1b[${r.pick(["A", "B", "C", "D"])}`,
		_ => r.pick(WORDS),
	};
}

function stream(seed: int32, cols: int32, rows: int32, ops: int32): string {
	let r: Rng = { state: seed as int64 };
	let out = "";
	for (let i = 0; i < ops; i++) { out += op(r, cols, rows); }
	return out;
}

function playSeed(seed: int32, cols: int32, rows: int32, ops: int32): string {
	const opened = Screen.open(cols, rows);
	if (!opened.ok) { return "open failed"; }
	const s = opened.value;
	const bytes = stream(seed, cols, rows, ops);
	let r: Rng = { state: (seed as int64) * 7 + 3 };
	let failure = "";
	const cut = 1 + r.next(40);
	if (!s.feedChunks(bytes, cut)) { failure = "a frame failed"; }
	if (failure == "") {
		const m = s.mismatch();
		if (m != "") { failure = m; }
	}
	if (failure != "") {
		console.log(`frames: seed ${seed} ${cols}x${rows} chunk ${cut}: ${failure}`);
		console.log(`frames: bytes ${bytes.replaceAll("\x1b", "<ESC>").replaceAll("\r", "<CR>").replaceAll("\n", "<LF>")}`);
	}
	s.close();
	return failure;
}

function playEveryFrame(seed: int32, cols: int32, rows: int32, ops: int32): string {
	const opened = Screen.open(cols, rows);
	if (!opened.ok) { return "open failed"; }
	const s = opened.value;
	let r: Rng = { state: seed as int64 };
	let failure = "";
	let sent = "";
	for (let i = 0; i < ops && failure == ""; i++) {
		const piece = op(r, cols, rows);
		sent += piece;
		if (!s.feed(piece)) {
			failure = "a frame failed";
		} else {
			const m = s.mismatch();
			if (m != "") { failure = m; }
		}
	}
	if (failure != "") {
		console.log(`frames: seed ${seed} ${cols}x${rows} frame per op: ${failure}`);
		console.log(`frames: bytes ${sent.replaceAll("\x1b", "<ESC>").replaceAll("\r", "<CR>").replaceAll("\n", "<LF>")}`);
	}
	s.close();
	return failure;
}

test "a stream cut into frames anywhere paints what a fresh read of the vt shows" {
	for (let seed = 1; seed <= 150; seed++) {
		assert playSeed(seed, 20, 6, 80) == "";
	}
}

test "a frame after every operation paints what a fresh read of the vt shows" {
	for (let seed = 1; seed <= 100; seed++) {
		assert playEveryFrame(seed, 12, 5, 60) == "";
	}
}

test "scroll-heavy streams on a tall narrow screen stay in step" {
	for (let seed = 1000; seed < 1060; seed++) {
		assert playSeed(seed, 7, 12, 120) == "";
		assert playEveryFrame(seed, 7, 12, 60) == "";
	}
}

function playWithViewportAndResize(seed: int32, ops: int32): string {
	const opened = Screen.open(14, 6);
	if (!opened.ok) { return "open failed"; }
	const s = opened.value;
	let r: Rng = { state: seed as int64 };
	let failure = "";
	let sent = "";
	for (let i = 0; i < ops && failure == ""; i++) {
		let ok = true;
		const kind = r.next(10);
		if (kind == 0) {
			const by = r.next(9) - 4;
			sent += `<scroll ${by}>`;
			const vt: Vt = s.vt;
			vt.scrollLines(by);
			ok = s.paint();
		} else if (kind == 1) {
			const cols = 1 + r.next(20);
			const rows = 1 + r.next(10);
			sent += `<resize ${cols}x${rows}>`;
			ok = s.resize(cols, rows);
		} else {
			const piece = op(r, s.cols, s.rows);
			sent += piece;
			ok = s.feed(piece);
		}
		if (!ok) { failure = "a frame failed"; }
		const m = ok ? s.mismatch() : "";
		if (m != "") { failure = m; }
	}
	if (failure != "") {
		console.log(`frames: seed ${seed} viewport and resize: ${failure}`);
		console.log(`frames: bytes ${sent.replaceAll("\x1b", "<ESC>").replaceAll("\r", "<CR>").replaceAll("\n", "<LF>")}`);
	}
	s.close();
	return failure;
}

test "scrolling the viewport and resizing between operations keeps the grid in step" {
	for (let seed = 1; seed <= 150; seed++) {
		assert playWithViewportAndResize(seed, 70) == "";
	}
}

test "a scroll moves the rows it keeps and builds none" {
	const opened = Screen.open(10, 4);
	assert opened.ok;
	if (opened.ok) {
		const s = opened.value;
		assert s.feed("a\r\nb\r\nc\r\nd");
		const q = s.grid.attach();
		assert s.feed("\r\ne\r\nf");
		let built = 0;
		let moved = 0;
		for (const o of q.ops) {
			if (o.kind == listInsert || o.kind == listRemove) { built++; }
			if (o.kind == listMove) { moved++; }
		}
		assert built == 0;
		assert moved == 2;
		assert s.lines() == "c\nd\ne\nf";
		assert s.mismatch() == "";
		s.grid.detach(q);
		s.close();
	}
}
