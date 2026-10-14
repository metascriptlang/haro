@passC("-I../../vendor/ghostty/include");
@passC("-DGHOSTTY_STATIC");
@link("../../vendor/ghostty/zig-out/lib/ghostty-vt-static.lib");
@include("./effects.h");
@compile("./effects.c");

import {
	ghostty_terminal_new,
	ghostty_terminal_free,
	ghostty_terminal_resize,
	ghostty_key_encoder_new,
	ghostty_key_encoder_free,
	ghostty_key_encoder_setopt_from_terminal,
	ghostty_key_event_new,
	ghostty_key_event_free,
	ghostty_key_event_set_action,
	ghostty_key_event_set_key,
	ghostty_key_event_set_utf8,
	ghostty_key_event_set_unshifted_codepoint,
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
	GhosttyKeyEncoder,
	GhosttyKeyEvent,
	GhosttyKeyAction,
	GhosttyKey,
} from "../../vendor/ghostty/include/ghostty/vt.h";
import { KeyAction, KeyEvent, KeyMod, modsMask, textSafe } from "../keys/keys";

struct Graphemes { cp: uint32[16]; }

extern function vtWriteBytes(terminal: GhosttyTerminal, bytes: Readonly<Span<uint8>>): void
	from "ghostty_terminal_vt_write";
extern function vtEffectsOpen(terminal: GhosttyTerminal): int32;
extern function vtRepliesTake(id: int32, buf: Span<uint8>): int64;
extern function vtEffectsClose(id: int32, terminal: GhosttyTerminal): void;
extern function eventSetMods(event: GhosttyKeyEvent, mods: uint16): void
	from "ghostty_key_event_set_mods";
extern function eventSetConsumedMods(event: GhosttyKeyEvent, mods: uint16): void
	from "ghostty_key_event_set_consumed_mods";
extern function encoderEncode(
	encoder: GhosttyKeyEncoder,
	event: GhosttyKeyEvent,
	buf: Span<uint8>,
	out written: uint64,
): GhosttyResult from "ghostty_key_encoder_encode";

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
extern function stateCursorHasValue(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out hasValue: boolean,
): GhosttyResult from "ghostty_render_state_get";
extern function stateCursorX(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out x: uint16,
): GhosttyResult from "ghostty_render_state_get";
extern function stateCursorY(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out y: uint16,
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
	vtWriteBytes(vt.terminal, text.asBytes());
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

export struct Cursor {
	x: int32;
	y: int32;
}

export function cursor(this vt: Vt): Result<Cursor | null, VtError> {
	const hasKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE;
	let hasValue = false;
	if (!ok(stateCursorHasValue(vt.state, hasKey, hasValue))) {
		return Result.err(VtError.ReadFailed);
	}
	if (!hasValue) { return Result.ok(null); }
	let x: uint16 = 0;
	let y: uint16 = 0;
	const xKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X;
	const yKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y;
	if (!ok(stateCursorX(vt.state, xKey, x)) || !ok(stateCursorY(vt.state, yKey, y))) {
		return Result.err(VtError.ReadFailed);
	}
	const at: Cursor | null = { x: x as int32, y: y as int32 };
	return Result.ok(at);
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

export enum KeysError {
	OpenFailed,
	EncodeFailed,
	NoRoom,
}

export struct Keys {
	encoder: GhosttyKeyEncoder;
	event: GhosttyKeyEvent;
}

function actionOf(a: KeyAction): GhosttyKeyAction {
	return match (a) {
		KeyAction.Release => GhosttyKeyAction.GHOSTTY_KEY_ACTION_RELEASE,
		KeyAction.Press => GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
		KeyAction.Repeat => GhosttyKeyAction.GHOSTTY_KEY_ACTION_REPEAT,
	};
}

function keyOf(name: string): GhosttyKey {
	return match (name) {
		"Backquote" => GhosttyKey.GHOSTTY_KEY_BACKQUOTE,
		"Backslash" => GhosttyKey.GHOSTTY_KEY_BACKSLASH,
		"BracketLeft" => GhosttyKey.GHOSTTY_KEY_BRACKET_LEFT,
		"BracketRight" => GhosttyKey.GHOSTTY_KEY_BRACKET_RIGHT,
		"Comma" => GhosttyKey.GHOSTTY_KEY_COMMA,
		"Digit0" => GhosttyKey.GHOSTTY_KEY_DIGIT_0,
		"Digit1" => GhosttyKey.GHOSTTY_KEY_DIGIT_1,
		"Digit2" => GhosttyKey.GHOSTTY_KEY_DIGIT_2,
		"Digit3" => GhosttyKey.GHOSTTY_KEY_DIGIT_3,
		"Digit4" => GhosttyKey.GHOSTTY_KEY_DIGIT_4,
		"Digit5" => GhosttyKey.GHOSTTY_KEY_DIGIT_5,
		"Digit6" => GhosttyKey.GHOSTTY_KEY_DIGIT_6,
		"Digit7" => GhosttyKey.GHOSTTY_KEY_DIGIT_7,
		"Digit8" => GhosttyKey.GHOSTTY_KEY_DIGIT_8,
		"Digit9" => GhosttyKey.GHOSTTY_KEY_DIGIT_9,
		"Equal" => GhosttyKey.GHOSTTY_KEY_EQUAL,
		"IntlBackslash" => GhosttyKey.GHOSTTY_KEY_INTL_BACKSLASH,
		"IntlRo" => GhosttyKey.GHOSTTY_KEY_INTL_RO,
		"IntlYen" => GhosttyKey.GHOSTTY_KEY_INTL_YEN,
		"KeyA" => GhosttyKey.GHOSTTY_KEY_A,
		"KeyB" => GhosttyKey.GHOSTTY_KEY_B,
		"KeyC" => GhosttyKey.GHOSTTY_KEY_C,
		"KeyD" => GhosttyKey.GHOSTTY_KEY_D,
		"KeyE" => GhosttyKey.GHOSTTY_KEY_E,
		"KeyF" => GhosttyKey.GHOSTTY_KEY_F,
		"KeyG" => GhosttyKey.GHOSTTY_KEY_G,
		"KeyH" => GhosttyKey.GHOSTTY_KEY_H,
		"KeyI" => GhosttyKey.GHOSTTY_KEY_I,
		"KeyJ" => GhosttyKey.GHOSTTY_KEY_J,
		"KeyK" => GhosttyKey.GHOSTTY_KEY_K,
		"KeyL" => GhosttyKey.GHOSTTY_KEY_L,
		"KeyM" => GhosttyKey.GHOSTTY_KEY_M,
		"KeyN" => GhosttyKey.GHOSTTY_KEY_N,
		"KeyO" => GhosttyKey.GHOSTTY_KEY_O,
		"KeyP" => GhosttyKey.GHOSTTY_KEY_P,
		"KeyQ" => GhosttyKey.GHOSTTY_KEY_Q,
		"KeyR" => GhosttyKey.GHOSTTY_KEY_R,
		"KeyS" => GhosttyKey.GHOSTTY_KEY_S,
		"KeyT" => GhosttyKey.GHOSTTY_KEY_T,
		"KeyU" => GhosttyKey.GHOSTTY_KEY_U,
		"KeyV" => GhosttyKey.GHOSTTY_KEY_V,
		"KeyW" => GhosttyKey.GHOSTTY_KEY_W,
		"KeyX" => GhosttyKey.GHOSTTY_KEY_X,
		"KeyY" => GhosttyKey.GHOSTTY_KEY_Y,
		"KeyZ" => GhosttyKey.GHOSTTY_KEY_Z,
		"Minus" => GhosttyKey.GHOSTTY_KEY_MINUS,
		"Period" => GhosttyKey.GHOSTTY_KEY_PERIOD,
		"Quote" => GhosttyKey.GHOSTTY_KEY_QUOTE,
		"Semicolon" => GhosttyKey.GHOSTTY_KEY_SEMICOLON,
		"Slash" => GhosttyKey.GHOSTTY_KEY_SLASH,
		"AltLeft" => GhosttyKey.GHOSTTY_KEY_ALT_LEFT,
		"AltRight" => GhosttyKey.GHOSTTY_KEY_ALT_RIGHT,
		"Backspace" => GhosttyKey.GHOSTTY_KEY_BACKSPACE,
		"CapsLock" => GhosttyKey.GHOSTTY_KEY_CAPS_LOCK,
		"ContextMenu" => GhosttyKey.GHOSTTY_KEY_CONTEXT_MENU,
		"ControlLeft" => GhosttyKey.GHOSTTY_KEY_CONTROL_LEFT,
		"ControlRight" => GhosttyKey.GHOSTTY_KEY_CONTROL_RIGHT,
		"Enter" => GhosttyKey.GHOSTTY_KEY_ENTER,
		"MetaLeft" => GhosttyKey.GHOSTTY_KEY_META_LEFT,
		"MetaRight" => GhosttyKey.GHOSTTY_KEY_META_RIGHT,
		"ShiftLeft" => GhosttyKey.GHOSTTY_KEY_SHIFT_LEFT,
		"ShiftRight" => GhosttyKey.GHOSTTY_KEY_SHIFT_RIGHT,
		"Space" => GhosttyKey.GHOSTTY_KEY_SPACE,
		"Tab" => GhosttyKey.GHOSTTY_KEY_TAB,
		"Convert" => GhosttyKey.GHOSTTY_KEY_CONVERT,
		"KanaMode" => GhosttyKey.GHOSTTY_KEY_KANA_MODE,
		"NonConvert" => GhosttyKey.GHOSTTY_KEY_NON_CONVERT,
		"Delete" => GhosttyKey.GHOSTTY_KEY_DELETE,
		"End" => GhosttyKey.GHOSTTY_KEY_END,
		"Help" => GhosttyKey.GHOSTTY_KEY_HELP,
		"Home" => GhosttyKey.GHOSTTY_KEY_HOME,
		"Insert" => GhosttyKey.GHOSTTY_KEY_INSERT,
		"PageDown" => GhosttyKey.GHOSTTY_KEY_PAGE_DOWN,
		"PageUp" => GhosttyKey.GHOSTTY_KEY_PAGE_UP,
		"ArrowDown" => GhosttyKey.GHOSTTY_KEY_ARROW_DOWN,
		"ArrowLeft" => GhosttyKey.GHOSTTY_KEY_ARROW_LEFT,
		"ArrowRight" => GhosttyKey.GHOSTTY_KEY_ARROW_RIGHT,
		"ArrowUp" => GhosttyKey.GHOSTTY_KEY_ARROW_UP,
		"NumLock" => GhosttyKey.GHOSTTY_KEY_NUM_LOCK,
		"Numpad0" => GhosttyKey.GHOSTTY_KEY_NUMPAD_0,
		"Numpad1" => GhosttyKey.GHOSTTY_KEY_NUMPAD_1,
		"Numpad2" => GhosttyKey.GHOSTTY_KEY_NUMPAD_2,
		"Numpad3" => GhosttyKey.GHOSTTY_KEY_NUMPAD_3,
		"Numpad4" => GhosttyKey.GHOSTTY_KEY_NUMPAD_4,
		"Numpad5" => GhosttyKey.GHOSTTY_KEY_NUMPAD_5,
		"Numpad6" => GhosttyKey.GHOSTTY_KEY_NUMPAD_6,
		"Numpad7" => GhosttyKey.GHOSTTY_KEY_NUMPAD_7,
		"Numpad8" => GhosttyKey.GHOSTTY_KEY_NUMPAD_8,
		"Numpad9" => GhosttyKey.GHOSTTY_KEY_NUMPAD_9,
		"NumpadAdd" => GhosttyKey.GHOSTTY_KEY_NUMPAD_ADD,
		"NumpadBackspace" => GhosttyKey.GHOSTTY_KEY_NUMPAD_BACKSPACE,
		"NumpadClear" => GhosttyKey.GHOSTTY_KEY_NUMPAD_CLEAR,
		"NumpadClearEntry" => GhosttyKey.GHOSTTY_KEY_NUMPAD_CLEAR_ENTRY,
		"NumpadComma" => GhosttyKey.GHOSTTY_KEY_NUMPAD_COMMA,
		"NumpadDecimal" => GhosttyKey.GHOSTTY_KEY_NUMPAD_DECIMAL,
		"NumpadDivide" => GhosttyKey.GHOSTTY_KEY_NUMPAD_DIVIDE,
		"NumpadEnter" => GhosttyKey.GHOSTTY_KEY_NUMPAD_ENTER,
		"NumpadEqual" => GhosttyKey.GHOSTTY_KEY_NUMPAD_EQUAL,
		"NumpadMemoryAdd" => GhosttyKey.GHOSTTY_KEY_NUMPAD_MEMORY_ADD,
		"NumpadMemoryClear" => GhosttyKey.GHOSTTY_KEY_NUMPAD_MEMORY_CLEAR,
		"NumpadMemoryRecall" => GhosttyKey.GHOSTTY_KEY_NUMPAD_MEMORY_RECALL,
		"NumpadMemoryStore" => GhosttyKey.GHOSTTY_KEY_NUMPAD_MEMORY_STORE,
		"NumpadMemorySubtract" => GhosttyKey.GHOSTTY_KEY_NUMPAD_MEMORY_SUBTRACT,
		"NumpadMultiply" => GhosttyKey.GHOSTTY_KEY_NUMPAD_MULTIPLY,
		"NumpadParenLeft" => GhosttyKey.GHOSTTY_KEY_NUMPAD_PAREN_LEFT,
		"NumpadParenRight" => GhosttyKey.GHOSTTY_KEY_NUMPAD_PAREN_RIGHT,
		"NumpadSubtract" => GhosttyKey.GHOSTTY_KEY_NUMPAD_SUBTRACT,
		"NumpadSeparator" => GhosttyKey.GHOSTTY_KEY_NUMPAD_SEPARATOR,
		"NumpadUp" => GhosttyKey.GHOSTTY_KEY_NUMPAD_UP,
		"NumpadDown" => GhosttyKey.GHOSTTY_KEY_NUMPAD_DOWN,
		"NumpadRight" => GhosttyKey.GHOSTTY_KEY_NUMPAD_RIGHT,
		"NumpadLeft" => GhosttyKey.GHOSTTY_KEY_NUMPAD_LEFT,
		"NumpadBegin" => GhosttyKey.GHOSTTY_KEY_NUMPAD_BEGIN,
		"NumpadHome" => GhosttyKey.GHOSTTY_KEY_NUMPAD_HOME,
		"NumpadEnd" => GhosttyKey.GHOSTTY_KEY_NUMPAD_END,
		"NumpadInsert" => GhosttyKey.GHOSTTY_KEY_NUMPAD_INSERT,
		"NumpadDelete" => GhosttyKey.GHOSTTY_KEY_NUMPAD_DELETE,
		"NumpadPageUp" => GhosttyKey.GHOSTTY_KEY_NUMPAD_PAGE_UP,
		"NumpadPageDown" => GhosttyKey.GHOSTTY_KEY_NUMPAD_PAGE_DOWN,
		"Escape" => GhosttyKey.GHOSTTY_KEY_ESCAPE,
		"F1" => GhosttyKey.GHOSTTY_KEY_F1,
		"F2" => GhosttyKey.GHOSTTY_KEY_F2,
		"F3" => GhosttyKey.GHOSTTY_KEY_F3,
		"F4" => GhosttyKey.GHOSTTY_KEY_F4,
		"F5" => GhosttyKey.GHOSTTY_KEY_F5,
		"F6" => GhosttyKey.GHOSTTY_KEY_F6,
		"F7" => GhosttyKey.GHOSTTY_KEY_F7,
		"F8" => GhosttyKey.GHOSTTY_KEY_F8,
		"F9" => GhosttyKey.GHOSTTY_KEY_F9,
		"F10" => GhosttyKey.GHOSTTY_KEY_F10,
		"F11" => GhosttyKey.GHOSTTY_KEY_F11,
		"F12" => GhosttyKey.GHOSTTY_KEY_F12,
		"F13" => GhosttyKey.GHOSTTY_KEY_F13,
		"F14" => GhosttyKey.GHOSTTY_KEY_F14,
		"F15" => GhosttyKey.GHOSTTY_KEY_F15,
		"F16" => GhosttyKey.GHOSTTY_KEY_F16,
		"F17" => GhosttyKey.GHOSTTY_KEY_F17,
		"F18" => GhosttyKey.GHOSTTY_KEY_F18,
		"F19" => GhosttyKey.GHOSTTY_KEY_F19,
		"F20" => GhosttyKey.GHOSTTY_KEY_F20,
		"F21" => GhosttyKey.GHOSTTY_KEY_F21,
		"F22" => GhosttyKey.GHOSTTY_KEY_F22,
		"F23" => GhosttyKey.GHOSTTY_KEY_F23,
		"F24" => GhosttyKey.GHOSTTY_KEY_F24,
		"F25" => GhosttyKey.GHOSTTY_KEY_F25,
		"Fn" => GhosttyKey.GHOSTTY_KEY_FN,
		"FnLock" => GhosttyKey.GHOSTTY_KEY_FN_LOCK,
		"PrintScreen" => GhosttyKey.GHOSTTY_KEY_PRINT_SCREEN,
		"ScrollLock" => GhosttyKey.GHOSTTY_KEY_SCROLL_LOCK,
		"Pause" => GhosttyKey.GHOSTTY_KEY_PAUSE,
		"BrowserBack" => GhosttyKey.GHOSTTY_KEY_BROWSER_BACK,
		"BrowserFavorites" => GhosttyKey.GHOSTTY_KEY_BROWSER_FAVORITES,
		"BrowserForward" => GhosttyKey.GHOSTTY_KEY_BROWSER_FORWARD,
		"BrowserHome" => GhosttyKey.GHOSTTY_KEY_BROWSER_HOME,
		"BrowserRefresh" => GhosttyKey.GHOSTTY_KEY_BROWSER_REFRESH,
		"BrowserSearch" => GhosttyKey.GHOSTTY_KEY_BROWSER_SEARCH,
		"BrowserStop" => GhosttyKey.GHOSTTY_KEY_BROWSER_STOP,
		"Eject" => GhosttyKey.GHOSTTY_KEY_EJECT,
		"LaunchApp1" => GhosttyKey.GHOSTTY_KEY_LAUNCH_APP_1,
		"LaunchApp2" => GhosttyKey.GHOSTTY_KEY_LAUNCH_APP_2,
		"LaunchMail" => GhosttyKey.GHOSTTY_KEY_LAUNCH_MAIL,
		"MediaPlayPause" => GhosttyKey.GHOSTTY_KEY_MEDIA_PLAY_PAUSE,
		"MediaSelect" => GhosttyKey.GHOSTTY_KEY_MEDIA_SELECT,
		"MediaStop" => GhosttyKey.GHOSTTY_KEY_MEDIA_STOP,
		"MediaTrackNext" => GhosttyKey.GHOSTTY_KEY_MEDIA_TRACK_NEXT,
		"MediaTrackPrevious" => GhosttyKey.GHOSTTY_KEY_MEDIA_TRACK_PREVIOUS,
		"Power" => GhosttyKey.GHOSTTY_KEY_POWER,
		"Sleep" => GhosttyKey.GHOSTTY_KEY_SLEEP,
		"AudioVolumeDown" => GhosttyKey.GHOSTTY_KEY_AUDIO_VOLUME_DOWN,
		"AudioVolumeMute" => GhosttyKey.GHOSTTY_KEY_AUDIO_VOLUME_MUTE,
		"AudioVolumeUp" => GhosttyKey.GHOSTTY_KEY_AUDIO_VOLUME_UP,
		"WakeUp" => GhosttyKey.GHOSTTY_KEY_WAKE_UP,
		"Copy" => GhosttyKey.GHOSTTY_KEY_COPY,
		"Cut" => GhosttyKey.GHOSTTY_KEY_CUT,
		"Paste" => GhosttyKey.GHOSTTY_KEY_PASTE,
		_ => GhosttyKey.GHOSTTY_KEY_UNIDENTIFIED,
	};
}

export function openKeys(this typeof Keys): Result<Keys, KeysError> {
	let encoder: GhosttyKeyEncoder;
	if (!ok(ghostty_key_encoder_new(null, encoder))) {
		return Result.err(KeysError.OpenFailed);
	}
	let event: GhosttyKeyEvent;
	if (!ok(ghostty_key_event_new(null, event))) {
		ghostty_key_encoder_free(encoder);
		return Result.err(KeysError.OpenFailed);
	}
	return Result.ok({ encoder: encoder, event: event });
}

export function encode(
	this k: Keys,
	vt: Vt,
	e: KeyEvent,
	buf: Span<uint8>,
): Result<int32, KeysError> {
	ghostty_key_encoder_setopt_from_terminal(k.encoder, vt.terminal);
	ghostty_key_event_set_action(k.event, actionOf(e.action));
	ghostty_key_event_set_key(k.event, keyOf(e.key));
	eventSetMods(k.event, modsMask(e.mods));
	eventSetConsumedMods(k.event, modsMask(e.consumedMods));
	ghostty_key_event_set_unshifted_codepoint(k.event, e.unshifted);
	if (textSafe(e.text)) {
		ghostty_key_event_set_utf8(k.event, e.text, e.text.byteLength as uint64);
	} else {
		ghostty_key_event_set_utf8(k.event, "", 0);
	}
	let written: uint64 = 0;
	const r = encoderEncode(k.encoder, k.event, buf, written);
	if (r == GhosttyResult.GHOSTTY_OUT_OF_SPACE) { return Result.err(KeysError.NoRoom); }
	if (!ok(r)) { return Result.err(KeysError.EncodeFailed); }
	return Result.ok(written as int32);
}

export function freeKeys(this k: Keys): void {
	ghostty_key_event_free(k.event);
	ghostty_key_encoder_free(k.encoder);
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

function press(key: string, text: string, unshifted: uint32, mods: BitSet<KeyMod>): KeyEvent {
	return {
		action: KeyAction.Press,
		key: key,
		mods: mods,
		consumedMods: 0 as BitSet<KeyMod>,
		unshifted: unshifted,
		text: text,
	};
}

function encoded(k: Keys, vt: Vt, e: KeyEvent): string {
	let buf: Vec<uint8> = new Array(64);
	const r = k.encode(vt, e, buf);
	if (!r.ok) { return ""; }
	let out = "";
	for (let i = 0; i < r.value; i++) { out += String.fromCharCode(buf[i] as int32); }
	return out;
}

test "enter encodes as a carriage return" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const opened = Keys.openKeys();
		assert opened.ok;
		if (opened.ok) {
			const k = opened.value;
			const none = 0 as BitSet<KeyMod>;
			assert encoded(k, vt, press("Enter", "\r", 0x0D, none)) == "\r";
			k.freeKeys();
		}
		vt.free();
	}
}

test "ctrl+c encodes as ETX even when the platform reports the byte as text" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const opened = Keys.openKeys();
		assert opened.ok;
		if (opened.ok) {
			const k = opened.value;
			const ctrl = (0 as BitSet<KeyMod>).incl(KeyMod.Ctrl);
			assert encoded(k, vt, press("KeyC", "\x03", 0x63, ctrl)) == "\x03";
			k.freeKeys();
		}
		vt.free();
	}
}

test "arrow up follows the cursor key mode the vt is in" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const opened = Keys.openKeys();
		assert opened.ok;
		if (opened.ok) {
			const k = opened.value;
			const none = 0 as BitSet<KeyMod>;
			assert encoded(k, vt, press("ArrowUp", "", 0, none)) == "\x1b[A";
			vt.writeText("\x1b[?1h");
			assert encoded(k, vt, press("ArrowUp", "", 0, none)) == "\x1bOA";
			k.freeKeys();
		}
		vt.free();
	}
}

test "alt prefixes the escape" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const opened = Keys.openKeys();
		assert opened.ok;
		if (opened.ok) {
			const k = opened.value;
			const alt = (0 as BitSet<KeyMod>).incl(KeyMod.Alt);
			assert encoded(k, vt, press("KeyX", "x", 0x78, alt)) == "\x1bx";
			k.freeKeys();
		}
		vt.free();
	}
}

test "a consumed alt lets the text through unprefixed" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const opened = Keys.openKeys();
		assert opened.ok;
		if (opened.ok) {
			const k = opened.value;
			const none = 0 as BitSet<KeyMod>;
			const alt = none.incl(KeyMod.Alt);
			const e: KeyEvent = {
				action: KeyAction.Press,
				key: "BracketLeft",
				mods: alt,
				consumedMods: alt,
				unshifted: 0x5B,
				text: "{",
			};
			assert encoded(k, vt, e) == "{";
			k.freeKeys();
		}
		vt.free();
	}
}

test "ctrl with printable text encodes as fixterms csi u" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const opened = Keys.openKeys();
		assert opened.ok;
		if (opened.ok) {
			const k = opened.value;
			const none = 0 as BitSet<KeyMod>;
			const ctrlAlt = none.incl(KeyMod.Ctrl).incl(KeyMod.Alt);
			const e: KeyEvent = {
				action: KeyAction.Press,
				key: "BracketLeft",
				mods: ctrlAlt,
				consumedMods: ctrlAlt,
				unshifted: 0x5B,
				text: "{",
			};
			assert encoded(k, vt, e) == "\x1b[123;7u";
			k.freeKeys();
		}
		vt.free();
	}
}

test "a committed grapheme arrives as its utf-8 bytes" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const opened = Keys.openKeys();
		assert opened.ok;
		if (opened.ok) {
			const k = opened.value;
			const none = 0 as BitSet<KeyMod>;
			let buf: Vec<uint8> = new Array(64);
			const r = k.encode(vt, press("Unidentified", "ệ", 0, none), buf);
			assert r.ok;
			if (r.ok) {
				assert r.value == 3;
				assert buf[0] == 0xE1;
				assert buf[1] == 0xBB;
				assert buf[2] == 0x87;
			}
			k.freeKeys();
		}
		vt.free();
	}
}

test "the cursor reports where the next write lands" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("ab");
		assert vt.update().ok;
		const afterText = vt.cursor();
		assert afterText.ok;
		if (afterText.ok) {
			const at = afterText.value;
			assert at !== null;
			if (at !== null) {
				assert at.x == 2;
				assert at.y == 0;
			}
		}
		vt.writeText("\r\n");
		assert vt.update().ok;
		const afterNewline = vt.cursor();
		assert afterNewline.ok;
		if (afterNewline.ok) {
			const at = afterNewline.value;
			assert at !== null;
			if (at !== null) {
				assert at.x == 0;
				assert at.y == 1;
			}
		}
		vt.free();
	}
}
