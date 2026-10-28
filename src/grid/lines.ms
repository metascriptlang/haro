import { fromCodePoint } from "std/core/string";
import { Marked, RowSpan } from "../select/select";
import {
	Cell,
	CellFlag,
	Cursor,
	Grapheme,
	Row,
	Rgb,
	Underline,
	Vt,
	graphemes,
	isUnicodeScalar,
} from "../vt/vt";

export enum GridError {
	CodepointInvalid,
}

export struct LineRun {
	units: int32;
	fg: Rgb;
	bg: Rgb;
	underline: Underline;
	underlineColor: Rgb | null;
	flags: BitSet<CellFlag>;
}

const LINE_FLAGS: BitSet<CellFlag> = CellFlag.Strikethrough | CellFlag.Overline;
const RUN_FLAGS: BitSet<CellFlag> = LINE_FLAGS | CellFlag.Bold | CellFlag.Italic;

export struct CellInk {
	fg: Rgb | null;
	bg: Rgb | null;
}

export struct RowTint {
	fg: Rgb | null;
	bg: Rgb | null;
}

export struct RowNote {
	text: string;
	fg: Rgb | null;
	bg: Rgb | null;
}

export struct GridLine {
	text: string;
	runs: Vec<LineRun>;
	widths: uint8[];
	cursorCell: int32;
	cursorInk: CellInk | null;
}

function sameStyle(this a: LineRun, b: LineRun): boolean {
	return a.fg == b.fg &&
		a.bg == b.bg &&
		a.underline == b.underline &&
		a.underlineColor == b.underlineColor &&
		a.flags == b.flags;
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
		flags: cell.flags.intersection(RUN_FLAGS),
	};
}

function inked(this run: LineRun, ink: CellInk): LineRun {
	return { ...run, fg: ink.fg ?? run.bg, bg: ink.bg ?? run.fg };
}

function tinted(this run: LineRun, tint: RowTint): LineRun {
	return { ...run, fg: tint.fg ?? run.fg, bg: tint.bg ?? run.bg };
}

function covers(this selected: RowSpan | null, from: int32, to: int32): boolean {
	return selected !== null && selected.from <= to && from <= selected.to;
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

function utf8Bytes(cp: uint32): int32 {
	return cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
}

function pushCell(ref widths: uint8[], cells: uint8, bytes: int32): void {
	widths.push(cells);
	for (let b = 1; b < bytes; b++) { widths.push(0); }
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
		run.underline == Underline.None && run.flags.isDisjointFrom(LINE_FLAGS);
}

struct Placed {
	at: int32;
	graphemes: Vec<Grapheme>;
}

const NOTE_GAP = 1;

function placed(this note: RowNote | null, count: int32, own: int32): Placed | null {
	if (note === null) { return null; }
	const parts = graphemes(note.text);
	let cells = 0;
	for (const g of parts) { cells += g.cells; }
	const at = count - cells;
	if (cells == 0 || at < own + (own > 0 ? NOTE_GAP : 0)) { return null; }
	return { at: at, graphemes: parts };
}

function noted(this run: LineRun, note: RowNote): LineRun {
	return {
		...run,
		fg: note.fg ?? faded(run.fg, run.bg),
		bg: note.bg ?? run.bg,
		underline: Underline.None,
		underlineColor: null,
		flags: 0 as BitSet<CellFlag>,
	};
}

export function cellOnRow(this cursor: Cursor | null, y: int32): int32 {
	return cursor !== null && cursor.y == y ? cursor.x : -1;
}

export function line(
	this row: Row,
	cursorCell: int32,
	cursorInk: CellInk | null,
	selection: CellInk,
	background: Rgb,
	tint: RowTint | null = null,
	note: RowNote | null = null,
): Result<GridLine, GridError> {
	let text = "";
	let runs: Vec<LineRun> = [];
	let widths: uint8[] = [];
	let extraAt = 0;
	const count = row.cells.length as int32;
	const cursorAt = cursorCell > 0 && cursorCell < count && row.isWideSpacer(cursorCell)
		? cursorCell - 1
		: cursorCell;
	const selected = row.selected;
	let end = count;
	while (end > 0 && row.cells[end - 1].isEmpty(background)) { end--; }
	if (cursorInk !== null) { end = Math.max(end, Math.min(cursorAt + 1, count)); }
	const placedNote = note.placed(count, end);
	if (selected !== null) { end = Math.max(end, Math.min(selected.to + 1, count)); }
	if (tint !== null && tint.bg !== null) { end = count; }
	if (placedNote !== null) { end = placedNote.at; }
	for (let i = 0; i < end; i++) {
		const cell = row.cells[i];
		const extra = cell.extra as int32;
		const extraStart = extraAt;
		extraAt += extra;
		if (row.isWideSpacer(i)) { continue; }
		const last = cell.flags.has(CellFlag.Wide) ? i + 1 : i;
		let run = cell.lineRun();
		if (tint !== null) { run = run.tinted(tint); }
		if (i == cursorAt && cursorInk !== null) {
			run = run.inked(cursorInk);
		} else if (selected.covers(i, last)) {
			run = run.inked(selection);
		}
		const split = row.breaksShapingBefore(i, cursorAt);
		if (cell.cp == 0) {
			text += " ";
			pushUnits(runs, run, 1, split);
			pushCell(widths, 1, 1);
			continue;
		}
		if (cell.flags.has(CellFlag.Invisible)) {
			const blank = cell.flags.has(CellFlag.Wide) ? "  " : " ";
			text += blank;
			for (let b = 0; b < blank.length; b++) { pushCell(widths, 1, 1); }
			const hidden: LineRun = {
				...run,
				underline: Underline.None,
				flags: run.flags.difference(LINE_FLAGS),
			};
			pushUnits(runs, hidden, blank.length as int32, split);
			continue;
		}
		const cells: uint8 = cell.flags.has(CellFlag.Wide) ? 2 : 1;
		for (let k = 0; k <= extra; k++) {
			const cp = k == 0 ? cell.cp : row.extra[extraStart + k - 1];
			if (!isUnicodeScalar(cp)) { return Result.err(GridError.CodepointInvalid); }
			text += fromCodePoint(cp as number);
			pushCell(widths, k == 0 ? cells : 0, utf8Bytes(cp));
			pushUnits(runs, run, cp > 0xFFFF ? 2 : 1, split && k == 0);
		}
	}
	if (placedNote !== null && note !== null) {
		let at = placedNote.at;
		for (const g of placedNote.graphemes) {
			let run = row.cells[at].lineRun();
			if (tint !== null) { run = run.tinted(tint); }
			run = run.noted(note);
			if (selected.covers(at, at + g.cells - 1)) { run = run.inked(selection); }
			text += g.text;
			pushCell(widths, g.cells as uint8, g.text.byteLength() as int32);
			pushUnits(runs, run, g.text.length as int32, at == placedNote.at);
			at += g.cells;
		}
	}
	return Result.ok({
		text: text,
		runs: runs,
		widths: widths,
		cursorCell: cursorCell,
		cursorInk: cursorInk,
	});
}

const SWAP: CellInk = { fg: null, bg: null };
const RED: Rgb = { r: 255, g: 0, b: 0 };

function inkedLine(
	text: string,
	cols: int32,
	cursorCell: int32,
	cursorInk: CellInk | null,
	selected: Marked | null,
): GridLine | null {
	const created = Vt.create(cols, 2);
	if (!created.ok) { return null; }
	const vt = created.value;
	defer vt.free();
	vt.writeText(text);
	const marked = selected === null || vt.selectionSet(selected).ok;
	const updated = vt.update();
	const colors = vt.palette();
	const rows = vt.rows();
	let found: GridLine | null = null;
	if (marked && updated.ok && colors.ok && rows.ok) {
		const line = rows.value[0].line(cursorCell, cursorInk, SWAP, colors.value.bg);
		if (line.ok) { found = line.value; }
	}
	return found;
}

function tintedLine(
	text: string,
	cols: int32,
	cursorCell: int32,
	selected: Marked | null,
	tint: RowTint | null,
	note: RowNote | null = null,
): GridLine | null {
	const created = Vt.create(cols, 2);
	if (!created.ok) { return null; }
	const vt = created.value;
	defer vt.free();
	vt.writeText(text);
	const marked = selected === null || vt.selectionSet(selected).ok;
	const updated = vt.update();
	const colors = vt.palette();
	const rows = vt.rows();
	let found: GridLine | null = null;
	if (marked && updated.ok && colors.ok && rows.ok) {
		const cursorInk: CellInk = { fg: null, bg: RED };
		const line = rows.value[0].line(cursorCell, cursorInk, SWAP, colors.value.bg, tint, note);
		if (line.ok) { found = line.value; }
	}
	return found;
}

function firstLine(text: string, cols: int32, cursorCell: int32): GridLine | null {
	return inkedLine(text, cols, cursorCell, null, null);
}

function columns(from: int32, to: int32): Marked {
	return { range: { start: { row: 0, col: from }, end: { row: 0, col: to } }, block: false };
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
	const line = firstLine("\x1b[1;38;2;255;0;0mA\x1b[0mb", 10, 0);
	assert line !== null;
	if (line !== null) {
		assert line.text == "Ab";
		assert line.runs.length == 2;
		assert line.runs[0].units == 1;
		assert line.runs[0].flags.has(CellFlag.Bold);
		assert line.runs[0].fg == RED;
		assert line.runs[1].units == 1;
		assert !line.runs[1].flags.has(CellFlag.Bold);
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

test "each cell gives its width at its first UTF-8 byte and 0 after, so a wide cell takes two" {
	const line = firstLine("你好a😀 e\u0301", 20, -1);
	assert line !== null;
	if (line !== null) {
		assert line.widths.join("") == "200200120001100", "widths: " + line.widths.join("");
	}
}

test "a concealed wide cell is two blank cells of width 1" {
	const line = firstLine("\x1b[8m\u4e2d", 10, -1);
	assert line !== null;
	if (line !== null) { assert line.widths.join("") == "11", "widths: " + line.widths.join(""); }
}

test "an erased line keeps its background as a run" {
	const line = firstLine("\x1b[48;2;255;0;0m\x1b[K", 10, -1);
	assert line !== null;
	if (line !== null) {
		assert line.text == "          ";
		assert line.runs.length == 1;
		assert line.runs[0].units == 10;
		assert line.runs[0].bg == RED;
	}
}

test "strikethrough is part of the run" {
	const line = firstLine("\x1b[9mx\x1b[0my", 10, -1);
	assert line !== null;
	if (line !== null) {
		assert line.runs[0].flags.has(CellFlag.Strikethrough);
		assert !line.runs[1].flags.has(CellFlag.Strikethrough);
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
		assert !hidden.flags.has(CellFlag.Strikethrough);
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
		assert line.runs[1].flags.has(CellFlag.Bold);
	}
}

test "an inverse cell swaps its run's colours" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		defer vt.free();
		vt.writeText("\x1b[7mx\x1b[0my");
		assert vt.update().ok;
		const colors = vt.palette();
		const rows = vt.rows();
		assert colors.ok && rows.ok;
		if (colors.ok && rows.ok) {
			const line = rows.value[0].line(-1, null, SWAP, colors.value.bg);
			assert line.ok;
			if (line.ok) {
				assert line.value.runs[0].fg == colors.value.bg;
				assert line.value.runs[0].bg == colors.value.fg;
				assert line.value.runs[1].fg == colors.value.fg;
			}
		}
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
		defer vt.free();
		vt.writeText("a   \r\nb\x1b[41m \x1b[0m\r\nc\x1b[4m \x1b[0m\r\nd\x1b[9m \x1b[0m");
		assert vt.update().ok;
		const colors = vt.palette();
		const rows = vt.rows();
		assert colors.ok && rows.ok;
		if (colors.ok && rows.ok) {
			let texts: Vec<string> = [];
			for (const row of rows.value) {
				const line = row.line(-1, null, SWAP, colors.value.bg);
				assert line.ok;
				if (line.ok) { texts.push(line.value.text); }
			}
			assert texts.join("|") == "a|b |c |d ";
		}
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

test "a lit block cursor draws its cell in the cursor colour, its text in the cell's background" {
	const line = inkedLine("abc", 10, 1, { fg: null, bg: RED }, null);
	assert line !== null;
	if (line !== null) {
		assert line.runs.length == 3;
		assert line.runs[1].units == 1;
		assert line.runs[1].bg == RED;
		assert line.runs[1].fg == line.runs[0].bg;
		assert line.runs[2].bg == line.runs[0].bg;
		assert line.cursorInk !== null;
	}
}

test "a lit cursor past the end of the text still draws its cell, and an unlit one adds nothing" {
	const lit = inkedLine("ab", 10, 4, { fg: null, bg: RED }, null);
	assert lit !== null;
	if (lit !== null) {
		assert lit.text == "ab   ";
		assert lit.runs[lit.runs.length - 1].bg == RED;
		assert lit.runs[lit.runs.length - 1].units == 1;
	}
	const unlit = firstLine("ab", 10, 4);
	assert unlit !== null;
	if (unlit !== null) { assert unlit.text == "ab"; }
}

test "a lit cursor on either cell of a wide character inks the whole character" {
	for (let at = 0; at < 2; at++) {
		const line = inkedLine("中a", 10, at, { fg: null, bg: RED }, null);
		assert line !== null;
		if (line !== null) {
			assert line.runs[0].units == 1;
			assert line.runs[0].bg == RED;
			assert line.runs[1].bg != RED;
			assert line.widths.join("") == "2001";
		}
	}
}

test "selected cells swap their colours, so an inverse cell selects back to plain" {
	const line = inkedLine("ab\x1b[7mc\x1b[0md", 10, -1, null, columns(1, 2));
	assert line !== null;
	if (line !== null) {
		assert line.runs.length == 3;
		assert line.runs[1].units == 1;
		assert line.runs[1].fg == line.runs[0].bg;
		assert line.runs[1].bg == line.runs[0].fg;
		assert line.runs[2].units == 2;
		assert line.runs[2].bg == line.runs[0].bg;
	}
}

test "a selection reaching either cell of a wide character colours it whole" {
	for (let from = 0; from < 2; from++) {
		const line = inkedLine("中文 x", 10, -1, null, columns(from, 2));
		assert line !== null;
		if (line !== null) {
			assert line.runs.length == 2;
			assert line.runs[0].units == 2;
			assert line.runs[0].bg == line.runs[1].fg;
		}
	}
}

test "selected blanks past the text are drawn, up to the last column" {
	const line = inkedLine("x", 6, -1, null, columns(3, 5));
	assert line !== null;
	if (line !== null) {
		assert line.text == "x     ";
		assert line.runs.length == 2;
		assert line.runs[1].units == 3;
		assert line.runs[1].bg == line.runs[0].fg;
	}
}

test "the cursor's ink wins over the selection on its cell" {
	const line = inkedLine("abc", 10, 1, { fg: null, bg: RED }, columns(0, 2));
	assert line !== null;
	if (line !== null) {
		assert line.runs.length == 3;
		assert line.runs[1].bg == RED;
		assert line.runs[0].bg == line.runs[2].bg && line.runs[0].bg != RED;
	}
}

test "an overline is part of the run, and it keeps a trailing blank on the line" {
	const line = firstLine("\x1b[53mx \x1b[0my", 10, -1);
	assert line !== null;
	if (line !== null) {
		assert line.runs[0].flags.has(CellFlag.Overline);
		assert !line.runs[1].flags.has(CellFlag.Overline);
	}
	const trailing = firstLine("x\x1b[53m  \x1b[0m", 10, -1);
	assert trailing !== null;
	if (trailing !== null) { assert trailing.text == "x  "; }
}

test "a hidden cell draws no overline" {
	const line = firstLine("\x1b[8;53mx\x1b[0m", 10, -1);
	assert line !== null;
	if (line !== null) { assert !line.runs[0].flags.has(CellFlag.Overline); }
}

const TINT: Rgb = { r: 58, g: 28, b: 36 };
const GREEN: Rgb = { r: 0, g: 255, b: 0 };

test "a row tint colours every cell to the full width, beneath the cursor and the selection" {
	const line = tintedLine("abcd", 8, 1, columns(2, 2), { fg: null, bg: TINT });
	assert line !== null;
	if (line !== null) {
		assert line.text == "abcd    ";
		assert line.runs.map((r: LineRun): string => `${r.units}`).join(",") == "1,1,1,5";
		assert line.runs[0].bg == TINT && line.runs[3].bg == TINT;
		assert line.runs[1].bg == RED;
		assert line.runs[1].fg == TINT;
		assert line.runs[2].fg == TINT;
		assert line.runs[2].bg == line.runs[0].fg;
	}
}

test "a row tint keeps a cell's own colour where it names none" {
	const line = tintedLine("a\x1b[41mb\x1b[0m", 8, -1, null, { fg: GREEN, bg: null });
	const plain = firstLine("a", 8, -1);
	assert line !== null && plain !== null;
	if (line !== null && plain !== null) {
		assert line.text == "ab";
		assert line.runs.length == 2;
		assert line.runs[0].fg == GREEN && line.runs[1].fg == GREEN;
		assert line.runs[0].bg == plain.runs[0].bg;
		assert line.runs[1].bg != plain.runs[0].bg;
	}
}

function noteOf(text: string): RowNote {
	return { text: text, fg: null, bg: null };
}

function unitsOf(line: GridLine): string {
	return line.runs.map((r: LineRun): string => `${r.units}`).join(",");
}

test "a note sits right-aligned on its row in the row's foreground drawn faint" {
	const line = tintedLine("$ false", 24, -1, null, null, noteOf("exit 2 · 1.3s"));
	const plain = firstLine("$ false", 24, -1);
	assert line !== null && plain !== null;
	if (line !== null && plain !== null) {
		assert line.text == "$ false" + "    " + "exit 2 · 1.3s", line.text;
		assert unitsOf(line) == "11,13", unitsOf(line);
		const own = plain.runs[0];
		assert line.runs[0].fg == own.fg;
		assert line.runs[1].fg == faded(own.fg, own.bg);
		assert line.runs[1].bg == own.bg;
		assert line.widths.length == line.text.byteLength();
	}
}

test "a note that would overlap the row's text or its cursor is hidden" {
	const fits = tintedLine("0123456789abc", 20, -1, null, null, noteOf("exit 2"));
	const touches = tintedLine("0123456789abcd", 20, -1, null, null, noteOf("exit 2"));
	const cursor = tintedLine("$ ", 20, 15, null, null, noteOf("exit 2"));
	assert fits !== null && touches !== null && cursor !== null;
	if (fits !== null && touches !== null && cursor !== null) {
		assert fits.text == "0123456789abc exit 2", fits.text;
		assert touches.text == "0123456789abcd", touches.text;
		assert !cursor.text.includes("exit"), cursor.text;
	}
}

test "a note's own colours win over the row tint, and a wide grapheme takes two cells" {
	const note: RowNote = { text: "中!", fg: GREEN, bg: RED };
	const line = tintedLine("ab", 8, -1, null, { fg: null, bg: TINT }, note);
	const under = tintedLine("ab", 8, -1, null, { fg: null, bg: TINT }, noteOf("x"));
	assert line !== null && under !== null;
	if (line !== null && under !== null) {
		assert line.text == "ab" + "   " + "中!", line.text;
		assert line.runs[line.runs.length - 1].fg == GREEN;
		assert line.runs[line.runs.length - 1].bg == RED;
		assert line.runs[0].bg == TINT;
		assert line.widths[5] == 2 && line.widths[8] == 1;
		assert under.runs[under.runs.length - 1].bg == TINT;
	}
}
