import { listInsert, listMove, listRemove } from "../../../neon/src/core/list";
import { scrollLines } from "../vt/vt";
import { Screen, ScreenError } from "./screen";

const WORDS: string[] = [
	"a", "hello", "x1", "TEST", "abc def", "中", "\u{1F600}", "e\u{301}", "क\u{94D}ष",
	"\t", "\b", "  ",
];
const SGRS: string[] = [
	"0", "1", "2", "3", "4", "4:3", "4:2", "7", "9", "22", "27", "31", "42", "93", "103",
	"38;5;200", "48;5;17", "38;2;10;200;30", "48;2;250;5;5", "39", "49",
];
const ERASES: string[] = ["J", "0J", "1J", "2J", "K", "0K", "1K", "2K"];

const LCG_MULTIPLIER: int64 = 1103515245;
const LCG_INCREMENT: int64 = 12345;
const LCG_MODULUS: int64 = 2147483648;
const LCG_LOW_BITS_DROPPED: int64 = 65536;

interface Rng { state: int64; }

function next(this r: Rng, n: int32): int32 {
	r.state = (r.state * LCG_MULTIPLIER + LCG_INCREMENT) % LCG_MODULUS;
	return ((r.state / LCG_LOW_BITS_DROPPED) % (n as int64)) as int32;
}

function pick(this r: Rng, list: string[]): string {
	return list[r.next(list.length as int32)];
}

function randomOp(r: Rng, cols: int32, rows: int32): string {
	return match (r.next(16)) {
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

function randomStream(seed: int32, cols: int32, rows: int32, ops: int32): string {
	const r: Rng = { state: seed as int64 };
	let out = "";
	for (let i = 0; i < ops; i++) { out += randomOp(r, cols, rows); }
	return out;
}

function failureAfter(s: Screen, painted: Result<void, ScreenError>): string {
	return painted.ok ? s.mismatch() : "a frame failed";
}

function reportFailure(run: string, failure: string, sent: string): void {
	if (failure == "") { return; }
	const visible = sent.replaceAll("\x1b", "<ESC>")
		.replaceAll("\r", "<CR>")
		.replaceAll("\n", "<LF>");
	console.log(`frames: ${run}: ${failure}`);
	console.log(`frames: bytes ${visible}`);
}

function playInChunks(seed: int32, cols: int32, rows: int32, ops: int32): string {
	const opened = Screen.open(cols, rows);
	if (!opened.ok) { return "open failed"; }
	const s = opened.value;
	const bytes = randomStream(seed, cols, rows, ops);
	const r: Rng = { state: (seed as int64) * 7 + 3 };
	const cut = 1 + r.next(40);
	const failure = failureAfter(s, s.feedChunks(bytes, cut));
	reportFailure(`seed ${seed} ${cols}x${rows} chunk ${cut}`, failure, bytes);
	s.close();
	return failure;
}

function playFramePerOp(seed: int32, cols: int32, rows: int32, ops: int32): string {
	const opened = Screen.open(cols, rows);
	if (!opened.ok) { return "open failed"; }
	const s = opened.value;
	const r: Rng = { state: seed as int64 };
	let failure = "";
	let sent = "";
	for (let i = 0; i < ops && failure == ""; i++) {
		const piece = randomOp(r, cols, rows);
		sent += piece;
		failure = failureAfter(s, s.feed(piece));
	}
	reportFailure(`seed ${seed} ${cols}x${rows} frame per op`, failure, sent);
	s.close();
	return failure;
}

test "a stream cut into frames anywhere paints what a fresh read of the vt shows" {
	for (let seed = 1; seed <= 150; seed++) {
		assert playInChunks(seed, 20, 6, 80) == "";
	}
}

test "a frame after every operation paints what a fresh read of the vt shows" {
	for (let seed = 1; seed <= 100; seed++) {
		assert playFramePerOp(seed, 12, 5, 60) == "";
	}
}

test "scroll-heavy streams on a tall narrow screen stay in step" {
	for (let seed = 1000; seed < 1060; seed++) {
		assert playInChunks(seed, 7, 12, 120) == "";
		assert playFramePerOp(seed, 7, 12, 60) == "";
	}
}

function playWithViewportAndResize(seed: int32, ops: int32): string {
	const opened = Screen.open(14, 6);
	if (!opened.ok) { return "open failed"; }
	const s = opened.value;
	const r: Rng = { state: seed as int64 };
	let failure = "";
	let sent = "";
	for (let i = 0; i < ops && failure == ""; i++) {
		let painted: Result<void, ScreenError> = Result.ok(null);
		match (r.next(10)) {
			0 => {
				const by = r.next(9) - 4;
				sent += `<scroll ${by}>`;
				s.vt.scrollLines(by);
				painted = s.paint();
			},
			1 => {
				const cols = 1 + r.next(20);
				const rows = 1 + r.next(10);
				sent += `<resize ${cols}x${rows}>`;
				painted = s.resize(cols, rows);
			},
			_ => {
				const piece = randomOp(r, s.cols, s.rows);
				sent += piece;
				painted = s.feed(piece);
			},
		}
		failure = failureAfter(s, painted);
	}
	reportFailure(`seed ${seed} viewport and resize`, failure, sent);
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
		defer s.close();
		assert s.feed("a\r\nb\r\nc\r\nd").ok;
		const q = s.grid.attach();
		assert s.feed("\r\ne\r\nf").ok;
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
	}
}
