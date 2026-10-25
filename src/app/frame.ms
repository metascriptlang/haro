import { List, createList } from "../../../neon/src/core/list";
import { TextSpan } from "../../../neon/src/render/hostTypes";
import { Style } from "../../../neon/src/render/style";
import { CellInk, GridLine, LineRun, cellOnRow, line } from "../grid/lines";
import { plan } from "../screen/plan";
import { Marked } from "../select/select";
import { Cursor, Rgb, Row, Underline, Vt } from "../vt/vt";
import { stats, noteApplied } from "./stats";
import { SELECTION } from "./theme";

export interface RowSlot {
	line: GridLine;
	spans: TextSpan[];
}

export function blank(this typeof RowSlot): RowSlot {
	return { line: { text: "", runs: [], widths: [], cursorCell: -1, cursorInk: null }, spans: [] };
}

export struct Styles {
	looks: Map<uint64, Style>;
	tinted: Map<string, Style>;
}

export function empty(this typeof Styles): Styles {
	return { looks: new Map<uint64, Style>(), tinted: new Map<string, Style>() };
}

export enum FrameError {
	PlanFailed,
	CursorFailed,
	LineFailed,
}

const HEX = "0123456789abcdef";
export const STYLE_CACHE_LIMIT = 4096;

function hexByte(v: uint8): string {
	const n = v as int32;
	return HEX[n >> 4] + HEX[n & 15];
}

export function hexOf(c: Rgb): string {
	return "#" + hexByte(c.r) + hexByte(c.g) + hexByte(c.b);
}

type Decoration = "none" | "underline" | "line-through" | "underline line-through";

function decorationOf(run: LineRun): Decoration {
	const under = run.underline != Underline.None;
	if (under && run.strikethrough) { return "underline line-through"; }
	if (under) { return "underline"; }
	if (run.strikethrough) { return "line-through"; }
	return "none";
}

const PLAIN_BG: uint64 = (1 as uint64) << 24;

function rgbBits(c: Rgb): uint64 {
	return ((c.r as uint64) << 16) | ((c.g as uint64) << 8) | (c.b as uint64);
}

function lookBits(run: LineRun): uint64 {
	const under: uint64 = match (run.underline) {
		Underline.None => 0,
		Underline.Curly => 2,
		_ => 1,
	};
	const strike = (run.strikethrough ? 1 : 0) as uint64;
	const bold = (run.bold ? 1 : 0) as uint64;
	const italic = (run.italic ? 1 : 0) as uint64;
	return (under << 3) | (strike << 2) | (bold << 1) | italic;
}

function styleOf(styles: Styles, run: LineRun, background: Rgb): Style {
	const plain = run.bg == background;
	const tint = run.underlineColor;
	const tinted = tint !== null && run.underline != Underline.None;
	const bgBits = plain ? PLAIN_BG : rgbBits(run.bg);
	const look = (bgBits << 29) | (rgbBits(run.fg) << 5) | lookBits(run);
	const key = tinted ? `${look}${hexOf(tint!)}` : "";
	const known = tinted ? styles.tinted.get(key) : styles.looks.get(look);
	if (known !== undefined) { return known; }
	const fg = hexOf(run.fg);
	const bg = plain ? "" : hexOf(run.bg);
	const decoration = decorationOf(run);
	const weight: "bold" | "normal" = run.bold ? "bold" : "normal";
	const slant: "italic" | "normal" = run.italic ? "italic" : "normal";
	const line: "wavy" | "solid" = run.underline == Underline.Curly ? "wavy" : "solid";
	const lineColor = tinted ? hexOf(tint!) : "";
	const style: Style = {
		color: fg,
		textDecorationLine: decoration,
		textDecorationStyle: line,
		fontWeight: weight,
		fontStyle: slant,
	};
	if (bg != "") { style.backgroundColor = bg; }
	if (lineColor != "") { style.textDecorationColor = lineColor; }
	if (tinted) {
		if (styles.tinted.size >= STYLE_CACHE_LIMIT) { styles.tinted.clear(); }
		styles.tinted.set(key, style);
	} else {
		if (styles.looks.size >= STYLE_CACHE_LIMIT) { styles.looks.clear(); }
		styles.looks.set(look, style);
	}
	return style;
}

export function spansOf(styles: Styles, l: GridLine, background: Rgb): TextSpan[] {
	let spans: TextSpan[] = [];
	let at = 0;
	for (const run of l.runs) {
		const text = l.text.slice(at, at + run.units);
		spans.push({ text: text, style: styleOf(styles, run, background) });
		at += run.units;
	}
	return spans;
}

function inkOn(this ink: CellInk | null, cell: int32): CellInk | null {
	return cell >= 0 ? ink : null;
}

function slotOf(
	styles: Styles,
	row: Row,
	cursor: Cursor | null,
	ink: CellInk | null,
	background: Rgb,
): Result<RowSlot, FrameError> {
	const cell = cursor.cellOnRow(row.y);
	const built = row.line(cell, ink.inkOn(cell), SELECTION, background);
	if (!built.ok) { return Result.err(FrameError.LineFailed); }
	const spans = spansOf(styles, built.value, background);
	return Result.ok({ line: move built.value, spans: spans });
}

function relight(
	grid: List<RowSlot>,
	styles: Styles,
	vt: Vt,
	cursor: Cursor | null,
	ink: CellInk | null,
	background: Rgb,
): Result<void, FrameError> {
	for (let i = 0; i < vt.painted.rows.length; i++) {
		const y = vt.painted.rows[i].y;
		const cell = cursor.cellOnRow(y);
		const shown = grid.at(y).line;
		if (shown.cursorCell != cell || shown.cursorInk != ink.inkOn(cell)) {
			grid.set(y, try slotOf(styles, vt.painted.rows[i], cursor, ink, background));
		}
	}
	return Result.ok(null);
}

export function relightCursor(
	grid: List<RowSlot>,
	styles: Styles,
	vt: Vt,
	ink: CellInk | null,
): Result<void, FrameError> {
	const colors = vt.painted.palette;
	if (colors === null || grid.length() != vt.painted.rows.length) { return Result.ok(null); }
	const at = vt.cursor();
	if (!at.ok) { return Result.err(FrameError.CursorFailed); }
	return relight(grid, styles, vt, at.value, ink, colors.bg);
}

export function applyFrame(
	grid: List<RowSlot>,
	styles: Styles,
	vt: Vt,
	ink: CellInk | null,
): Result<Cursor | null, FrameError> {
	const planned = vt.plan();
	if (!planned.ok) { return Result.err(FrameError.PlanFailed); }
	const at = vt.cursor();
	if (!at.ok) { return Result.err(FrameError.CursorFailed); }
	const cursor = at.value;
	const p = planned.value;
	let chars: int32 = 0;
	const last = grid.length() - 1;
	for (let i = 0; i < p.scrolled; i++) { grid.move(0, last); }
	for (const y of p.ys) {
		const slot = try slotOf(styles, vt.painted.rows[y], cursor, ink, p.colors.bg);
		chars += slot.line.text.length as int32;
		grid.set(y, slot);
	}
	const _relit = try relight(grid, styles, vt, cursor, ink, p.colors.bg);
	stats.noteApplied(p.ys.length as int32, p.scrolled, chars, performance.now());
	return Result.ok(cursor);
}

const BLACK: Rgb = { r: 0, g: 0, b: 0 };
const WHITE: Rgb = { r: 255, g: 255, b: 255 };
const RED: Rgb = { r: 255, g: 0, b: 0 };

function run(units: int32, fg: Rgb, bg: Rgb, underline: Underline): LineRun {
	return {
		units: units, fg: fg, bg: bg, underline: underline, underlineColor: null,
		bold: false, italic: false, strikethrough: false,
	};
}

test "each run becomes a span over its own text, sharing one style per look" {
	const styles = Styles.empty();
	const l: GridLine = {
		text: "ab cd",
		runs: [
			run(2, RED, BLACK, Underline.None),
			run(1, WHITE, BLACK, Underline.None),
			run(2, RED, BLACK, Underline.None),
		],
		widths: [],
		cursorCell: -1,
		cursorInk: null,
	};
	const spans = spansOf(styles, l, BLACK);
	assert spans.length == 3;
	assert spans[0].text == "ab" && spans[1].text == " " && spans[2].text == "cd";
	assert spans[0].style === spans[2].style;
	assert styles.looks.size == 2;
}

test "truecolour output that never repeats a look keeps the style cache bounded" {
	const styles = Styles.empty();
	for (let i = 0; i < STYLE_CACHE_LIMIT * 3; i++) {
		const fg: Rgb = { r: (i & 255) as uint8, g: ((i >> 8) & 255) as uint8, b: 7 };
		const l: GridLine = {
			text: "x",
			runs: [run(1, fg, BLACK, Underline.None)],
			widths: [],
			cursorCell: -1,
			cursorInk: null,
		};
		const spans = spansOf(styles, l, BLACK);
		assert spans[0].style!.color == hexOf(fg);
	}
	assert styles.looks.size <= STYLE_CACHE_LIMIT;
}

test "a background differs from the terminal's only where a run says so" {
	const styles = Styles.empty();
	const l: GridLine = {
		text: "xy",
		runs: [run(1, WHITE, BLACK, Underline.Curly), run(1, WHITE, RED, Underline.None)],
		widths: [],
		cursorCell: -1,
		cursorInk: null,
	};
	const spans = spansOf(styles, l, BLACK);
	assert spans[0].style!.backgroundColor === undefined;
	assert spans[0].style!.textDecorationLine == "underline";
	assert spans[1].style!.backgroundColor == "#ff0000";
	assert spans[1].style!.color == "#ffffff";
}

test "an underline colour tints the line, and only while the run is underlined" {
	const styles = Styles.empty();
	const curly: LineRun = { ...run(1, WHITE, BLACK, Underline.Curly), underlineColor: RED };
	const plain: LineRun = { ...run(1, WHITE, BLACK, Underline.None), underlineColor: RED };
	const white: LineRun = { ...curly, underlineColor: WHITE };
	const l: GridLine = {
		text: "xyzw",
		runs: [curly, plain, white, curly],
		widths: [],
		cursorCell: -1,
		cursorInk: null,
	};
	const spans = spansOf(styles, l, BLACK);
	assert spans[0].style!.textDecorationColor == "#ff0000";
	assert spans[0].style!.color == "#ffffff";
	assert spans[1].style!.textDecorationColor === undefined;
	assert spans[2].style!.textDecorationColor == "#ffffff";
	assert spans[0].style === spans[3].style;
}

test "a cursor that moves along its row rebuilds that row, so a ligature under it splits" {
	const created = Vt.create(12, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const grid = createList<RowSlot>([RowSlot.blank(), RowSlot.blank()]);
		const styles = Styles.empty();
		vt.writeText("a->b");
		assert applyFrame(grid, styles, vt, null).ok;
		assert grid.at(0).spans[0].text == "a->b";
		vt.writeText("\x1b[1;3H");
		assert applyFrame(grid, styles, vt, null).ok;
		assert grid.at(0).line.cursorCell == 2;
		assert grid.at(0).spans.length == 3;
		assert grid.at(0).spans[1].text == ">";
		vt.writeText("\x1b[2;1H");
		assert applyFrame(grid, styles, vt, null).ok;
		assert grid.at(0).line.cursorCell == -1;
		assert grid.at(0).spans.length == 1;
		vt.free();
	}
}

function backgroundOf(slot: RowSlot, i: int32): string {
	return slot.spans[i].style!.backgroundColor ?? "none";
}

test "a lit cursor colours its cell and moves with it, rebuilding only the rows it changes" {
	const created = Vt.create(12, 3);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const grid = createList<RowSlot>([RowSlot.blank(), RowSlot.blank(), RowSlot.blank()]);
		const styles = Styles.empty();
		const lit: CellInk = { fg: null, bg: RED };
		vt.writeText("ab\r\ncd\r\nef\x1b[2;3H");
		assert applyFrame(grid, styles, vt, lit).ok;
		assert grid.at(1).spans.length == 2;
		assert grid.at(1).spans[1].text == " ";
		assert backgroundOf(grid.at(1), 1) == "#ff0000";
		assert grid.at(0).spans.length == 1;
		const untouched = grid.at(2);
		vt.writeText("\x1b[1;2H");
		assert applyFrame(grid, styles, vt, lit).ok;
		assert grid.at(0).spans[1].text == "b";
		assert backgroundOf(grid.at(0), 1) == "#ff0000";
		assert grid.at(1).spans.length == 1;
		assert grid.at(2) === untouched;
		vt.free();
	}
}

test "relighting the cursor rebuilds only its row, so a blink turns its cell off and on" {
	const created = Vt.create(12, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const grid = createList<RowSlot>([RowSlot.blank(), RowSlot.blank()]);
		const styles = Styles.empty();
		const lit: CellInk = { fg: null, bg: RED };
		vt.writeText("ab\r\ncd\x1b[1;1H");
		assert applyFrame(grid, styles, vt, lit).ok;
		assert backgroundOf(grid.at(0), 0) == "#ff0000";
		const other = grid.at(1);
		assert relightCursor(grid, styles, vt, null).ok;
		assert backgroundOf(grid.at(0), 0) == "none";
		assert relightCursor(grid, styles, vt, lit).ok;
		assert backgroundOf(grid.at(0), 0) == "#ff0000";
		assert grid.at(1) === other;
		vt.free();
	}
}

test "selected cells, a wide one included, draw with their colours swapped" {
	const created = Vt.create(12, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const grid = createList<RowSlot>([RowSlot.blank(), RowSlot.blank()]);
		const styles = Styles.empty();
		vt.writeText("ab\u4e2dc");
		const marked: Marked = {
			range: { start: { row: 0, col: 1 }, end: { row: 0, col: 2 } },
			block: false,
		};
		assert vt.selectionSet(marked).ok;
		assert applyFrame(grid, styles, vt, null).ok;
		const colors = vt.palette();
		assert colors.ok;
		if (colors.ok) {
			const spans = grid.at(0).spans;
			assert spans.length == 3;
			assert spans[1].text == "b\u4e2d";
			assert spans[1].style!.color == hexOf(colors.value.bg);
			assert spans[1].style!.backgroundColor == hexOf(colors.value.fg);
			assert spans[2].style!.backgroundColor === undefined;
		}
		vt.free();
	}
}
