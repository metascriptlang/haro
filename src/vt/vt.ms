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

export struct VtRow {
	y: int32;
	dirty: boolean;
	text: string;
}

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

function rowText(this vt: Vt): Result<string, VtError> {
	let cells = vt.cells;
	const cellsKey = GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS;
	if (!ok(rowCells(vt.rows, cellsKey, cells))) {
		return Result.err(VtError.ReadFailed);
	}
	let text = "";
	while (ghostty_render_state_row_cells_next(cells)) {
		let count: uint32 = 0;
		const lenKey =
			GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN;
		if (!ok(cellGraphemeCount(cells, lenKey, count))) { return Result.err(VtError.ReadFailed); }
		if (count == 0) {
			text += " ";
			continue;
		}
		if (count > MAX_GRAPHEMES) { return Result.err(VtError.GraphemeTooLong); }
		let graphemes: Graphemes = { cp: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] };
		const bufKey =
			GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF;
		if (!ok(cellGraphemes(cells, bufKey, graphemes))) { return Result.err(VtError.ReadFailed); }
		for (let i = 0; i < (count as int32); i++) {
			const cp = graphemes.cp[i] as int32;
			if (cp > 0xFFFF) { return Result.err(VtError.CodepointAboveBmpParked); }
			text += String.fromCharCode(cp);
		}
	}
	return Result.ok(text);
}

export function rows(this vt: Vt): Result<VtRow[], VtError> {
	let iterator = vt.rows;
	const key = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR;
	if (!ok(stateRowIterator(vt.state, key, iterator))) { return Result.err(VtError.ReadFailed); }
	const out: VtRow[] = [];
	let y = 0;
	while (ghostty_render_state_row_iterator_next(iterator)) {
		let dirty = false;
		const dirtyKey = GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY;
		if (!ok(rowDirty(iterator, dirtyKey, dirty))) { return Result.err(VtError.ReadFailed); }
		const text = try vt.rowText();
		out.push({ y: y, dirty: dirty, text: text });
		y++;
	}
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
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			assert rows.value.length == 4;
			assert rows.value[0].text.trimEnd() == "hello";
			assert rows.value[1].text.trimEnd() == "world";
			assert rows.value[0].dirty;
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
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) { assert rows.value[0].text.trimEnd() == "aéb"; }
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
