import {
	GhosttyCell,
	GhosttyCellContentTag,
	GhosttyCellData,
	GhosttyCellWide,
	GhosttyColorRgb,
	GhosttyRenderState,
	GhosttyRenderStateData,
	GhosttyRenderStateRowCells,
	GhosttyRenderStateRowCellsData,
	GhosttyRenderStateRowData,
	GhosttyRenderStateRowIterator,
	GhosttyRenderStateRowSelection,
	GhosttyResult,
	GhosttySgrUnderline,
	GhosttyStyle,
	GhosttyStyleColorTag,
	ghostty_render_state_row_cells_next,
	ghostty_render_state_row_iterator_next,
	ghostty_render_state_row_iterator_next_dirty,
	size_t,
} from "../../vendor/ghostty/include/ghostty/vt.h";
import { fromCodePoint } from "std/core/string";
import { CellWidth, RowSpan } from "../select/select";
import { Vt } from "./terminal";
import {
	Colors256,
	cellGraphemesInto,
	cellFacts,
	cellWide,
	cellsGet,
	checked,
	graphemeWidth,
	ok,
	pushAll,
	rgb,
	rowGet,
	stateGet,
} from "./vtNative";
import {
	Cell,
	CellFlag,
	Palette,
	Rgb,
	Row,
	Underline,
	VtError,
} from "./vtTypes";

const INLINE_GRAPHEMES: uint32 = 16;
const MAX_CELL_EXTRA: uint32 = 65536;

export function palette(this vt: Vt): Result<Palette, VtError> {
	let fg: GhosttyColorRgb = { r: 0, g: 0, b: 0 };
	let bg: GhosttyColorRgb = { r: 0, g: 0, b: 0 };
	const fgKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND;
	const bgKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND;
	try checked(stateGet(vt.state, fgKey, fg), VtError.ReadFailed);
	try checked(stateGet(vt.state, bgKey, bg), VtError.ReadFailed);
	let set = false;
	const setKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR_HAS_VALUE;
	try checked(stateGet(vt.state, setKey, set), VtError.ReadFailed);
	let cursor: GhosttyColorRgb = { r: 0, g: 0, b: 0 };
	const cursorKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR;
	if (set && !ok(stateGet(vt.state, cursorKey, cursor))) { return Result.err(VtError.ReadFailed); }
	return Result.ok({ fg: rgb(fg), bg: rgb(bg), cursor: set ? rgb(cursor) : null });
}

function colorOr(
	cells: GhosttyRenderStateRowCells,
	key: GhosttyRenderStateRowCellsData,
	fallback: Rgb,
): Rgb {
	let color: GhosttyColorRgb = { r: 0, g: 0, b: 0 };
	if (!ok(cellsGet(cells, key, color))) { return fallback; }
	return rgb(color);
}

function styleFlags(style: GhosttyStyle): BitSet<CellFlag> {
	let flags = 0 as BitSet<CellFlag>;
	if (style.bold) { flags = flags.incl(CellFlag.Bold); }
	if (style.italic) { flags = flags.incl(CellFlag.Italic); }
	if (style.faint) { flags = flags.incl(CellFlag.Faint); }
	if (style.blink) { flags = flags.incl(CellFlag.Blink); }
	if (style.inverse) { flags = flags.incl(CellFlag.Inverse); }
	if (style.invisible) { flags = flags.incl(CellFlag.Invisible); }
	if (style.strikethrough) { flags = flags.incl(CellFlag.Strikethrough); }
	if (style.overline) { flags = flags.incl(CellFlag.Overline); }
	return flags;
}

export function underlineOf(style: GhosttyStyle): Result<Underline, VtError> {
	return match (style.underline as GhosttySgrUnderline) {
		GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_NONE => Result.ok(Underline.None),
		GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_SINGLE => Result.ok(Underline.Single),
		GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_DOUBLE => Result.ok(Underline.Double),
		GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_CURLY => Result.ok(Underline.Curly),
		GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_DOTTED => Result.ok(Underline.Dotted),
		GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_DASHED => Result.ok(Underline.Dashed),
		_ => Result.err(VtError.UnderlineUnknown),
	};
}

function graphemesFrom(
	cells: GhosttyRenderStateRowCells,
	buf: Span<uint32>,
	count: uint32,
	ref extra: Vec<uint32>,
): Result<uint32, VtError> {
	const bufKey = GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF;
	try checked(cellGraphemesInto(cells, bufKey, buf as Ptr<uint32>), VtError.ReadFailed);
	pushAll(extra, buf[1..count as int32]);
	return Result.ok(buf[0]);
}

function graphemesOf(
	cells: GhosttyRenderStateRowCells,
	count: uint32,
	ref extra: Vec<uint32>,
): Result<uint32, VtError> {
	if (count <= INLINE_GRAPHEMES) {
		let small: uint32[16] = [];
		return graphemesFrom(cells, small, count, extra);
	}
	if (count > MAX_CELL_EXTRA) { return Result.err(VtError.GraphemeTooLong); }
	let all: Vec<uint32> = new Array(count as int32);
	return graphemesFrom(cells, all, count, extra);
}

function underlineColorOf(
	state: GhosttyRenderState,
	style: GhosttyStyle,
): Result<Rgb | null, VtError> {
	const color = style.underline_color;
	return match (color.tag) {
		GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_RGB => {
			const found: Rgb | null = rgb(color.value.rgb);
			return Result.ok(found);
		},
		GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_PALETTE => {
			let palette: Colors256;
			const key = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_COLOR_PALETTE;
			try checked(stateGet(state, key, palette), VtError.ReadFailed);
			const found: Rgb | null = rgb(palette.c[color.value.palette]);
			return Result.ok(found);
		},
		GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_NONE => Result.ok(null),
		GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_TAG_MAX_VALUE => Result.err(VtError.ReadFailed),
	};
}

export function widthOf(raw: GhosttyCell): Result<CellWidth, VtError> {
	let wide = GhosttyCellWide.GHOSTTY_CELL_WIDE_NARROW;
	try checked(cellWide(raw, GhosttyCellData.GHOSTTY_CELL_DATA_WIDE, wide), VtError.ReadFailed);
	return match (wide) {
		GhosttyCellWide.GHOSTTY_CELL_WIDE_WIDE => Result.ok(CellWidth.Wide),
		GhosttyCellWide.GHOSTTY_CELL_WIDE_SPACER_TAIL => Result.ok(CellWidth.Tail),
		GhosttyCellWide.GHOSTTY_CELL_WIDE_NARROW => Result.ok(CellWidth.Narrow),
		GhosttyCellWide.GHOSTTY_CELL_WIDE_SPACER_HEAD => Result.ok(CellWidth.Narrow),
		GhosttyCellWide.GHOSTTY_CELL_WIDE_MAX_VALUE => Result.err(VtError.ReadFailed),
	};
}

struct RawFacts {
	tag: GhosttyCellContentTag;
	styled: boolean;
	wide: GhosttyCellWide;
	cp: uint32;
}

function rawFacts(raw: GhosttyCell): Result<RawFacts, VtError> {
	let tag: GhosttyCellContentTag[1] = [GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_CODEPOINT];
	let styled: boolean[1] = [false];
	let wide: GhosttyCellWide[1] = [GhosttyCellWide.GHOSTTY_CELL_WIDE_NARROW];
	let cp: uint32[1] = [0];
	let keys: GhosttyCellData[4] = [
		GhosttyCellData.GHOSTTY_CELL_DATA_CONTENT_TAG,
		GhosttyCellData.GHOSTTY_CELL_DATA_HAS_STYLING,
		GhosttyCellData.GHOSTTY_CELL_DATA_WIDE,
		GhosttyCellData.GHOSTTY_CELL_DATA_CODEPOINT,
	];
	let values: Ptr<void>[4] = [tag as Ptr<void>, styled as Ptr<void>, wide as Ptr<void>, cp as Ptr<void>];
	try checked(cellFacts(raw, 4, keys as Ptr<GhosttyCellData>, values as Ptr<Ptr<void>>, null), VtError.ReadFailed);
	return Result.ok({ tag: tag[0], styled: styled[0], wide: wide[0], cp: cp[0] });
}

function readCell(
	state: GhosttyRenderState,
	cells: GhosttyRenderStateRowCells,
	colors: Palette,
	ref extra: Vec<uint32>,
): Result<Cell, VtError> {
	let raw: GhosttyCell = 0;
	const rawKey = GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW;
	try checked(cellsGet(cells, rawKey, raw), VtError.ReadFailed);
	const facts = try rawFacts(raw);
	const grapheme = facts.tag == GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME;
	const plain = facts.tag == GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_CODEPOINT && !facts.styled;
	const bgKey = GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR;
	const bg = plain ? colors.bg : colorOr(cells, bgKey, colors.bg);
	const none = 0 as BitSet<CellFlag>;
	if (facts.cp == 0 && !grapheme) {
		return Result.ok({
			cp: 0,
			extra: 0,
			fg: colors.fg,
			bg: bg,
			flags: none,
			underline: Underline.None,
			underlineColor: null,
		});
	}
	let count: uint32 = 1;
	let base = facts.cp;
	if (grapheme) {
		const lenKey = GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN;
		try checked(cellsGet(cells, lenKey, count), VtError.ReadFailed);
		base = try graphemesOf(cells, count, extra);
	}
	let fg = colors.fg;
	let flags = none;
	let underline = Underline.None;
	let underlineColor: Rgb | null = null;
	if (facts.styled) {
		const fgKey = GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR;
		fg = colorOr(cells, fgKey, colors.fg);
		let style: GhosttyStyle = { size: sizeof GhosttyStyle as size_t };
		const styleKey = GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE;
		try checked(cellsGet(cells, styleKey, style), VtError.ReadFailed);
		flags = styleFlags(style);
		underline = try underlineOf(style);
		if (underline != Underline.None) { underlineColor = try underlineColorOf(state, style); }
	}
	if (facts.wide == GhosttyCellWide.GHOSTTY_CELL_WIDE_WIDE) { flags = flags.incl(CellFlag.Wide); }
	return Result.ok({
		cp: base,
		extra: (count - 1) as uint16,
		fg: fg,
		bg: bg,
		flags: flags,
		underline: underline,
		underlineColor: underlineColor,
	});
}

function readRow(
	this vt: Vt,
	iterator: GhosttyRenderStateRowIterator,
	y: int32,
	colors: Palette,
	cols: int32,
): Result<Row, VtError> {
	let cells = vt.cells;
	const cellsKey = GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS;
	try checked(rowGet(iterator, cellsKey, cells), VtError.ReadFailed);
	let row: Row = { y: y, cells: new Array(cols), extra: [], selected: try selectedIn(iterator) };
	let at = 0;
	while (ghostty_render_state_row_cells_next(cells)) {
		if (at == cols) { return Result.err(VtError.ReadFailed); }
		row.cells[at] = try readCell(vt.state, cells, colors, row.extra);
		at++;
	}
	if (at < cols) { row.cells.shrink(at); }
	return Result.ok(row);
}

function selectedIn(iterator: GhosttyRenderStateRowIterator): Result<RowSpan | null, VtError> {
	let picked: GhosttyRenderStateRowSelection = { size: sizeof GhosttyRenderStateRowSelection as size_t };
	const key = GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION;
	const r = rowGet(iterator, key, picked);
	if (r == GhosttyResult.GHOSTTY_NO_VALUE) { return Result.ok(null); }
	try checked(r, VtError.ReadFailed);
	// Typed local until card 2026-10-21-result-ok-drops-null-from-declared-return.md
	const span: RowSpan | null = { from: picked.start_x as int32, to: picked.end_x as int32 };
	return Result.ok(span);
}

function rowIterator(this vt: Vt): Result<GhosttyRenderStateRowIterator, VtError> {
	let iterator = vt.iterator;
	const key = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR;
	try checked(stateGet(vt.state, key, iterator), VtError.ReadFailed);
	return Result.ok(iterator);
}

export function rows(this vt: Vt): Result<Vec<Row>, VtError> {
	const colors = try vt.palette();
	const cols = (try vt.size())[0];
	const iterator = try vt.rowIterator();
	let out: Vec<Row> = [];
	let y = 0;
	while (ghostty_render_state_row_iterator_next(iterator)) {
		const row = try vt.readRow(iterator, y, colors, cols);
		out.push(row);
		y++;
	}
	return Result.ok(out);
}

export function dirtyRows(this vt: Vt): Result<Vec<Row>, VtError> {
	const colors = try vt.palette();
	const cols = (try vt.size())[0];
	const iterator = try vt.rowIterator();
	let out: Vec<Row> = [];
	let y: uint16 = 0;
	while (ghostty_render_state_row_iterator_next_dirty(iterator, y)) {
		const row = try vt.readRow(iterator, y as int32, colors, cols);
		out.push(row);
	}
	return Result.ok(out);
}

export function isUnicodeScalar(cp: uint32): boolean {
	return cp <= 0x10FFFF && (cp < 0xD800 || cp > 0xDFFF);
}

export struct Grapheme {
	text: string;
	cells: int32;
}

function codePoints(text: string): Vec<uint32> {
	let cps: Vec<uint32> = [];
	for (let i = 0; i < text.length; i++) {
		const unit = text.charCodeAt(i) as uint32;
		const low = i + 1 < text.length ? text.charCodeAt(i + 1) as uint32 : 0;
		if (unit >= 0xD800 && unit < 0xDC00 && low >= 0xDC00 && low < 0xE000) {
			cps.push(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00));
			i++;
		} else {
			cps.push(unit);
		}
	}
	return cps;
}

export function graphemes(text: string): Vec<Grapheme> {
	const cps = codePoints(text);
	let out: Vec<Grapheme> = [];
	let at = 0;
	while (at < cps.length) {
		let width: uint8 = 0;
		const used = graphemeWidth(cps[at..cps.length as int32], width) as int32;
		let cluster = "";
		for (let k = at; k < at + used; k++) { cluster += fromCodePoint(cps[k] as number); }
		out.push({ text: cluster, cells: width as int32 });
		at += used;
	}
	return out;
}

export function text(this row: Row): Result<string, VtError> {
	let text = "";
	let extraAt = 0;
	let afterWide = false;
	for (const cell of row.cells) {
		const spacerTail = afterWide && cell.cp == 0;
		afterWide = cell.flags.has(CellFlag.Wide);
		if (spacerTail) { continue; }
		if (cell.cp == 0) {
			text += " ";
			continue;
		}
		const extra = cell.extra as int32;
		for (let k = 0; k <= extra; k++) {
			const cp = k == 0 ? cell.cp : row.extra[extraAt + k - 1];
			if (!isUnicodeScalar(cp)) { return Result.err(VtError.CodepointInvalid); }
			text += fromCodePoint(cp as number);
		}
		extraAt += extra;
	}
	return Result.ok(text);
}

export function lines(this vt: Vt): Result<Vec<string>, VtError> {
	const all = try vt.rows();
	let out: Vec<string> = [];
	for (const row of all) { out.push((try row.text()).trimEnd()); }
	return Result.ok(out);
}
