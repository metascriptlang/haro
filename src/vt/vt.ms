@passC("-I../../vendor/ghostty/include");
@passC("-DGHOSTTY_STATIC");
@link("../../vendor/ghostty/zig-out/lib/ghostty-vt-static.lib");
@include("./effects.h");
@compile("./effects.c");

import {
	ghostty_terminal_new,
	ghostty_terminal_free,
	ghostty_terminal_vt_write,
	ghostty_terminal_resize,
	ghostty_render_state_new,
	ghostty_render_state_free,
	ghostty_render_state_update,
	ghostty_render_state_clean,
	ghostty_render_state_row_iterator_new,
	ghostty_render_state_row_iterator_free,
	ghostty_render_state_row_iterator_next,
	ghostty_render_state_row_iterator_next_dirty,
	ghostty_render_state_row_cells_new,
	ghostty_render_state_row_cells_free,
	ghostty_render_state_row_cells_next,
	GhosttyResult,
	GhosttyTerminal,
	GhosttyRenderState,
	GhosttyRenderStateData,
	GhosttyRenderStateRowIterator,
	GhosttyRenderStateRowData,
	GhosttyRenderStateRowCells,
	GhosttyRenderStateRowCellsData,
	GhosttyColorRgb,
	GhosttyStyle,
	GhosttyCell,
	GhosttyCellData,
	GhosttyCellWide,
} from "../../vendor/ghostty/include/ghostty/vt.h";

struct Graphemes { cp: uint32[16]; }

extern function vtWriteBytes(terminal: GhosttyTerminal, bytes: Span<uint8>): void
	from "ghostty_terminal_vt_write";
extern function vtEffectsOpen(terminal: GhosttyTerminal): int32;
extern function vtRepliesTake(id: int32, buf: Span<uint8>): int64;
extern function vtEffectsClose(id: int32, terminal: GhosttyTerminal): void;

extern function stateCols(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out cols: uint16,
): GhosttyResult from "ghostty_render_state_get";
extern function stateRows(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out rows: uint16,
): GhosttyResult from "ghostty_render_state_get";
extern function stateRowIterator(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out it: GhosttyRenderStateRowIterator,
): GhosttyResult from "ghostty_render_state_get";
extern function rowDirty(
	it: GhosttyRenderStateRowIterator,
	key: GhosttyRenderStateRowData,
	out dirty: boolean,
): GhosttyResult from "ghostty_render_state_row_get";
extern function rowCells(
	it: GhosttyRenderStateRowIterator,
	key: GhosttyRenderStateRowData,
	out cells: GhosttyRenderStateRowCells,
): GhosttyResult from "ghostty_render_state_row_get";
extern function cellGraphemeCount(
	cells: GhosttyRenderStateRowCells,
	key: GhosttyRenderStateRowCellsData,
	out count: uint32,
): GhosttyResult from "ghostty_render_state_row_cells_get";
extern function cellGraphemes(
	cells: GhosttyRenderStateRowCells,
	key: GhosttyRenderStateRowCellsData,
	out graphemes: Graphemes,
): GhosttyResult from "ghostty_render_state_row_cells_get";
extern function stateColor(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out color: GhosttyColorRgb,
): GhosttyResult from "ghostty_render_state_get";
extern function cellColor(
	cells: GhosttyRenderStateRowCells,
	key: GhosttyRenderStateRowCellsData,
	out color: GhosttyColorRgb,
): GhosttyResult from "ghostty_render_state_row_cells_get";
extern function cellHasStyling(
	cells: GhosttyRenderStateRowCells,
	key: GhosttyRenderStateRowCellsData,
	out styled: boolean,
): GhosttyResult from "ghostty_render_state_row_cells_get";
extern function cellStyle(
	cells: GhosttyRenderStateRowCells,
	key: GhosttyRenderStateRowCellsData,
	out style: GhosttyStyle,
): GhosttyResult from "ghostty_render_state_row_cells_get";
extern function cellRaw(
	cells: GhosttyRenderStateRowCells,
	key: GhosttyRenderStateRowCellsData,
	out raw: GhosttyCell,
): GhosttyResult from "ghostty_render_state_row_cells_get";
extern function cellWide(
	raw: GhosttyCell,
	key: GhosttyCellData,
	out wide: GhosttyCellWide,
): GhosttyResult from "ghostty_cell_get";

const MAX_GRAPHEMES: uint32 = 16;

export enum VtError {
	CreateFailed,
	UpdateFailed,
	ResizeFailed,
	ReadFailed,
	GraphemeTooLong,
	CodepointAboveBmpParked,
	OutOfMemory,
}

export struct Vt {
	terminal: GhosttyTerminal;
	state: GhosttyRenderState;
	rows: GhosttyRenderStateRowIterator;
	cells: GhosttyRenderStateRowCells;
	effects: int32;
}

export struct Rgb { r: uint8; g: uint8; b: uint8; }

export enum CellFlag {
	Bold,
	Italic,
	Faint,
	Blink,
	Inverse,
	Invisible,
	Strikethrough,
	Overline,
	Wide,
}

export enum Underline {
	None,
	Single,
	Double,
	Curly,
	Dotted,
	Dashed,
}

export struct Cell {
	cp: uint32;
	extra: uint8;
	fg: Rgb;
	bg: Rgb;
	flags: BitSet<CellFlag>;
	underline: Underline;
}

export struct Row {
	y: int32;
	cells: Vec<Cell>;
	extra: Vec<uint32>;
}

struct Palette { fg: Rgb; bg: Rgb; }

function ok(r: GhosttyResult): boolean {
	return r == GhosttyResult.GHOSTTY_SUCCESS;
}

export function create(this typeof Vt, cols: int32, rows: int32): Result<Vt, VtError> {
	let terminal: GhosttyTerminal;
	if (!ok(ghostty_terminal_new(null, terminal, cols as uint16, rows as uint16))) {
		return Result.err(VtError.CreateFailed);
	}
	let state: GhosttyRenderState;
	let iterator: GhosttyRenderStateRowIterator;
	let cells: GhosttyRenderStateRowCells;
	if (
		!ok(ghostty_render_state_new(null, state)) ||
		!ok(ghostty_render_state_row_iterator_new(null, iterator)) ||
		!ok(ghostty_render_state_row_cells_new(null, cells))
	) {
		ghostty_terminal_free(terminal);
		return Result.err(VtError.CreateFailed);
	}
	const effects = vtEffectsOpen(terminal);
	if (effects < 0) {
		ghostty_render_state_row_cells_free(cells);
		ghostty_render_state_row_iterator_free(iterator);
		ghostty_render_state_free(state);
		ghostty_terminal_free(terminal);
		return Result.err(VtError.CreateFailed);
	}
	return Result.ok({
		terminal: terminal,
		state: state,
		rows: iterator,
		cells: cells,
		effects: effects,
	});
}

export function write(this vt: Vt, bytes: Span<uint8>): void {
	vtWriteBytes(vt.terminal, bytes);
}

export function writeText(this vt: Vt, text: string): void {
	ghostty_terminal_vt_write(vt.terminal, text, text.byteLength as uint64);
}

export function replies(this vt: Vt, buf: Span<uint8>): Result<int32, VtError> {
	const n = vtRepliesTake(vt.effects, buf);
	if (n == -2) { return Result.err(VtError.OutOfMemory); }
	if (n < 0) { return Result.err(VtError.ReadFailed); }
	return Result.ok(n as int32);
}

export function resize(this vt: Vt, cols: int32, rows: int32): Result<Vt, VtError> {
	const r = ghostty_terminal_resize(vt.terminal, cols as uint16, rows as uint16, 0, 0);
	if (!ok(r)) { return Result.err(VtError.ResizeFailed); }
	return Result.ok(vt);
}

export function update(this vt: Vt): Result<Vt, VtError> {
	if (!ok(ghostty_render_state_update(vt.state, vt.terminal))) {
		return Result.err(VtError.UpdateFailed);
	}
	return Result.ok(vt);
}

export function size(this vt: Vt): Result<[int32, int32], VtError> {
	let cols: uint16 = 0;
	let rows: uint16 = 0;
	if (
		!ok(stateCols(vt.state, GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_COLS, cols)) ||
		!ok(stateRows(vt.state, GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_ROWS, rows))
	) {
		return Result.err(VtError.ReadFailed);
	}
	return Result.ok([cols as int32, rows as int32]);
}

function rgb(c: GhosttyColorRgb): Rgb {
	return { r: c.r, g: c.g, b: c.b };
}

function palette(this vt: Vt): Result<Palette, VtError> {
	let fg: GhosttyColorRgb = { r: 0, g: 0, b: 0 };
	let bg: GhosttyColorRgb = { r: 0, g: 0, b: 0 };
	const fgKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND;
	const bgKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND;
	if (!ok(stateColor(vt.state, fgKey, fg)) || !ok(stateColor(vt.state, bgKey, bg))) {
		return Result.err(VtError.ReadFailed);
	}
	return Result.ok({ fg: rgb(fg), bg: rgb(bg) });
}

function colorOr(
	cells: GhosttyRenderStateRowCells,
	key: GhosttyRenderStateRowCellsData,
	fallback: Rgb,
): Rgb {
	let color: GhosttyColorRgb = { r: 0, g: 0, b: 0 };
	if (!ok(cellColor(cells, key, color))) { return fallback; }
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

function underlineOf(style: GhosttyStyle): Underline {
	return match (style.underline) {
		1 => Underline.Single,
		2 => Underline.Double,
		3 => Underline.Curly,
		4 => Underline.Dotted,
		5 => Underline.Dashed,
		_ => Underline.None,
	};
}

function readCell(
	cells: GhosttyRenderStateRowCells,
	colors: Palette,
	ref extra: Vec<uint32>,
): Result<Cell, VtError> {
	const bgKey = GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR;
	const bg = colorOr(cells, bgKey, colors.bg);
	let count: uint32 = 0;
	const lenKey = GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN;
	if (!ok(cellGraphemeCount(cells, lenKey, count))) { return Result.err(VtError.ReadFailed); }
	const none = 0 as BitSet<CellFlag>;
	if (count == 0) {
		return Result.ok({
			cp: 0,
			extra: 0,
			fg: colors.fg,
			bg: bg,
			flags: none,
			underline: Underline.None,
		});
	}
	if (count > MAX_GRAPHEMES) { return Result.err(VtError.GraphemeTooLong); }
	let graphemes: Graphemes = { cp: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] };
	const bufKey = GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF;
	if (!ok(cellGraphemes(cells, bufKey, graphemes))) { return Result.err(VtError.ReadFailed); }
	for (let i = 1; i < (count as int32); i++) { extra.push(graphemes.cp[i]); }
	const fgKey = GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR;
	const fg = colorOr(cells, fgKey, colors.fg);
	let flags = none;
	let underline = Underline.None;
	let styled = false;
	const styledKey = GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING;
	if (!ok(cellHasStyling(cells, styledKey, styled))) { return Result.err(VtError.ReadFailed); }
	if (styled) {
		let style: GhosttyStyle;
		style.size = sizeof GhosttyStyle;
		const styleKey = GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE;
		if (!ok(cellStyle(cells, styleKey, style))) { return Result.err(VtError.ReadFailed); }
		flags = styleFlags(style);
		underline = underlineOf(style);
	}
	let raw: GhosttyCell = 0;
	const rawKey = GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW;
	if (!ok(cellRaw(cells, rawKey, raw))) { return Result.err(VtError.ReadFailed); }
	let wide = GhosttyCellWide.GHOSTTY_CELL_WIDE_NARROW;
	if (!ok(cellWide(raw, GhosttyCellData.GHOSTTY_CELL_DATA_WIDE, wide))) {
		return Result.err(VtError.ReadFailed);
	}
	if (wide == GhosttyCellWide.GHOSTTY_CELL_WIDE_WIDE) { flags = flags.incl(CellFlag.Wide); }
	return Result.ok({
		cp: graphemes.cp[0],
		extra: (count - 1) as uint8,
		fg: fg,
		bg: bg,
		flags: flags,
		underline: underline,
	});
}

function readRow(
	this vt: Vt,
	iterator: GhosttyRenderStateRowIterator,
	y: int32,
	colors: Palette,
): Result<Row, VtError> {
	let cells = vt.cells;
	const cellsKey = GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS;
	if (!ok(rowCells(iterator, cellsKey, cells))) { return Result.err(VtError.ReadFailed); }
	let row: Row = { y: y, cells: [], extra: [] };
	while (ghostty_render_state_row_cells_next(cells)) {
		const cell = try readCell(cells, colors, row.extra);
		row.cells.push(cell);
	}
	return Result.ok(row);
}

export function rows(this vt: Vt): Result<Vec<Row>, VtError> {
	const colors = try vt.palette();
	let iterator = vt.rows;
	const key = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR;
	if (!ok(stateRowIterator(vt.state, key, iterator))) { return Result.err(VtError.ReadFailed); }
	let out: Vec<Row> = [];
	let y = 0;
	while (ghostty_render_state_row_iterator_next(iterator)) {
		out.push(try vt.readRow(iterator, y, colors));
		y++;
	}
	return Result.ok(out);
}

export function dirtyRows(this vt: Vt): Result<Vec<Row>, VtError> {
	const colors = try vt.palette();
	let iterator = vt.rows;
	const key = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR;
	if (!ok(stateRowIterator(vt.state, key, iterator))) { return Result.err(VtError.ReadFailed); }
	let out: Vec<Row> = [];
	let y: uint16 = 0;
	while (ghostty_render_state_row_iterator_next_dirty(iterator, y)) {
		out.push(try vt.readRow(iterator, y as int32, colors));
	}
	return Result.ok(out);
}

export function text(this row: Row): Result<string, VtError> {
	let text = "";
	let e = 0;
	for (const cell of row.cells) {
		if (cell.cp == 0) {
			text += " ";
			continue;
		}
		if (cell.cp > 0xFFFF) { return Result.err(VtError.CodepointAboveBmpParked); }
		text += String.fromCharCode(cell.cp as int32);
		for (let i = 0; i < (cell.extra as int32); i++) {
			const cp = row.extra[e + i];
			if (cp > 0xFFFF) { return Result.err(VtError.CodepointAboveBmpParked); }
			text += String.fromCharCode(cp as int32);
		}
		e += cell.extra as int32;
	}
	return Result.ok(text);
}

export function lines(this vt: Vt): Result<Vec<string>, VtError> {
	const all = try vt.rows();
	let out: Vec<string> = [];
	for (const row of all) { out.push((try row.text()).trimEnd()); }
	return Result.ok(out);
}

export function clean(this vt: Vt): void {
	ghostty_render_state_clean(vt.state);
}

export function free(this vt: Vt): void {
	vtEffectsClose(vt.effects, vt.terminal);
	ghostty_render_state_row_cells_free(vt.cells);
	ghostty_render_state_row_iterator_free(vt.rows);
	ghostty_render_state_free(vt.state);
	ghostty_terminal_free(vt.terminal);
}

test "written text lands on the rows the render state reports" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
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
		vt.free();
	}
}

test "raw bytes keep a multi-byte UTF-8 character whole" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
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
		vt.free();
	}
}

function ascii(bytes: Span<uint8>): string {
	let text = "";
	for (const b of bytes) { text += String.fromCharCode(b as int32); }
	return text;
}

test "a cursor position query is answered with the cursor's place" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("ab[6n");
		let buf: Vec<uint8> = new Array(64);
		const n = vt.replies(buf);
		assert n.ok;
		if (n.ok) { assert ascii(buf[0..n.value]) == "[1;3R"; }
		vt.free();
	}
}

test "text without a query leaves nothing to reply" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("hello");
		let buf: Vec<uint8> = new Array(64);
		const n = vt.replies(buf);
		assert n.ok;
		if (n.ok) { assert n.value == 0; }
		vt.free();
	}
}

test "a styled cell carries its colour, flags and underline" {
	const created = Vt.create(20, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("[1;4;38;2;255;0;0mA[0mb");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const red: Rgb = { r: 255, g: 0, b: 0 };
			const a = rows.value[0].cells[0];
			assert a.cp == 0x41;
			assert a.fg == red;
			assert a.flags.has(CellFlag.Bold);
			assert !a.flags.has(CellFlag.Italic);
			assert a.underline == Underline.Single;
			const b = rows.value[0].cells[1];
			assert b.cp == 0x62;
			assert b.fg != red;
			assert b.flags.isEmpty();
			assert b.underline == Underline.None;
		}
		vt.free();
	}
}

test "an erased line keeps its background on cells without text" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("[48;2;0;0;255m[K");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const blue: Rgb = { r: 0, g: 0, b: 255 };
			const cell = rows.value[0].cells[5];
			assert cell.cp == 0;
			assert cell.bg == blue;
		}
		vt.free();
	}
}

test "a wide character is flagged and its spacer holds no text" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("中a");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const cells = rows.value[0].cells;
			assert cells[0].cp == 0x4E2D;
			assert cells[0].flags.has(CellFlag.Wide);
			assert cells[1].cp == 0;
			assert cells[2].cp == 0x61;
			assert !cells[2].flags.has(CellFlag.Wide);
		}
		vt.free();
	}
}

test "a combining mark joins its base cell" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("éx");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const row = rows.value[0];
			assert row.cells[0].cp == 0x65;
			assert row.cells[0].extra == 1;
			assert row.extra.length == 1;
			assert row.extra[0] == 0x301;
			assert row.cells[1].cp == 0x78;
		}
		vt.free();
	}
}

test "only rows written since the last clean are dirty" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("a
b");
		assert vt.update().ok;
		vt.clean();
		vt.writeText("c");
		assert vt.update().ok;
		const dirty = vt.dirtyRows();
		assert dirty.ok;
		if (dirty.ok) {
			assert dirty.value.length == 1;
			assert dirty.value[0].y == 1;
			assert dirty.value[0].cells[1].cp == 0x62;
		}
		vt.free();
	}
}
