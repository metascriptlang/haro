import { List, createList } from "../../../neon/src/core/list";
import { TextSpan } from "../../../neon/src/render/hostTypes";
import { Style } from "../../../neon/src/render/style";
import { GridLine, LineRun, line } from "../grid/lines";
import { plan } from "../screen/plan";
import { Cursor, Rgb, Row, Underline, Vt, palette } from "../vt/vt";
import { stats, noteApplied } from "./stats";

export struct RowSlot {
	line: GridLine;
	spans: TextSpan[];
}

export function blank(this typeof RowSlot): RowSlot {
	return { line: { text: "", runs: [], cursorCell: -1 }, spans: [] };
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
	PaletteFailed,
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

function cursorCellOf(cursor: Cursor | null, y: int32): int32 {
	return cursor !== null && cursor.y == y ? cursor.x : -1;
}

function slotOf(
	styles: Styles,
	row: Row,
	cursor: Cursor | null,
	background: Rgb,
): Result<RowSlot, FrameError> {
	const built = row.line(cursorCellOf(cursor, row.y), background);
	if (!built.ok) { return Result.err(FrameError.LineFailed); }
	return Result.ok({ line: built.value, spans: spansOf(styles, built.value, background) });
}

export function applyFrame(
	grid: List<RowSlot>,
	styles: Styles,
	vt: Vt,
): Result<Cursor | null, FrameError> {
	const planned = vt.plan();
	if (!planned.ok) { return Result.err(FrameError.PlanFailed); }
	const at = vt.cursor();
	if (!at.ok) { return Result.err(FrameError.CursorFailed); }
	const colors = vt.palette();
	if (!colors.ok) { return Result.err(FrameError.PaletteFailed); }
	const cursor = at.value;
	const p = planned.value;
	let chars: int32 = 0;
	const last = grid.length() - 1;
	for (let i = 0; i < p.scrolled; i++) { grid.move(0, last); }
	for (const row of p.rows) {
		const slot = try slotOf(styles, row, cursor, colors.value.bg);
		chars += slot.line.text.length as int32;
		grid.set(row.y, slot);
	}
	for (const row of vt.painted.rows) {
		if (grid.at(row.y).line.cursorCell != cursorCellOf(cursor, row.y)) {
			grid.set(row.y, try slotOf(styles, row, cursor, colors.value.bg));
		}
	}
	stats.noteApplied(p.rows.length as int32, p.scrolled, chars, performance.now());
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
		cursorCell: -1,
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
			cursorCell: -1,
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
		cursorCell: -1,
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
	const l: GridLine = { text: "xyzw", runs: [curly, plain, white, curly], cursorCell: -1 };
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
		assert applyFrame(grid, styles, vt).ok;
		assert grid.at(0).spans[0].text == "a->b";
		vt.writeText("\x1b[1;3H");
		assert applyFrame(grid, styles, vt).ok;
		assert grid.at(0).line.cursorCell == 2;
		assert grid.at(0).spans.length == 3;
		assert grid.at(0).spans[1].text == ">";
		vt.writeText("\x1b[2;1H");
		assert applyFrame(grid, styles, vt).ok;
		assert grid.at(0).line.cursorCell == -1;
		assert grid.at(0).spans.length == 1;
		vt.free();
	}
}
