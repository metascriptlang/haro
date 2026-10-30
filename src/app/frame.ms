import { List, createList } from "../../../neon/src/core/list";
import { TextSpan } from "../../../neon/src/render/hostTypes";
import { Style, TextDecorationLine, TextDecorationStyle } from "../../../neon/src/render/style";
import { CellInk, GridLine, LineRun } from "../grid/lines";
import { Link } from "../screen/linksGrid";
import { Marked } from "../select/select";
import { CellFlag, Cursor, Rgb, Underline, Vt } from "../vt/vt";
import {
	Decor,
	FrameError,
	FrameRows,
	Shown,
	empty,
	fitShown,
	planRows,
} from "../controller/rows";

export interface RowSlot {
	line: GridLine;
	spans: TextSpan[];
}

export function blank(this typeof RowSlot): RowSlot {
	return { line: { text: "", runs: [], widths: [], cursorCell: null, cursorInk: null }, spans: [] };
}

export interface Styles {
	looks: Map<uint64, Style>;
	olderLooks: Map<uint64, Style>;
	tinted: Map<string, Style>;
	olderTinted: Map<string, Style>;
}

export function empty(this typeof Styles): Styles {
	return {
		looks: new Map<uint64, Style>(),
		olderLooks: new Map<uint64, Style>(),
		tinted: new Map<string, Style>(),
		olderTinted: new Map<string, Style>(),
	};
}

const HEX = "0123456789abcdef";
export const STYLE_CACHE_LIMIT = 8192;

function hexBytes(): string[] {
	let table: string[] = [];
	for (let n = 0; n < 256; n++) { table.push(HEX[n >> 4] + HEX[n & 15]); }
	return table;
}

const HEX_BYTES = hexBytes();

export function hexOf(this c: Rgb): string {
	return `#${HEX_BYTES[c.r]}${HEX_BYTES[c.g]}${HEX_BYTES[c.b]}`;
}

function recall<K>(now: Map<K, Style>, older: Map<K, Style>, key: K): Style | null {
	const known = now.get(key);
	if (known !== null) { return known; }
	const kept = older.get(key);
	if (kept !== null) { now.set(key, kept); }
	return kept;
}

function decorationOf(this run: LineRun): TextDecorationLine {
	const under = run.underline != Underline.None;
	const through = run.flags.has(CellFlag.Strikethrough);
	if (run.flags.has(CellFlag.Overline)) {
		if (under && through) { return "underline overline line-through"; }
		if (under) { return "underline overline"; }
		if (through) { return "overline line-through"; }
		return "overline";
	}
	if (under && through) { return "underline line-through"; }
	if (under) { return "underline"; }
	if (through) { return "line-through"; }
	return "none";
}

function lineStyleOf(underline: Underline): TextDecorationStyle {
	return match (underline) {
		Underline.None | Underline.Single => "solid",
		Underline.Double => "double",
		Underline.Curly => "wavy",
		Underline.Dotted => "dotted",
		Underline.Dashed => "dashed",
	};
}

const PLAIN_BG: uint64 = (1 as uint64) << 24;

function rgbBits(this c: Rgb): uint64 {
	return ((c.r as uint64) << 16) | ((c.g as uint64) << 8) | (c.b as uint64);
}

const FLAGS_BITS: uint64 = 9;
const FG_SHIFT: uint64 = FLAGS_BITS + 3;
const BG_SHIFT: uint64 = FG_SHIFT + 24;

function lookBits(this run: LineRun): uint64 {
	return ((run.underline as uint64) << FLAGS_BITS) | ((run.flags as uint32) as uint64);
}

function styleOf(this styles: Styles, run: LineRun, background: Rgb): Style {
	const plain = run.bg == background;
	const tint = run.underlineColor;
	const tinted = tint !== null && run.underline != Underline.None;
	const bgBits = plain ? PLAIN_BG : run.bg.rgbBits();
	const look = (bgBits << BG_SHIFT) | (run.fg.rgbBits() << FG_SHIFT) | run.lookBits();
	const key = tinted ? `${look}${tint!.hexOf()}` : "";
	const known = tinted
		? recall(styles.tinted, styles.olderTinted, key)
		: recall(styles.looks, styles.olderLooks, look);
	if (known !== null) { return known; }
	const fg = run.fg.hexOf();
	const bg = plain ? "" : run.bg.hexOf();
	const decoration = run.decorationOf();
	const weight: "bold" | "normal" = run.flags.has(CellFlag.Bold) ? "bold" : "normal";
	const slant: "italic" | "normal" = run.flags.has(CellFlag.Italic) ? "italic" : "normal";
	const lineColor = tinted ? tint!.hexOf() : "";
	const style: Style = {
		color: fg,
		textDecorationLine: decoration,
		textDecorationStyle: lineStyleOf(run.underline),
		fontWeight: weight,
		fontStyle: slant,
	};
	if (bg != "") { style.backgroundColor = bg; }
	if (lineColor != "") { style.textDecorationColor = lineColor; }
	if (tinted) {
		if (styles.tinted.size >= STYLE_CACHE_LIMIT) {
			styles.olderTinted = styles.tinted;
			styles.tinted = new Map<string, Style>();
		}
		styles.tinted.set(key, style);
	} else {
		if (styles.looks.size >= STYLE_CACHE_LIMIT) {
			styles.olderLooks = styles.looks;
			styles.looks = new Map<uint64, Style>();
		}
		styles.looks.set(look, style);
	}
	return style;
}

export function spansOf(this styles: Styles, l: GridLine, background: Rgb): TextSpan[] {
	if (l.runs.length == 1) {
		return [{ text: l.text, style: styles.styleOf(l.runs[0], background) }];
	}
	let spans: TextSpan[] = [];
	let at = 0;
	for (const run of l.runs) {
		const text = l.text.slice(at, at + run.units);
		spans.push({ text: text, style: styles.styleOf(run, background) });
		at += run.units;
	}
	return spans;
}

export function applyRows(grid: List<RowSlot>, styles: Styles, f: FrameRows): int32 {
	let chars: int32 = 0;
	const last = grid.length() - 1;
	for (let i = 0; i < f.scrolled; i++) { grid.move(0, last); }
	for (let i = 0; i < f.rows.length; i++) {
		chars += f.rows[i].line.text.length as int32;
		const line = f.rows[i].line;
		grid.set(f.rows[i].y, { line: line, spans: styles.spansOf(line, f.background) });
	}
	return chars;
}

export function fitGrid(grid: List<RowSlot>, rows: int32): void {
	const have = grid.length() as int32;
	for (let i = have; i < rows; i++) { grid.push(RowSlot.blank()); }
	for (let i = have; i > rows; i--) { grid.remove(i - 1); }
}

export interface View {
	grid: List<RowSlot>;
	styles: Styles;
	background: Rgb;
	hover: Link | null;
}

export function open(this typeof View): View {
	return {
		grid: createList<RowSlot>([]),
		styles: Styles.empty(),
		background: { r: 0, g: 0, b: 0 },
		hover: null,
	};
}

export function underlined(this l: GridLine, from: int32, to: int32): GridLine {
	let runs: Vec<LineRun> = [];
	let at: int32 = 0;
	for (const run of l.runs) {
		const end = at + run.units;
		const a = Math.max(from, at) as int32;
		const b = Math.min(to, end) as int32;
		if (a >= b || run.underline != Underline.None) {
			runs.push(run);
		} else {
			if (a > at) { runs.push({ ...run, units: a - at }); }
			runs.push({ ...run, units: b - a, underline: Underline.Single });
			if (b < end) { runs.push({ ...run, units: end - b }); }
		}
		at = end;
	}
	return { ...l, runs: runs };
}

function respan(this v: View, y: int32, link: Link | null): void {
	if (y < 0 || y >= (v.grid.length() as int32)) { return; }
	const line = v.grid.at(y).line;
	let shown = line;
	if (link !== null) {
		for (const s of link.stretches) {
			if (s.row == y) { shown = shown.underlined(s.from, s.to); }
		}
	}
	v.grid.set(y, { line: line, spans: v.styles.spansOf(shown, v.background) });
}

export function showHover(this v: View, link: Link | null): void {
	const was = v.hover;
	if (was == link) { return; }
	v.hover = null;
	if (was !== null) {
		for (const s of was.stretches) { v.respan(s.row, null); }
	}
	v.hover = link;
	if (link !== null) {
		for (const s of link.stretches) { v.respan(s.row, link); }
	}
}

function repaints(this link: Link, f: FrameRows): boolean {
	for (const s of link.stretches) {
		for (const r of f.rows) {
			if (r.y == s.row) { return true; }
		}
	}
	return false;
}

export function fitRows(this v: View, rows: int32): void {
	fitGrid(v.grid, rows);
}

export function paint(this v: View, f: FrameRows): int32 {
	const link = v.hover;
	if (link !== null && (f.scrolled != 0 || link.repaints(f))) { v.showHover(null); }
	v.background = f.background;
	return applyRows(v.grid, v.styles, f);
}

export function repaintCursor(this v: View, f: FrameRows): void {
	const link = v.hover;
	if (link !== null && (f.scrolled != 0 || link.repaints(f))) { v.showHover(null); }
	const _chars = applyRows(v.grid, v.styles, f);
}

export function text(this v: View, y: int32): string {
	return v.grid.at(y).line.text.trimEnd();
}

export function applyFrame(
	grid: List<RowSlot>,
	styles: Styles,
	ref shown: Vec<Shown>,
	vt: Vt,
	ink: CellInk | null,
): Result<Cursor | null, FrameError> {
	const planned = try shown.planRows(vt, ink, Decor.empty());
	const _chars = applyRows(grid, styles, planned.rows);
	return Result.ok(planned.cursor);
}

const BLACK: Rgb = { r: 0, g: 0, b: 0 };
const WHITE: Rgb = { r: 255, g: 255, b: 255 };
const RED: Rgb = { r: 255, g: 0, b: 0 };

function run(units: int32, fg: Rgb, bg: Rgb, underline: Underline): LineRun {
	return {
		units: units, fg: fg, bg: bg, underline: underline, underlineColor: null,
		flags: 0 as BitSet<CellFlag>,
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
		cursorCell: null,
		cursorInk: null,
	};
	const spans = spansOf(styles, l, BLACK);
	assert spans.length == 3;
	assert spans[0].text == "ab" && spans[1].text == " " && spans[2].text == "cd";
	assert spans[0].style === spans[2].style;
	assert styles.looks.size == 2;
}

test "a line of one run is one span holding the whole text, wide characters included" {
	const styles = Styles.empty();
	const l: GridLine = {
		text: "h\u00e9llo \u{1F600}",
		runs: [run(8, WHITE, BLACK, Underline.None)],
		widths: [],
		cursorCell: null,
		cursorInk: null,
	};
	const spans = spansOf(styles, l, BLACK);
	assert spans.length == 1;
	assert spans[0].text == l.text;
}

test "truecolour output that never repeats a look keeps the style cache bounded" {
	const styles = Styles.empty();
	for (let i = 0; i < STYLE_CACHE_LIMIT * 3; i++) {
		const fg: Rgb = { r: (i & 255) as uint8, g: ((i >> 8) & 255) as uint8, b: 7 };
		const l: GridLine = {
			text: "x",
			runs: [run(1, fg, BLACK, Underline.None)],
			widths: [],
			cursorCell: null,
			cursorInk: null,
		};
		const spans = spansOf(styles, l, BLACK);
		assert spans[0].style!.color == hexOf(fg);
	}
	assert styles.looks.size <= STYLE_CACHE_LIMIT;
}

test "a screenful of truecolour looks wider than one cache generation keeps its styles across repaints" {
	const styles = Styles.empty();
	const looks = STYLE_CACHE_LIMIT + STYLE_CACHE_LIMIT / 2;
	let first: TextSpan[] = [];
	for (let pass = 0; pass < 3; pass++) {
		for (let i = 0; i < looks; i++) {
			const fg: Rgb = { r: (i & 255) as uint8, g: ((i >> 8) & 255) as uint8, b: 7 };
			const l: GridLine = {
				text: "x",
				runs: [run(1, fg, BLACK, Underline.None)],
				widths: [],
				cursorCell: null,
				cursorInk: null,
			};
			const spans = spansOf(styles, l, BLACK);
			if (pass == 0) { first.push(spans[0]); }
			else { assert spans[0].style === first[i].style; }
		}
	}
}

test "a background differs from the terminal's only where a run says so" {
	const styles = Styles.empty();
	const l: GridLine = {
		text: "xy",
		runs: [run(1, WHITE, BLACK, Underline.Curly), run(1, WHITE, RED, Underline.None)],
		widths: [],
		cursorCell: null,
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
		cursorCell: null,
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
		let shown: Vec<Shown> = [];
		fitShown(shown, 2);
		const styles = Styles.empty();
		vt.writeText("a->b");
		assert applyFrame(grid, styles, shown, vt, null).ok;
		assert grid.at(0).spans[0].text == "a->b";
		vt.writeText("\x1b[1;3H");
		assert applyFrame(grid, styles, shown, vt, null).ok;
		assert grid.at(0).line.cursorCell === 2;
		assert grid.at(0).spans.length == 3;
		assert grid.at(0).spans[1].text == ">";
		vt.writeText("\x1b[2;1H");
		assert applyFrame(grid, styles, shown, vt, null).ok;
		assert grid.at(0).line.cursorCell === null;
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
		let shown: Vec<Shown> = [];
		fitShown(shown, 3);
		const styles = Styles.empty();
		const lit: CellInk = { fg: null, bg: RED };
		vt.writeText("ab\r\ncd\r\nef\x1b[2;3H");
		assert applyFrame(grid, styles, shown, vt, lit).ok;
		assert grid.at(1).spans.length == 2;
		assert grid.at(1).spans[1].text == " ";
		assert backgroundOf(grid.at(1), 1) == "#ff0000";
		assert grid.at(0).spans.length == 1;
		const untouched = grid.at(2);
		vt.writeText("\x1b[1;2H");
		assert applyFrame(grid, styles, shown, vt, lit).ok;
		assert grid.at(0).spans[1].text == "b";
		assert backgroundOf(grid.at(0), 1) == "#ff0000";
		assert grid.at(1).spans.length == 1;
		assert grid.at(2) === untouched;
		vt.free();
	}
}

test "selected cells, a wide one included, draw with their colours swapped" {
	const created = Vt.create(12, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const grid = createList<RowSlot>([RowSlot.blank(), RowSlot.blank()]);
		let shown: Vec<Shown> = [];
		fitShown(shown, 2);
		const styles = Styles.empty();
		vt.writeText("ab\u4e2dc");
		const marked: Marked = {
			range: { start: { row: 0, col: 1 }, end: { row: 0, col: 2 } },
			block: false,
		};
		assert vt.selectionSet(marked).ok;
		assert applyFrame(grid, styles, shown, vt, null).ok;
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

test "each underline style and an overline reach the span's decoration" {
	const styles = Styles.empty();
	const overline = (0 as BitSet<CellFlag>).incl(CellFlag.Overline);
	const over: LineRun = { ...run(1, WHITE, BLACK, Underline.None), flags: overline };
	const all: LineRun = {
		...run(1, WHITE, BLACK, Underline.Double),
		flags: CellFlag.Overline | CellFlag.Strikethrough,
	};
	const l: GridLine = {
		text: "abcdefg",
		runs: [
			run(1, WHITE, BLACK, Underline.Single),
			run(1, WHITE, BLACK, Underline.Double),
			run(1, WHITE, BLACK, Underline.Curly),
			run(1, WHITE, BLACK, Underline.Dotted),
			run(1, WHITE, BLACK, Underline.Dashed),
			over,
			all,
		],
		widths: [],
		cursorCell: null,
		cursorInk: null,
	};
	const spans = spansOf(styles, l, BLACK);
	assert spans[0].style!.textDecorationStyle == "solid";
	assert spans[1].style!.textDecorationStyle == "double";
	assert spans[2].style!.textDecorationStyle == "wavy";
	assert spans[3].style!.textDecorationStyle == "dotted";
	assert spans[4].style!.textDecorationStyle == "dashed";
	assert spans[4].style!.textDecorationLine == "underline";
	assert spans[5].style!.textDecorationLine == "overline";
	assert spans[6].style!.textDecorationLine == "underline overline line-through";
}

test "an underline never shares a cached style with a foreground one bit away" {
	const styles = Styles.empty();
	const near: Rgb = { r: 0, g: 0, b: 1 };
	const l: GridLine = {
		text: "xy",
		runs: [run(1, BLACK, WHITE, Underline.Single), run(1, near, WHITE, Underline.None)],
		widths: [],
		cursorCell: null,
		cursorInk: null,
	};
	const spans = spansOf(styles, l, BLACK);
	assert spans[1].style!.textDecorationLine == "none";
	assert spans[1].style!.color == "#000001";
}

function lineOf(text: string, runs: Vec<LineRun>): GridLine {
	return { text: text, runs: runs, widths: [], cursorCell: null, cursorInk: null };
}

test "an underline over a range splits the runs it crosses and leaves the rest and underlined runs alone" {
	const l = lineOf("abcdef", [
		run(3, WHITE, BLACK, Underline.None),
		run(2, WHITE, BLACK, Underline.Double),
		run(1, RED, BLACK, Underline.None),
	]);
	const u = l.underlined(1, 6);
	assert u.runs.length == 4;
	assert u.runs[0].units == 1 && u.runs[0].underline == Underline.None;
	assert u.runs[1].units == 2 && u.runs[1].underline == Underline.Single;
	assert u.runs[2].units == 2 && u.runs[2].underline == Underline.Double;
	assert u.runs[3].units == 1 && u.runs[3].underline == Underline.Single && u.runs[3].fg == RED;
	assert l.underlined(4, 4).runs.length == l.runs.length;
	assert l.underlined(6, 9).runs.length == l.runs.length;
}

function hoverOn(y: int32, from: int32, to: int32): Link {
	return { uri: "https://x.io", stretches: [{ row: y, from: from, to: to }] };
}

function rowsOf(y: int32, text: string): FrameRows {
	const l = lineOf(text, [run(text.length as int32, WHITE, BLACK, Underline.None)]);
	return { scrolled: 0, rows: [{ y: y, line: l }], background: BLACK };
}

function underlinedText(this v: View, y: int32): string {
	let out = "";
	for (const span of v.grid.at(y).spans) {
		if (span.style!.textDecorationLine == "underline") { out += span.text; }
	}
	return out;
}

test "a hovered link is underlined on screen, cleared when the pointer leaves, and dropped when its row repaints" {
	const v = View.open();
	v.fitRows(3);
	assert v.paint(rowsOf(0, "see https://x.io ok")) == 19;
	v.showHover(hoverOn(0, 4, 16));
	assert v.underlinedText(0) == "https://x.io";
	assert v.grid.at(0).spans.length == 3;
	v.showHover(hoverOn(1, 0, 3));
	assert v.underlinedText(0) == "";
	assert v.grid.at(0).spans.length == 1;
	v.showHover(hoverOn(0, 0, 3));
	assert v.underlinedText(0) == "see";
	assert v.paint(rowsOf(2, "other")) == 5;
	assert v.underlinedText(0) == "see";
	assert v.paint(rowsOf(0, "see https://x.io ok")) == 19;
	assert v.hover === null;
	assert v.underlinedText(0) == "";
	v.showHover(hoverOn(0, 0, 3));
	v.showHover(null);
	assert v.underlinedText(0) == "";
}

test "a scroll drops the hover before the rows move, so no underline stays on a row that left" {
	const v = View.open();
	v.fitRows(2);
	assert v.paint(rowsOf(0, "link")) == 4;
	v.showHover(hoverOn(0, 0, 4));
	assert v.underlinedText(0) == "link";
	const moved: FrameRows = { scrolled: 1, rows: [], background: BLACK };
	assert v.paint(moved) == 0;
	assert v.hover === null;
	assert v.underlinedText(0) == "";
	assert v.underlinedText(1) == "";
}
