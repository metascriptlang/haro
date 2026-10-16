export const VTEBENCH_COLS: int32 = 120;
export const VTEBENCH_ROWS: int32 = 40;
export const GHOSTTY_COLS: int32 = 120;
export const GHOSTTY_ROWS: int32 = 80;

const VTEBENCH_MIN_BYTES: int32 = 1048576;
const GHOSTTY_BYTES: int32 = 4194304;
const LETTERS: int32 = 26;
const FIRST_LETTER: int32 = 65;
const ALT_SCREEN = "\x1b[?1049h";

export const WORKLOAD_NAMES: string[] = [
	"cursor_motion",
	"dense_cells",
	"light_cells",
	"scrolling",
	"scrolling_fullscreen",
	"scrolling_top_region",
	"scrolling_bottom_region",
	"scrolling_top_small_region",
	"scrolling_bottom_small_region",
	"unicode",
	"ghosttyAscii",
	"ghosttyStyled",
	"ghosttyWideMix",
];

export struct Workload {
	name: string;
	cols: int32;
	rows: int32;
	setup: Vec<uint8>;
	payload: Vec<uint8>;
}

export enum WorkloadError {
	Unknown,
}

export function bytesOf(text: string): Vec<uint8> {
	let out: Vec<uint8> = [];
	putText(out, text);
	return out;
}

function putText(ref out: Vec<uint8>, text: string): void {
	const bytes = text.asBytes();
	for (let i = 0; i < (bytes.length as int32); i++) { out.push(bytes[i]); }
}

function putLineEnd(ref out: Vec<uint8>): void {
	out.push(13);
	out.push(10);
}

function putCodepoint(ref out: Vec<uint8>, cp: int32): void {
	if (cp < 0x80) {
		out.push(cp as uint8);
		return;
	}
	if (cp < 0x800) {
		out.push((0xC0 | (cp >> 6)) as uint8);
		out.push((0x80 | (cp & 0x3F)) as uint8);
		return;
	}
	if (cp < 0x10000) {
		out.push((0xE0 | (cp >> 12)) as uint8);
		out.push((0x80 | ((cp >> 6) & 0x3F)) as uint8);
		out.push((0x80 | (cp & 0x3F)) as uint8);
		return;
	}
	out.push((0xF0 | (cp >> 18)) as uint8);
	out.push((0x80 | ((cp >> 12) & 0x3F)) as uint8);
	out.push((0x80 | ((cp >> 6) & 0x3F)) as uint8);
	out.push((0x80 | (cp & 0x3F)) as uint8);
}

function repeatedTo(unit: Vec<uint8>, minBytes: int32): Vec<uint8> {
	const length = unit.length as int32;
	const count = (minBytes - 1) / length + 1;
	let out: Vec<uint8> = [];
	for (let n = 0; n < count; n++) {
		for (let i = 0; i < length; i++) { out.push(unit[i]); }
	}
	return out;
}

function moveAndPut(ref out: Vec<uint8>, line: int32, column: int32, letter: int32): void {
	putText(out, `\x1b[${line};${column}H`);
	out.push(letter as uint8);
}

function cursorMotion(cols: int32, rows: int32): Vec<uint8> {
	let out: Vec<uint8> = [];
	for (let letter = FIRST_LETTER; letter < FIRST_LETTER + LETTERS; letter++) {
		let columnStart = 1;
		let columnEnd = cols;
		let lineStart = 1;
		let lineEnd = rows;
		while (true) {
			let column = columnStart;
			let line = lineStart;
			while (column < columnEnd) {
				moveAndPut(out, line, column, letter);
				column++;
			}
			while (line < lineEnd) {
				moveAndPut(out, line, column, letter);
				line++;
			}
			while (column > columnStart) {
				moveAndPut(out, line, column, letter);
				column--;
			}
			while (line > lineStart) {
				moveAndPut(out, line, column, letter);
				line--;
			}
			columnStart++;
			lineStart++;
			columnEnd--;
			lineEnd--;
			if (columnStart > columnEnd || lineStart > lineEnd) { break; }
		}
	}
	return out;
}

function denseCells(cols: int32, rows: int32): Vec<uint8> {
	let out: Vec<uint8> = [];
	let offset = 0;
	for (let letter = FIRST_LETTER; letter < FIRST_LETTER + LETTERS; letter++) {
		putText(out, "\x1b[H");
		for (let line = 1; line <= rows; line++) {
			for (let column = 1; column <= cols; column++) {
				const index = line + column + offset;
				const fg = index % 156 + 100;
				const bg = 255 - index % 156 + 100;
				putText(out, `\x1b[38;5;${fg};48;5;${bg};1;3;4m`);
				out.push(letter as uint8);
			}
		}
		offset++;
	}
	return out;
}

function lightCells(cols: int32, rows: int32): Vec<uint8> {
	let out: Vec<uint8> = [];
	for (let letter = FIRST_LETTER; letter < FIRST_LETTER + LETTERS; letter++) {
		putText(out, "\x1b[H");
		for (let i = 0; i < cols * rows; i++) { out.push(letter as uint8); }
	}
	return out;
}

function scrollingUnit(): Vec<uint8> {
	return bytesOf("y\r\n");
}

function scrollingFullscreen(cols: int32): Vec<uint8> {
	let out: Vec<uint8> = [];
	for (let letter = FIRST_LETTER; letter < FIRST_LETTER + LETTERS; letter++) {
		for (let column = 0; column < cols; column++) { out.push(letter as uint8); }
		putLineEnd(out);
	}
	return out;
}

const UNICODE_RANGES: int32[] = [
	0xA1, 0x304, 0x370, 0x487, 0x48A, 0x595, 0x5BE, 0x604, 0x606, 0x614, 0x61B, 0x64F,
	0x660, 0x6DA, 0x6DE, 0x6E3, 0x6E5, 0x734, 0x74B, 0x7AA, 0x910, 0x945, 0x949, 0x955,
	0x958, 0xA36, 0x10A1, 0x1164, 0x1200, 0x167D, 0x1D00, 0x1DC4, 0x1DFA, 0x206A,
	0x2070, 0x20D4, 0x20F1, 0x28FF, 0x2E80, 0x9FEF, 0xAC00, 0xD7FB,
];
const EMOJI_FIRST: int32 = 0x1F600;
const EMOJI_LAST: int32 = 0x1F64F;

function unicodeSymbols(): Vec<uint8> {
	let out: Vec<uint8> = [];
	for (let r = 0; r < (UNICODE_RANGES.length as int32); r += 2) {
		for (let cp = UNICODE_RANGES[r]; cp <= UNICODE_RANGES[r + 1]; cp++) {
			putCodepoint(out, cp);
		}
	}
	putLineEnd(out);
	for (let cp = EMOJI_FIRST; cp <= EMOJI_LAST; cp++) { putCodepoint(out, cp); }
	putLineEnd(out);
	return out;
}

struct Rng { state: uint64; }

function nextBelow(ref rng: Rng, bound: int32): int32 {
	let x = rng.state;
	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	rng.state = x;
	return ((x >> 32) % (bound as uint64)) as int32;
}

function ghosttyAscii(bytes: int32): Vec<uint8> {
	let rng: Rng = { state: 42 };
	let out: Vec<uint8> = [];
	for (let i = 0; i < bytes; i++) { out.push((0x21 + nextBelow(rng, 94)) as uint8); }
	return out;
}

struct TextMix {
	styleRate: int32;
	graphemeRate: int32;
	weightOne: int32;
	weightTwo: int32;
	weightThree: int32;
}

const SGR_ATTRIBUTES: int32[] = [1, 3, 4, 7, 9];

function putSgr(ref out: Vec<uint8>, ref rng: Rng): void {
	const kind = nextBelow(rng, 8);
	if (kind == 0) {
		putText(out, "\x1b[0m");
	} else if (kind == 1) {
		const base = nextBelow(rng, 2) == 0 ? 30 : 90;
		putText(out, `\x1b[${base + nextBelow(rng, 8)}m`);
	} else if (kind == 2) {
		const base = nextBelow(rng, 2) == 0 ? 40 : 100;
		putText(out, `\x1b[${base + nextBelow(rng, 8)}m`);
	} else if (kind == 3) {
		putText(out, `\x1b[38;5;${nextBelow(rng, 256)}m`);
	} else if (kind == 4) {
		putText(out, `\x1b[48;5;${nextBelow(rng, 256)}m`);
	} else if (kind == 7) {
		putText(out, `\x1b[${SGR_ATTRIBUTES[nextBelow(rng, 5)]}m`);
	} else {
		const layer = kind == 5 ? 38 : 48;
		const r = nextBelow(rng, 6) * 51;
		const g = nextBelow(rng, 6) * 51;
		const b = nextBelow(rng, 6) * 51;
		putText(out, `\x1b[${layer};2;${r};${g};${b}m`);
	}
}

function putMixChar(ref out: Vec<uint8>, ref rng: Rng, mix: TextMix): void {
	const total = mix.weightOne + mix.weightTwo + mix.weightThree;
	const pick = nextBelow(rng, total);
	let cp = 0;
	if (pick < mix.weightOne) {
		cp = nextBelow(rng, 100) < 15 ? 0x20 : 0x21 + nextBelow(rng, 0x5E);
	} else if (pick < mix.weightOne + mix.weightTwo) {
		cp = 0xC0 + nextBelow(rng, 0x24F - 0xC0 + 1);
	} else if (nextBelow(rng, 2) == 0) {
		cp = 0x3041 + nextBelow(rng, 0x30FE - 0x3041 + 1);
	} else {
		cp = 0x4E00 + nextBelow(rng, 0x9FFF - 0x4E00 + 1);
	}
	putCodepoint(out, cp);
	if (mix.graphemeRate > 0 && nextBelow(rng, 1000) < mix.graphemeRate) {
		putCodepoint(out, 0x300 + nextBelow(rng, 0x70));
	}
}

function ghosttyStyled(bytes: int32, mix: TextMix): Vec<uint8> {
	let rng: Rng = { state: 42 };
	let out: Vec<uint8> = [];
	while ((out.length as int32) < bytes) {
		let remaining = 40 + nextBelow(rng, 41);
		let styled = false;
		while (remaining > 0) {
			if (mix.styleRate > 0 && nextBelow(rng, 1000) < mix.styleRate) {
				putSgr(out, rng);
				styled = true;
			}
			const run = Math.min(remaining, 4 + nextBelow(rng, 13));
			for (let i = 0; i < run; i++) { putMixChar(out, rng, mix); }
			remaining -= run;
		}
		if (styled) { putText(out, "\x1b[0m"); }
		putLineEnd(out);
	}
	return out;
}

export function buildWorkload(name: string): Result<Workload, WorkloadError> {
	const cols = VTEBENCH_COLS;
	const rows = VTEBENCH_ROWS;
	const none: Vec<uint8> = [];
	const w: Workload = match (name) {
		"cursor_motion" => ({
			name: name, cols: cols, rows: rows, setup: none,
			payload: cursorMotion(cols, rows),
		}),
		"dense_cells" => ({
			name: name, cols: cols, rows: rows, setup: bytesOf(ALT_SCREEN),
			payload: denseCells(cols, rows),
		}),
		"light_cells" => ({
			name: name, cols: cols, rows: rows, setup: bytesOf(ALT_SCREEN),
			payload: repeatedTo(lightCells(cols, rows), VTEBENCH_MIN_BYTES),
		}),
		"scrolling" => ({
			name: name, cols: cols, rows: rows, setup: none,
			payload: repeatedTo(scrollingUnit(), VTEBENCH_MIN_BYTES),
		}),
		"scrolling_fullscreen" => ({
			name: name, cols: cols, rows: rows, setup: none,
			payload: repeatedTo(scrollingFullscreen(cols), VTEBENCH_MIN_BYTES),
		}),
		"scrolling_top_region" => ({
			name: name, cols: cols, rows: rows,
			setup: bytesOf(`${ALT_SCREEN}\x1b[2;${rows}r`),
			payload: repeatedTo(scrollingUnit(), VTEBENCH_MIN_BYTES),
		}),
		"scrolling_bottom_region" => ({
			name: name, cols: cols, rows: rows,
			setup: bytesOf(`${ALT_SCREEN}\x1b[1;${rows - 1}r`),
			payload: repeatedTo(scrollingUnit(), VTEBENCH_MIN_BYTES),
		}),
		"scrolling_top_small_region" => ({
			name: name, cols: cols, rows: rows,
			setup: bytesOf(`${ALT_SCREEN}\x1b[${rows / 2};${rows}r`),
			payload: repeatedTo(scrollingUnit(), VTEBENCH_MIN_BYTES),
		}),
		"scrolling_bottom_small_region" => ({
			name: name, cols: cols, rows: rows,
			setup: bytesOf(`${ALT_SCREEN}\x1b[1;${rows / 2}r`),
			payload: repeatedTo(scrollingUnit(), VTEBENCH_MIN_BYTES),
		}),
		"unicode" => ({
			name: name, cols: cols, rows: rows, setup: bytesOf(ALT_SCREEN),
			payload: repeatedTo(unicodeSymbols(), VTEBENCH_MIN_BYTES),
		}),
		"ghosttyAscii" => ({
			name: name, cols: GHOSTTY_COLS, rows: GHOSTTY_ROWS, setup: none,
			payload: ghosttyAscii(GHOSTTY_BYTES),
		}),
		"ghosttyStyled" => ({
			name: name, cols: GHOSTTY_COLS, rows: GHOSTTY_ROWS, setup: none,
			payload: ghosttyStyled(GHOSTTY_BYTES, {
				styleRate: 800, graphemeRate: 0, weightOne: 1, weightTwo: 0, weightThree: 0,
			}),
		}),
		"ghosttyWideMix" => ({
			name: name, cols: GHOSTTY_COLS, rows: GHOSTTY_ROWS, setup: none,
			payload: ghosttyStyled(GHOSTTY_BYTES, {
				styleRate: 0, graphemeRate: 100, weightOne: 0, weightTwo: 1, weightThree: 2,
			}),
		}),
		_ => ({ name: "", cols: 0, rows: 0, setup: none, payload: none }),
	};
	if (w.cols == 0) { return Result.err(WorkloadError.Unknown); }
	return Result.ok(w);
}

test "light cells fill the grid once per letter and home the cursor before each" {
	const payload = lightCells(4, 3);
	assert payload.length == 26 * (3 + 12);
	assert payload[0] == 27 && payload[3] == 65 && payload[15] == 27 && payload[18] == 66;
}

test "dense cells carry the 256-colour pair and the three attributes on every cell" {
	const payload = denseCells(2, 1);
	const text = "\x1b[H\x1b[38;5;102;48;5;353;1;3;4mA\x1b[38;5;103;48;5;352;1;3;4mA";
	for (let i = 0; i < text.byteLength; i++) {
		assert payload[i] == text.asBytes()[i];
	}
}

test "cursor motion walks the ring of a 3x2 grid" {
	const payload = cursorMotion(3, 2);
	const first = "\x1b[1;1HA\x1b[1;2HA\x1b[1;3HA\x1b[2;3HA\x1b[2;2HA\x1b[2;1HA";
	for (let i = 0; i < first.byteLength; i++) {
		assert payload[i] == first.asBytes()[i];
	}
}

test "a scrolling payload reaches the vtebench minimum with whole units" {
	const payload = repeatedTo(scrollingUnit(), 10);
	assert payload.length == 12;
	assert payload[0] == 121 && payload[1] == 13 && payload[2] == 10 && payload[3] == 121;
}

test "the unicode payload holds the vtebench symbols, its emoji and two line ends" {
	const payload = unicodeSymbols();
	assert payload.length == 138296 + 2;
}

test "the generated text is the same for every call and ends every line in CR LF" {
	const mix: TextMix = {
		styleRate: 800, graphemeRate: 100, weightOne: 1, weightTwo: 1, weightThree: 1,
	};
	const a = ghosttyStyled(4096, mix);
	const b = ghosttyStyled(4096, mix);
	assert a.length == b.length && a.length >= 4096;
	for (let i = 0; i < (a.length as int32); i++) { assert a[i] == b[i]; }
	const last = a.length as int32;
	assert a[last - 2] == 13 && a[last - 1] == 10;
}

test "the ascii stream holds only printable bytes other than space" {
	const payload = ghosttyAscii(2048);
	assert payload.length == 2048;
	for (let i = 0; i < 2048; i++) { assert payload[i] >= 0x21 && payload[i] <= 0x7E; }
}

test "a workload names its grid and an unknown name is an error" {
	const known = buildWorkload("scrolling_top_region");
	assert known.ok;
	if (known.ok) {
		assert known.value.cols == 120 && known.value.rows == 40;
		assert known.value.setup.length == 8 + 7;
	}
	assert !buildWorkload("nope").ok;
}
