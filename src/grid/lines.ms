import { fromCodePoint } from "std/core/string";
import { Cell, CellFlag, Cursor, Row, Rgb, Underline, Vt, isUnicodeScalar } from "../vt/vt";

export enum GridError {
	CodepointInvalid,
}

export struct LineRun {
	units: int32;
	fg: Rgb;
	bg: Rgb;
	underline: Underline;
	underlineColor: Rgb | null;
	bold: boolean;
	italic: boolean;
	strikethrough: boolean;
}

export struct GridLine {
	text: string;
	runs: Vec<LineRun>;
	cursorCell: int32;
}

function sameStyle(this a: LineRun, b: LineRun): boolean {
	return a.fg == b.fg &&
		a.bg == b.bg &&
		a.underline == b.underline &&
		a.underlineColor == b.underlineColor &&
		a.bold == b.bold &&
		a.italic == b.italic &&
		a.strikethrough == b.strikethrough;
}

const FAINT_OPACITY: float64 = 0.5;

function fadeChannel(fg: uint8, bg: uint8): uint8 {
	return Math.round(fg * FAINT_OPACITY + bg * (1 - FAINT_OPACITY)) as uint8;
}

function faded(fg: Rgb, bg: Rgb): Rgb {
	return { r: fadeChannel(fg.r, bg.r), g: fadeChannel(fg.g, bg.g), b: fadeChannel(fg.b, bg.b) };
}

function lineRun(this cell: Cell): LineRun {
	const inverse = cell.flags.has(CellFlag.Inverse);
	const fg = inverse ? cell.bg : cell.fg;
	const bg = inverse ? cell.fg : cell.bg;
	return {
		units: 0,
		fg: cell.flags.has(CellFlag.Faint) ? faded(fg, bg) : fg,
		bg: bg,
		underline: cell.underline,
		underlineColor: cell.underlineColor,
		bold: cell.flags.has(CellFlag.Bold),
		italic: cell.flags.has(CellFlag.Italic),
		strikethrough: cell.flags.has(CellFlag.Strikethrough),
	};
}

function isWideSpacer(this row: Row, i: int32): boolean {
	return row.cells[i].cp == 0 && i > 0 && row.cells[i - 1].flags.has(CellFlag.Wide);
}

function pushUnits(ref runs: Vec<LineRun>, run: LineRun, units: int32, split: boolean): void {
	const last = runs.length;
	if (!split && last > 0 && runs[last - 1].sameStyle(run)) {
		runs[last - 1].units += units;
		return;
	}
	runs.push({ ...run, units: units });
}

function isUnligatedPair(a: uint32, b: uint32): boolean {
	return (a == 0x66 && (b == 0x69 || b == 0x6C)) || (a == 0x73 && b == 0x74);
}

function breaksShapingBefore(this row: Row, i: int32, cursorCell: int32): boolean {
	const cell = row.cells[i];
	if (i == 0 || cell.extra != 0) { return false; }
	if (i == cursorCell || i == cursorCell + 1) { return true; }
	const prev = row.cells[i - 1];
	return prev.extra == 0 && isUnligatedPair(prev.cp, cell.cp);
}

function isEmpty(this cell: Cell, background: Rgb): boolean {
	const run = cell.lineRun();
	return (cell.cp == 0 || cell.cp == 0x20) && cell.extra == 0 && run.bg == background &&
		run.underline == Underline.None && !run.strikethrough;
}

export function cellOnRow(this cursor: Cursor | null, y: int32): int32 {
	return cursor !== null && cursor.y == y ? cursor.x : -1;
}

export function line(
	this row: Row,
	cursorCell: int32,
	background: Rgb,
): Result<GridLine, GridError> {
	let text = "";
	let runs: Vec<LineRun> = [];
	let extraAt = 0;
	let end = row.cells.length as int32;
	while (end > 0 && row.cells[end - 1].isEmpty(background)) { end--; }
	for (let i = 0; i < end; i++) {
		const cell = row.cells[i];
		const extra = cell.extra as int32;
		const extraStart = extraAt;
		extraAt += extra;
		if (row.isWideSpacer(i)) { continue; }
		const run = cell.lineRun();
		const split = row.breaksShapingBefore(i, cursorCell);
		if (cell.cp == 0) {
			text += " ";
			pushUnits(runs, run, 1, split);
			continue;
		}
		if (cell.flags.has(CellFlag.Invisible)) {
			const blank = cell.flags.has(CellFlag.Wide) ? "  " : " ";
			text += blank;
			const hidden: LineRun = { ...run, underline: Underline.None, strikethrough: false };
			pushUnits(runs, hidden, blank.length as int32, split);
			continue;
		}
		for (let k = 0; k <= extra; k++) {
			const cp = k == 0 ? cell.cp : row.extra[extraStart + k - 1];
			if (!isUnicodeScalar(cp)) { return Result.err(GridError.CodepointInvalid); }
			text += fromCodePoint(cp as number);
			pushUnits(runs, run, cp > 0xFFFF ? 2 : 1, split && k == 0);
		}
	}
	return Result.ok({ text: text, runs: runs, cursorCell: cursorCell });
}

function firstLine(text: string, cols: int32, cursorCell: int32): GridLine | null {
	const created = Vt.create(cols, 2);
	if (!created.ok) { return null; }
	const vt = created.value;
	vt.writeText(text);
	const updated = vt.update();
	const colors = vt.palette();
	const rows = vt.rows();
	let found: GridLine | null = null;
	if (updated.ok && colors.ok && rows.ok) {
		const line = rows.value[0].line(cursorCell, colors.value.bg);
		if (line.ok) { found = line.value; }
	}
	vt.free();
	return found;
}

test "a plain row is one run over its text, without the blank cells after it" {
	const line = firstLine("hello", 10, -1);
	assert line !== null;
	if (line !== null) {
		assert line.text == "hello";
		assert line.runs.length == 1;
		assert line.runs[0].units == 5;
		assert line.cursorCell == -1;
	}
}

test "each styled stretch is its own run" {
	const red: Rgb = { r: 255, g: 0, b: 0 };
	const line = firstLine("\x1b[1;38;2;255;0;0mA\x1b[0mb", 10, 0);
	assert line !== null;
	if (line !== null) {
		assert line.text == "Ab";
		assert line.runs.length == 2;
		assert line.runs[0].units == 1;
		assert line.runs[0].bold;
		assert line.runs[0].fg == red;
		assert line.runs[1].units == 1;
		assert !line.runs[1].bold;
		assert line.cursorCell == 0;
	}
}

test "underline kinds travel through, wavy as curly" {
	const line = firstLine("\x1b[4:2md\x1b[4:3mw\x1b[4:5mv", 20, -1);
	assert line !== null;
	if (line !== null) {
		assert line.runs[0].underline == Underline.Double;
		assert line.runs[1].underline == Underline.Curly;
		assert line.runs[2].underline == Underline.Dashed;
	}
}

test "a wide cell carries no spacer text and holds its run" {
	const line = firstLine("中a", 10, -1);
	assert line !== null;
	if (line !== null) {
		assert line.text == "中a";
		assert line.runs.length == 1;
		assert line.runs[0].units == 2;
	}
}

test "an erased line keeps its background as a run" {
	const red: Rgb = { r: 255, g: 0, b: 0 };
	const line = firstLine("\x1b[48;2;255;0;0m\x1b[K", 10, -1);
	assert line !== null;
	if (line !== null) {
		assert line.text == "          ";
		assert line.runs.length == 1;
		assert line.runs[0].units == 10;
		assert line.runs[0].bg == red;
	}
}

test "strikethrough is part of the run" {
	const line = firstLine("\x1b[9mx\x1b[0my", 10, -1);
	assert line !== null;
	if (line !== null) {
		assert line.runs[0].strikethrough;
		assert !line.runs[1].strikethrough;
	}
}

test "a concealed cell keeps its background and draws no text or line" {
	const line = firstLine("\x1b[8;4;9;41mab\x1b[0mc\x1b[8m\u4e2d", 10, -1);
	assert line !== null;
	if (line !== null) {
		assert line.text == "  c  ";
		const hidden = line.runs[0];
		assert hidden.units == 2;
		assert hidden.underline == Underline.None;
		assert !hidden.strikethrough;
		assert hidden.bg != line.runs[1].bg;
	}
}

test "a codepoint above the BMP is two UTF-16 units of its run" {
	const line = firstLine("a😀\x1b[1mb", 10, -1);
	assert line !== null;
	if (line !== null) {
		assert line.text == "a😀b";
		assert line.runs.length == 2;
		assert line.runs[0].units == 3;
		assert line.text.slice(0, 3) == "a😀";
		assert line.runs[1].bold;
	}
}

test "an inverse cell swaps its run's colours" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("\x1b[7mx\x1b[0my");
		assert vt.update().ok;
		const colors = vt.palette();
		const rows = vt.rows();
		assert colors.ok && rows.ok;
		if (colors.ok && rows.ok) {
			const line = rows.value[0].line(-1, colors.value.bg);
			assert line.ok;
			if (line.ok) {
				assert line.value.runs[0].fg == colors.value.bg;
				assert line.value.runs[0].bg == colors.value.fg;
				assert line.value.runs[1].fg == colors.value.fg;
			}
		}
		vt.free();
	}
}

test "a faint cell draws its foreground halfway to its background" {
	const line = firstLine("\x1b[2;38;2;200;100;0;48;2;0;0;100mx", 10, -1);
	assert line !== null;
	if (line !== null) {
		const fg = line.runs[0].fg;
		assert fg.r == 100 && fg.g == 50 && fg.b == 50;
		assert line.runs[0].bg.b == 100;
	}
}

test "a trailing blank that shows a background, an underline or a strikethrough stays" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("a   \r\nb\x1b[41m \x1b[0m\r\nc\x1b[4m \x1b[0m\r\nd\x1b[9m \x1b[0m");
		assert vt.update().ok;
		const colors = vt.palette();
		const rows = vt.rows();
		assert colors.ok && rows.ok;
		if (colors.ok && rows.ok) {
			let texts: Vec<string> = [];
			for (const row of rows.value) {
				const line = row.line(-1, colors.value.bg);
				assert line.ok;
				if (line.ok) { texts.push(line.value.text); }
			}
			assert texts.join("|") == "a|b |c |d ";
		}
		vt.free();
	}
}

function unitsOf(text: string, cursorCell: int32): string {
	const line = firstLine(text, 12, cursorCell);
	if (line === null) { return "no line"; }
	let out: string[] = [];
	for (const run of line.runs) { out.push(`${run.units}`); }
	return out.join(",");
}

test "the cursor's cell is a run of its own, so a ligature under it shows its parts" {
	assert unitsOf("a->b", -1) == "4";
	assert unitsOf("a->b", 2) == "2,1,1";
	assert unitsOf("a->b", 0) == "1,3";
}

test "fi, fl and st never share a run, so they stay unligated" {
	assert unitsOf("fifl", -1) == "1,2,1";
	assert unitsOf("ast", -1) == "2,1";
	assert unitsOf("ft", -1) == "2";
}
