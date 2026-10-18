@passC("-I../../vendor/ghostty/include");
@passC("-DGHOSTTY_STATIC");
when (emcc) {
	@link("../../out/wasm/libghostty-vt.a");
} else when (windows) {
	@link("../../vendor/ghostty/zig-out/lib/ghostty-vt-static.lib");
} else {
	@link("../../vendor/ghostty/zig-out/lib/libghostty-vt.a");
}
@include("./effects.h");
@compile("./effects.c");
@include("./shim.h");
@compile("./shim.c");

import {
	ghostty_terminal_new,
	ghostty_terminal_free,
	ghostty_terminal_resize,
	ghostty_tracked_grid_ref_free,
	ghostty_tracked_grid_ref_point,
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
	ghostty_mouse_encoder_new,
	ghostty_mouse_encoder_free,
	ghostty_mouse_encoder_setopt_from_terminal,
	ghostty_mouse_event_new,
	ghostty_mouse_event_free,
	ghostty_mouse_event_clear_button,
	ghostty_mouse_event_set_position,
	GhosttyAllocator,
	GhosttyResult,
	GhosttyTerminal,
	GhosttyTerminalData,
	GhosttyTerminalOption,
	GhosttyTerminalModeConfig,
	GhosttyFocusEvent,
	GhosttyTerminalScreen,
	GhosttyTerminalScrollbar,
	GhosttyTrackedGridRef,
	GhosttyGridRef,
	GhosttySelection,
	GhosttySelectionOrder,
	GhosttyTerminalSelectWordOptions,
	GhosttyTerminalSelectLineOptions,
	GhosttyTerminalSelectionFormatOptions,
	GhosttyFormatterFormat,
	GhosttyTerminalScrollViewportTag,
	GhosttyRow,
	GhosttyRowData,
	GhosttyRowSemanticPrompt,
	GhosttyPointCoordinate,
	GhosttyPointTag,
	GhosttyRenderState,
	GhosttyRenderStateData,
	GhosttyRenderStateRowIterator,
	GhosttyRenderStateRowData,
	GhosttyRenderStateRowCells,
	GhosttyRenderStateRowCellsData,
	GhosttyColorRgb,
	GhosttyStyle,
	GhosttyStyleColorTag,
	GhosttyRenderStateCursorVisualStyle,
	GhosttyCell,
	GhosttyCellData,
	GhosttyCellWide,
	GhosttyKeyEncoder,
	GhosttyMouseEncoder,
	GhosttyMouseEncoderOption,
	GhosttyMouseEncoderSize,
	GhosttyMouseEvent,
	GhosttyKeyEvent,
	GhosttyKeyAction,
	GhosttyKey,
} from "../../vendor/ghostty/include/ghostty/vt.h";
import { fromCodePoint } from "std/core/string";
import { KeyAction, KeyEvent, KeyMod, modsMask, textSafe, withoutAltGr } from "../keys/keys";
import { Marked, Point, Range, Selection, Unit } from "../select/select";
import { Handle } from "std/ffi";

struct Graphemes { cp: uint32[16]; }
struct Colors256 { c: GhosttyColorRgb[256]; }

extern function vtWriteBytes(terminal: GhosttyTerminal, bytes: Readonly<Span<uint8>>): void
	from "ghostty_terminal_vt_write";
extern function vtAllocator(): Ptr<GhosttyAllocator>;
extern function vtEffectsWire(terminal: GhosttyTerminal, effects: Ptr<void> | null): int32;
extern function mouseSetFlag(
	encoder: GhosttyMouseEncoder,
	option: GhosttyMouseEncoderOption,
	ref value: boolean,
): void from "ghostty_mouse_encoder_setopt";
extern function mouseSetSize(
	encoder: GhosttyMouseEncoder,
	option: GhosttyMouseEncoderOption,
	ref size: GhosttyMouseEncoderSize,
): void from "ghostty_mouse_encoder_setopt";
extern function mouseSetAction(event: GhosttyMouseEvent, action: int32): void from "ghostty_mouse_event_set_action";
extern function mouseSetButton(event: GhosttyMouseEvent, button: int32): void from "ghostty_mouse_event_set_button";
extern function mouseSetMods(event: GhosttyMouseEvent, mods: uint16): void from "ghostty_mouse_event_set_mods";
extern function mouseEncode(
	encoder: GhosttyMouseEncoder,
	event: GhosttyMouseEvent,
	buf: Span<uint8>,
	out written: uint64,
): GhosttyResult from "ghostty_mouse_encoder_encode";
extern function vtString(terminal: GhosttyTerminal, key: GhosttyTerminalData, buf: Span<uint8>): int64;
extern function vtTopTrack(terminal: GhosttyTerminal, out ref: GhosttyTrackedGridRef): int32;
extern function vtTopAnchor(ref: GhosttyTrackedGridRef, terminal: GhosttyTerminal): int32;
extern function terminalScrollbar(
	terminal: GhosttyTerminal,
	key: GhosttyTerminalData,
	out scrollbar: GhosttyTerminalScrollbar,
): GhosttyResult from "ghostty_terminal_get";
extern function terminalScreen(
	terminal: GhosttyTerminal,
	key: GhosttyTerminalData,
	out screen: GhosttyTerminalScreen,
): GhosttyResult from "ghostty_terminal_get";
extern function terminalFlag(
	terminal: GhosttyTerminal,
	key: GhosttyTerminalData,
	out value: boolean,
): GhosttyResult from "ghostty_terminal_get";
extern function terminalMode(
	terminal: GhosttyTerminal,
	key: GhosttyTerminalData,
	ref mode: GhosttyTerminalModeConfig,
): GhosttyResult from "ghostty_terminal_get";
extern function terminalColors(
	terminal: GhosttyTerminal,
	key: GhosttyTerminalData,
	out colors: Colors256,
): GhosttyResult from "ghostty_terminal_get";
extern function setColor(
	terminal: GhosttyTerminal,
	option: GhosttyTerminalOption,
	ref color: GhosttyColorRgb,
): GhosttyResult from "ghostty_terminal_set";
extern function setColors(
	terminal: GhosttyTerminal,
	option: GhosttyTerminalOption,
	ref colors: Colors256,
): GhosttyResult from "ghostty_terminal_set";
extern function setSize(
	terminal: GhosttyTerminal,
	option: GhosttyTerminalOption,
	ref value: uint64,
): GhosttyResult from "ghostty_terminal_set";
extern function setFlag(
	terminal: GhosttyTerminal,
	option: GhosttyTerminalOption,
	ref value: boolean,
): GhosttyResult from "ghostty_terminal_set";
extern function setMode(
	terminal: GhosttyTerminal,
	option: GhosttyTerminalOption,
	ref mode: GhosttyTerminalModeConfig,
): GhosttyResult from "ghostty_terminal_set";
extern function unset(
	terminal: GhosttyTerminal,
	option: GhosttyTerminalOption,
	value: Ptr<void> | null,
): GhosttyResult from "ghostty_terminal_set";
extern function focusEncode(
	event: GhosttyFocusEvent,
	buf: Span<uint8>,
	out written: uint64,
): GhosttyResult from "ghostty_focus_encode";
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
extern function cellGraphemesInto(
	cells: GhosttyRenderStateRowCells,
	key: GhosttyRenderStateRowCellsData,
	buf: Ptr<uint32>,
): GhosttyResult from "ghostty_render_state_row_cells_get";
extern function stateColor(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out color: GhosttyColorRgb,
): GhosttyResult from "ghostty_render_state_get";
extern function stateFlag(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out value: boolean,
): GhosttyResult from "ghostty_render_state_get";
extern function stateCursorStyle(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out style: GhosttyRenderStateCursorVisualStyle,
): GhosttyResult from "ghostty_render_state_get";
extern function stateColors(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out colors: Colors256,
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
extern function styleDefault(out style: GhosttyStyle): void from "ghostty_style_default";
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

extern function vtGridRef(
	terminal: GhosttyTerminal,
	tag: GhosttyPointTag,
	x: int32,
	y: int32,
	out gridRef: GhosttyGridRef,
): GhosttyResult;
extern function vtScroll(terminal: GhosttyTerminal, tag: GhosttyTerminalScrollViewportTag, amount: int64): void;
extern function gridRefLink(
	ref gridRef: GhosttyGridRef,
	buf: Span<uint8>,
	out len: uint64,
): GhosttyResult from "ghostty_grid_ref_hyperlink_uri";
extern function gridRefCell(ref gridRef: GhosttyGridRef, out cell: GhosttyCell): GhosttyResult
	from "ghostty_grid_ref_cell";
extern function gridRefRow(ref gridRef: GhosttyGridRef, out row: GhosttyRow): GhosttyResult
	from "ghostty_grid_ref_row";
extern function rowPrompt(
	row: GhosttyRow,
	key: GhosttyRowData,
	out prompt: GhosttyRowSemanticPrompt,
): GhosttyResult from "ghostty_row_get";
extern function pointOf(
	terminal: GhosttyTerminal,
	ref gridRef: GhosttyGridRef,
	tag: GhosttyPointTag,
	out at: GhosttyPointCoordinate,
): GhosttyResult from "ghostty_terminal_point_from_grid_ref";
extern function terminalSelection(
	terminal: GhosttyTerminal,
	key: GhosttyTerminalData,
	ref selection: GhosttySelection,
): GhosttyResult from "ghostty_terminal_get";
extern function setSelection(
	terminal: GhosttyTerminal,
	option: GhosttyTerminalOption,
	ref selection: GhosttySelection,
): GhosttyResult from "ghostty_terminal_set";
extern function selectionOrdered(
	terminal: GhosttyTerminal,
	ref selection: GhosttySelection,
	order: GhosttySelectionOrder,
	ref ordered: GhosttySelection,
): GhosttyResult from "ghostty_terminal_selection_ordered";
extern function selectWord(
	terminal: GhosttyTerminal,
	ref options: GhosttyTerminalSelectWordOptions,
	ref selection: GhosttySelection,
): GhosttyResult from "ghostty_terminal_select_word";
extern function selectLine(
	terminal: GhosttyTerminal,
	ref options: GhosttyTerminalSelectLineOptions,
	ref selection: GhosttySelection,
): GhosttyResult from "ghostty_terminal_select_line";
extern function selectionFormat(
	terminal: GhosttyTerminal,
	options: GhosttyTerminalSelectionFormatOptions,
	buf: Span<uint8>,
	out written: uint64,
): GhosttyResult from "ghostty_terminal_selection_format_buf";
extern function pasteSafe(data: Readonly<Span<uint8>>): boolean from "ghostty_paste_is_safe";
extern function pasteEncode(
	data: Span<uint8>,
	bracketed: boolean,
	buf: Span<uint8>,
	out written: uint64,
): GhosttyResult from "ghostty_paste_encode";

const MAX_GRAPHEMES: uint32 = 16;
const MAX_CELL_EXTRA: uint32 = 65536;

export enum VtError {
	CreateFailed,
	UpdateFailed,
	ResizeFailed,
	ReadFailed,
	GraphemeTooLong,
	CodepointInvalid,
	SelectFailed,
}

export enum PasteError {
	Unsafe,
	EncodeFailed,
}

export struct Vt {
	terminal: GhosttyTerminal;
	state: GhosttyRenderState;
	rows: GhosttyRenderStateRowIterator;
	cells: GhosttyRenderStateRowCells;
	effects: Effects;
	mouse: Mouse;
	top: GhosttyTrackedGridRef;
	painted: Painted;
}

// The mouse encoder, opened on the first report, and the modes and geometry it was last given: it
// forgets the last cell it reported on every setopt_from_terminal and size, so each is set only when
// its value changed.
export interface Mouse {
	encoder: GhosttyMouseEncoder | null;
	event: GhosttyMouseEvent | null;
	signature: int32;
	geometry: MouseGeometry | null;
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
	extra: uint16;
	fg: Rgb;
	bg: Rgb;
	flags: BitSet<CellFlag>;
	underline: Underline;
	underlineColor: Rgb | null;
}

export struct Row {
	y: int32;
	cells: Vec<Cell>;
	extra: Vec<uint32>;
}

export interface Painted {
	alternate: boolean;
	rows: Vec<Row>;
	palette: Palette | null;
}

export struct Palette { fg: Rgb; bg: Rgb; }

function ok(r: GhosttyResult): boolean {
	return r == GhosttyResult.GHOSTTY_SUCCESS;
}

const HOLD_LIMIT_MS = 1000;

// What the terminal's callbacks leave for the host: the replies to send to the pty, the events since
// the last take, an OSC 52 write and an OSC 52 read waiting for its answer.
export interface Effects {
	state: GhosttyRenderState;
	replies: Vec<uint8>;
	bells: int32;
	titleChanged: boolean;
	pwdChanged: boolean;
	held: boolean;
	heldAtMs: number;
	holdLimitMs: number;
	clipboard: string | null;
	readFrame: Vec<uint8> | null;
	readAsked: boolean;
}

export function openEffects(terminal: GhosttyTerminal, state: GhosttyRenderState): Effects | null {
	const e: Effects = {
		state: state,
		replies: [],
		bells: 0,
		titleChanged: false,
		pwdChanged: false,
		held: false,
		heldAtMs: 0,
		holdLimitMs: HOLD_LIMIT_MS,
		clipboard: null,
		readFrame: null,
		readAsked: false,
	};
	if (vtEffectsWire(terminal, Handle.borrow(e).ptr) != 0) {
		closeEffects(terminal);
		return null;
	}
	return e;
}

export function closeEffects(terminal: GhosttyTerminal): void {
	const _cleared = vtEffectsWire(terminal, null);
}

function effectsAt(p: Ptr<void>): Effects {
	return Handle.at<Effects>(p).value();
}

@exportName("haroVtWritePty")
function writePty(effects: Ptr<void>, bytes: Ptr<uint8>, n: uint64): void {
	const e = effectsAt(effects);
	for (let i = 0; i < (n as int32); i++) { e.replies.push(bytes[i]); }
}

@exportName("haroVtBell")
function bell(terminal: GhosttyTerminal, effects: Ptr<void>): void {
	effectsAt(effects).bells += 1;
}

@exportName("haroVtTitleChanged")
function titleChanged(terminal: GhosttyTerminal, effects: Ptr<void>): void {
	effectsAt(effects).titleChanged = true;
}

@exportName("haroVtPwdChanged")
function pwdChanged(terminal: GhosttyTerminal, effects: Ptr<void>): void {
	effectsAt(effects).pwdChanged = true;
}

@exportName("haroVtRenderHold")
function renderHold(terminal: GhosttyTerminal, effects: Ptr<void>, held: boolean): void {
	const e = effectsAt(effects);
	e.held = held;
	if (!held) { return; }
	const _captured = ghostty_render_state_update(e.state, terminal);
	e.heldAtMs = performance.now();
}

@exportName("haroVtClipboardWritten")
function clipboardWritten(effects: Ptr<void>, text: Ptr<uint8>, n: uint64): void {
	let bytes: Vec<uint8> = [];
	for (let i = 0; i < (n as int32); i++) { bytes.push(text[i]); }
	effectsAt(effects).clipboard = bytes[0..bytes.length].asString();
}

@exportName("haroVtRepliesLength")
function repliesLength(effects: Ptr<void>): int64 {
	return effectsAt(effects).replies.length;
}

const OSC52_REPLY = "\x1b]52;";

// An OSC 52 read cannot wait for the user inside vt_write: the reply must be given before the callback
// returns. So the callback answers "denied", which makes libghostty write an empty clipboard reply
// ("ESC ] 52 ; c ;" and the terminator the program used) after mark; this takes those bytes back out
// of the replies and keeps them, and answerClipboard later writes the same frame with the clipboard in
// it, or empty. A request while one is pending, or one whose reply is not that frame (kitty's OSC 5522
// protocol), keeps its refusal.
@exportName("haroVtClipboardRead")
function clipboardRead(effects: Ptr<void>, mark: int64): void {
	const e = effectsAt(effects);
	const from = mark as int32;
	if (e.readFrame !== null || e.replies.length - from < 8) { return; }
	const prefix = OSC52_REPLY.asBytes();
	for (let i = 0; i < prefix.length; i++) {
		if (e.replies[from + i] != prefix[i]) { return; }
	}
	let frame: Vec<uint8> = [];
	for (let i = from; i < e.replies.length; i++) { frame.push(e.replies[i]); }
	e.replies.shrink(from);
	e.readFrame = frame;
	e.readAsked = true;
}

// Moves up to buf.length reply bytes into buf, oldest first.
export function takeReplies(this e: Effects, buf: Span<uint8>): int32 {
	const n = e.replies.length < buf.length ? e.replies.length : buf.length;
	for (let i = 0; i < n; i++) { buf[i] = e.replies[i]; }
	let rest: Vec<uint8> = [];
	for (let i = n; i < e.replies.length; i++) { rest.push(e.replies[i]); }
	e.replies = rest;
	return n;
}

// The text of the last OSC 52 write to the standard clipboard that the host has not taken.
export function takeClipboard(this e: Effects): string | null {
	const text = e.clipboard;
	e.clipboard = null;
	return text;
}

// True once per OSC 52 read that waits for an answer.
export function clipboardAsked(this e: Effects): boolean {
	const asked = e.readAsked;
	e.readAsked = false;
	return asked;
}

const BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".asBytes();
const PAD: uint8 = 0x3d;
const SEMICOLON: uint8 = 0x3b;

function pushBase64(ref out: Vec<uint8>, bytes: Readonly<Span<uint8>>): void {
	for (let i = 0; i < bytes.length; i += 3) {
		let v = (bytes[i] as uint32) << 16;
		if (i + 1 < bytes.length) { v |= (bytes[i + 1] as uint32) << 8; }
		if (i + 2 < bytes.length) { v |= bytes[i + 2] as uint32; }
		out.push(BASE64[((v >> 18) & 63) as int32]);
		out.push(BASE64[((v >> 12) & 63) as int32]);
		out.push(i + 1 < bytes.length ? BASE64[((v >> 6) & 63) as int32] : PAD);
		out.push(i + 2 < bytes.length ? BASE64[(v & 63) as int32] : PAD);
	}
}

// Writes the reply the waiting read expects: the clipboard text when allow is set, else empty. False
// when no read waits.
export function answerClipboard(this e: Effects, text: string, allow: boolean): boolean {
	const frame = e.readFrame;
	if (frame === null) { return false; }
	let head = 0;
	let semicolons = 0;
	while (head < frame.length && semicolons < 2) {
		if (frame[head] == SEMICOLON) { semicolons++; }
		head++;
	}
	for (let i = 0; i < head; i++) { e.replies.push(frame[i]); }
	if (allow) { pushBase64(e.replies, text.asBytes()); }
	for (let i = head; i < frame.length; i++) { e.replies.push(frame[i]); }
	e.readFrame = null;
	return true;
}

export const SCROLLBACK_LINES: int64 = 10000;
const SCROLLBACK_MAX_BYTES: uint64 = 50000000;

const MODE_DECCKM: uint16 = 1;
const MODE_CURSOR_BLINKING: uint16 = 12;
const MODE_FOCUS_EVENT: uint16 = 1004;
const MODE_ALT_SCROLL: uint16 = 1007;
const MODE_BRACKETED_PASTE: uint16 = 2004;

function colorsSet(terminal: GhosttyTerminal, fg: Rgb, bg: Rgb): boolean {
	let f: GhosttyColorRgb = { r: fg.r, g: fg.g, b: fg.b };
	let b: GhosttyColorRgb = { r: bg.r, g: bg.g, b: bg.b };
	return ok(setColor(terminal, GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, f))
		&& ok(setColor(terminal, GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, b));
}

// Blinking is what a fresh terminal starts in and what DECSCUSR 0 returns to. The blink mode is not
// configurable as a reset default, so a full reset (RIS) goes back to a steady cursor.
function blinkDefaultSet(terminal: GhosttyTerminal, on: boolean): boolean {
	let mode: GhosttyTerminalModeConfig = { mode: MODE_CURSOR_BLINKING, value: on };
	let blink = on;
	return ok(setMode(terminal, GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_MODE, mode))
		&& ok(setFlag(terminal, GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, blink));
}

function scrollbackSet(terminal: GhosttyTerminal, lines: int64): boolean {
	let bytes = SCROLLBACK_MAX_BYTES;
	let kept = lines as uint64;
	return ok(setSize(terminal, GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, bytes))
		&& ok(setSize(terminal, GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, kept));
}

function modeOn(terminal: GhosttyTerminal, mode: uint16): boolean | null {
	let m: GhosttyTerminalModeConfig = { mode: mode, value: false };
	if (!ok(terminalMode(terminal, GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_MODE, m))) { return null; }
	return m.value;
}

export function create(this typeof Vt, cols: int32, rows: int32): Result<Vt, VtError> {
	let terminal: GhosttyTerminal;
	if (!ok(ghostty_terminal_new(vtAllocator(), terminal, cols as uint16, rows as uint16))) {
		return Result.err(VtError.CreateFailed);
	}
	let state: GhosttyRenderState;
	let iterator: GhosttyRenderStateRowIterator;
	let cells: GhosttyRenderStateRowCells;
	if (
		!ok(ghostty_render_state_new(vtAllocator(), state)) ||
		!ok(ghostty_render_state_row_iterator_new(vtAllocator(), iterator)) ||
		!ok(ghostty_render_state_row_cells_new(vtAllocator(), cells))
	) {
		ghostty_terminal_free(terminal);
		return Result.err(VtError.CreateFailed);
	}
	const effects = openEffects(terminal, state);
	let top: GhosttyTrackedGridRef;
	if (effects === null || vtTopTrack(terminal, top) != 0
		|| !colorsSet(terminal, { r: 255, g: 255, b: 255 }, { r: 0, g: 0, b: 0 })
		|| !blinkDefaultSet(terminal, true) || !scrollbackSet(terminal, SCROLLBACK_LINES)) {
		if (effects !== null) { closeEffects(terminal); }
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
		mouse: { encoder: null, event: null, signature: -1, geometry: null },
		top: top,
		painted: { alternate: false, rows: [], palette: null },
	});
}

export function write(this vt: Vt, bytes: Span<uint8>): void {
	vtWriteBytes(vt.terminal, bytes);
}

export function writeText(this vt: Vt, text: string): void {
	vtWriteBytes(vt.terminal, text.asBytes());
}

export function replies(this vt: Vt, buf: Span<uint8>): Result<int32, VtError> {
	return Result.ok(vt.effects.takeReplies(buf));
}

export struct VtEvents {
	bells: int32;
	titleChanged: boolean;
	pwdChanged: boolean;
}

export function takeEvents(this vt: Vt): Result<VtEvents, VtError> {
	const e = vt.effects;
	const events: VtEvents = { bells: e.bells, titleChanged: e.titleChanged, pwdChanged: e.pwdChanged };
	e.bells = 0;
	e.titleChanged = false;
	e.pwdChanged = false;
	return Result.ok(events);
}

function stringOf(terminal: GhosttyTerminal, key: GhosttyTerminalData): Result<string, VtError> {
	let buf: Vec<uint8> = new Array(256);
	let n = vtString(terminal, key, buf);
	if (n > (buf.length as int64)) {
		buf = new Array(n as int32);
		n = vtString(terminal, key, buf);
	}
	if (n < 0) { return Result.err(VtError.ReadFailed); }
	return Result.ok(buf[0..(n as int32)].asString());
}

export function title(this vt: Vt): Result<string, VtError> {
	return stringOf(vt.terminal, GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_TITLE);
}

// The OSC 8 URI of the viewport cell at x, y, or null when the cell has none.
export function linkAt(this vt: Vt, x: int32, y: int32): Result<string | null, VtError> {
	let at: GhosttyGridRef;
	if (!ok(vtGridRef(vt.terminal, GhosttyPointTag.GHOSTTY_POINT_TAG_VIEWPORT, x, y, at))) {
		return Result.err(VtError.ReadFailed);
	}
	let buf: Vec<uint8> = new Array(256);
	let len: uint64 = 0;
	let r = gridRefLink(at, buf, len);
	if (r == GhosttyResult.GHOSTTY_OUT_OF_SPACE) {
		buf = new Array(len as int32);
		r = gridRefLink(at, buf, len);
	}
	if (!ok(r)) { return Result.err(VtError.ReadFailed); }
	if (len == 0) { return Result.ok(null); }
	const uri: string | null = buf[0..(len as int32)].asString();
	return Result.ok(uri);
}

export function pwd(this vt: Vt): Result<string, VtError> {
	return stringOf(vt.terminal, GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_PWD);
}

export function resize(this vt: Vt, cols: int32, rows: int32): Result<Vt, VtError> {
	const r = ghostty_terminal_resize(vt.terminal, cols as uint16, rows as uint16, 0, 0);
	if (!ok(r)) { return Result.err(VtError.ResizeFailed); }
	vt.painted.rows = [];
	vt.painted.palette = null;
	return Result.ok(vt);
}

export function setDefaultColors(this vt: Vt, fg: Rgb, bg: Rgb): Result<Vt, VtError> {
	if (!colorsSet(vt.terminal, fg, bg)) { return Result.err(VtError.ReadFailed); }
	return Result.ok(vt);
}

// The built-in palette with its first entries replaced by colors, as the colours a program's SGR 30-37,
// 90-97 and 38;5 indices name.
export function setPalette(this vt: Vt, colors: Readonly<Span<Rgb>>): Result<Vt, VtError> {
	const option = GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE;
	let palette: Colors256;
	if (colors.length > 256 || !ok(unset(vt.terminal, option, null))
		|| !ok(terminalColors(vt.terminal, GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, palette))) {
		return Result.err(VtError.ReadFailed);
	}
	for (let i = 0; i < colors.length; i++) { palette.c[i] = { r: colors[i].r, g: colors[i].g, b: colors[i].b }; }
	if (!ok(setColors(vt.terminal, option, palette))) { return Result.err(VtError.ReadFailed); }
	vt.painted.rows = [];
	return Result.ok(vt);
}

export function setScrollback(this vt: Vt, lines: int64): Result<Vt, VtError> {
	if (!scrollbackSet(vt.terminal, lines)) { return Result.err(VtError.ReadFailed); }
	return Result.ok(vt);
}

export function setPullScrollback(this vt: Vt, pull: boolean): Result<Vt, VtError> {
	let on = pull;
	if (!ok(setFlag(vt.terminal, GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_RESIZE_PULL_SCROLLBACK, on))) {
		return Result.err(VtError.ReadFailed);
	}
	return Result.ok(vt);
}

export function takeClipboard(this vt: Vt): Result<string | null, VtError> {
	return Result.ok(vt.effects.takeClipboard());
}

export function clipboardAsked(this vt: Vt): boolean {
	return vt.effects.clipboardAsked();
}

export function answerClipboard(this vt: Vt, text: string, allow: boolean): Result<Vt, VtError> {
	if (!vt.effects.answerClipboard(text, allow)) { return Result.err(VtError.ReadFailed); }
	return Result.ok(vt);
}

const MODE_SYNC_OUTPUT: uint16 = 2026;

// Whether synchronized output holds the screen. A hold older than the limit ends here: the terminal has
// no clock and a program that never releases would freeze the screen (terminal.h, "Timeouts").
export function holding(this vt: Vt): boolean {
	const e = vt.effects;
	if (!e.held) { return false; }
	if (performance.now() - e.heldAtMs < e.holdLimitMs) { return true; }
	let mode: GhosttyTerminalModeConfig = { mode: MODE_SYNC_OUTPUT, value: false };
	const _released = setMode(vt.terminal, GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_MODE, mode);
	e.held = false;
	return false;
}

export function holdLimit(this vt: Vt, ms: int64): void {
	vt.effects.holdLimitMs = ms as number;
}

export function update(this vt: Vt): Result<Vt, VtError> {
	if (vt.holding()) { return Result.ok(vt); }
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
	wide: boolean;
}

export function cursor(this vt: Vt): Result<Cursor | null, VtError> {
	const hasKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE;
	let hasValue = false;
	if (!ok(stateFlag(vt.state, hasKey, hasValue))) {
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
	let tail = false;
	const tailKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL;
	if (!ok(stateFlag(vt.state, tailKey, tail))) { return Result.err(VtError.ReadFailed); }
	if (tail) {
		const onTail: Cursor | null = { x: (x as int32) - 1, y: y as int32, wide: true };
		return Result.ok(onTail);
	}
	let under: GhosttyGridRef;
	let cell: GhosttyCell = 0;
	let wide = GhosttyCellWide.GHOSTTY_CELL_WIDE_NARROW;
	if (!ok(vtGridRef(vt.terminal, GhosttyPointTag.GHOSTTY_POINT_TAG_VIEWPORT, x as int32, y as int32, under))
		|| !ok(gridRefCell(under, cell)) || !ok(cellWide(cell, GhosttyCellData.GHOSTTY_CELL_DATA_WIDE, wide))) {
		return Result.err(VtError.ReadFailed);
	}
	const at: Cursor | null = { x: x as int32, y: y as int32, wide: wide == GhosttyCellWide.GHOSTTY_CELL_WIDE_WIDE };
	return Result.ok(at);
}

export enum CursorShape {
	Bar,
	Block,
	Underline,
	BlockHollow,
}

export struct CursorLook {
	visible: boolean;
	shape: CursorShape;
	blinking: boolean;
}

// Reads the render state, so it describes the frame the last update captured.
export function cursorLook(this vt: Vt): Result<CursorLook, VtError> {
	let visible = false;
	let blinking = false;
	let style: GhosttyRenderStateCursorVisualStyle;
	if (!ok(stateFlag(vt.state, GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, visible))
		|| !ok(stateCursorStyle(vt.state, GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, style))
		|| !ok(stateFlag(vt.state, GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, blinking))) {
		return Result.err(VtError.ReadFailed);
	}
	const shape = style as int32;
	if (shape < 0 || shape > (CursorShape.BlockHollow as int32)) { return Result.err(VtError.ReadFailed); }
	return Result.ok({ visible: visible, shape: shape as CursorShape, blinking: blinking });
}

export struct Modes {
	focusEvents: boolean;
	bracketedPaste: boolean;
	altScroll: boolean;
	cursorKeys: boolean;
	mouseTracking: boolean;
}

export function modes(this vt: Vt): Result<Modes, VtError> {
	const focusEvents = modeOn(vt.terminal, MODE_FOCUS_EVENT);
	const bracketedPaste = modeOn(vt.terminal, MODE_BRACKETED_PASTE);
	const altScroll = modeOn(vt.terminal, MODE_ALT_SCROLL);
	const cursorKeys = modeOn(vt.terminal, MODE_DECCKM);
	let tracking = false;
	if (focusEvents === null || bracketedPaste === null || altScroll === null || cursorKeys === null
		|| !ok(terminalFlag(vt.terminal, GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, tracking))) {
		return Result.err(VtError.ReadFailed);
	}
	return Result.ok({
		focusEvents: focusEvents,
		bracketedPaste: bracketedPaste,
		altScroll: altScroll,
		cursorKeys: cursorKeys,
		mouseTracking: tracking,
	});
}

// 0 bytes when the program has not asked for focus events.
export function focusReport(this vt: Vt, gained: boolean, buf: Span<uint8>): Result<int32, VtError> {
	const on = modeOn(vt.terminal, MODE_FOCUS_EVENT);
	if (on === null) { return Result.err(VtError.ReadFailed); }
	if (!on) { return Result.ok(0); }
	const event = gained ? GhosttyFocusEvent.GHOSTTY_FOCUS_GAINED : GhosttyFocusEvent.GHOSTTY_FOCUS_LOST;
	let written: uint64 = 0;
	if (!ok(focusEncode(event, buf, written))) { return Result.err(VtError.ReadFailed); }
	return Result.ok(written as int32);
}

export enum MouseAction {
	Press,
	Release,
	Motion,
}

export struct MouseInput {
	action: MouseAction;
	button: int32;
	mods: BitSet<KeyMod>;
	x: float32;
	y: float32;
}

export struct MouseGeometry {
	cellWidth: int32;
	cellHeight: int32;
	width: int32;
	height: int32;
}

const MOUSE_MODES: uint16[] = [9, 1000, 1002, 1003, 1005, 1006, 1015, 1016];

// Which mouse modes are on, as bits: changes exactly when the encoder's options would.
function mouseSignature(terminal: GhosttyTerminal): int32 | null {
	let signature = 0;
	for (let i = 0; i < MOUSE_MODES.length; i++) {
		const on = modeOn(terminal, MOUSE_MODES[i]);
		if (on === null) { return null; }
		if (on) { signature |= 1 << i; }
	}
	let tracking = false;
	if (!ok(terminalFlag(terminal, GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, tracking))) {
		return null;
	}
	return tracking ? signature | (1 << MOUSE_MODES.length) : signature;
}

function mouseOpen(m: Mouse): boolean {
	if (m.encoder !== null && m.event !== null) { return true; }
	let encoder: GhosttyMouseEncoder;
	let event: GhosttyMouseEvent;
	if (!ok(ghostty_mouse_encoder_new(vtAllocator(), encoder))) { return false; }
	if (!ok(ghostty_mouse_event_new(vtAllocator(), event))) {
		ghostty_mouse_encoder_free(encoder);
		return false;
	}
	let track = true;
	mouseSetFlag(encoder, GhosttyMouseEncoderOption.GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, track);
	m.encoder = encoder;
	m.event = event;
	return true;
}

function sameGeometry(a: MouseGeometry | null, b: MouseGeometry): boolean {
	return a !== null && a.cellWidth == b.cellWidth && a.cellHeight == b.cellHeight && a.width == b.width
		&& a.height == b.height;
}

// The report for one pointer event under the modes the program set: 0 bytes when the mode reports
// nothing for it (a motion within the cell it last reported, for one). x and y are surface pixels with
// the grid at the origin.
export function mouseReport(
	this vt: Vt,
	e: MouseInput,
	g: MouseGeometry,
	anyPressed: boolean,
	buf: Span<uint8>,
): Result<int32, VtError> {
	const m = vt.mouse;
	const signature = mouseSignature(vt.terminal);
	if (signature === null || !mouseOpen(m)) { return Result.err(VtError.ReadFailed); }
	const encoder = m.encoder;
	const event = m.event;
	if (encoder === null || event === null) { return Result.err(VtError.ReadFailed); }
	if (signature != m.signature) {
		ghostty_mouse_encoder_setopt_from_terminal(encoder, vt.terminal);
		m.signature = signature;
	}
	if (!sameGeometry(m.geometry, g)) {
		let size: GhosttyMouseEncoderSize = {
			size: sizeof GhosttyMouseEncoderSize,
			screen_width: g.width as uint32,
			screen_height: g.height as uint32,
			cell_width: g.cellWidth as uint32,
			cell_height: g.cellHeight as uint32,
		};
		mouseSetSize(encoder, GhosttyMouseEncoderOption.GHOSTTY_MOUSE_ENCODER_OPT_SIZE, size);
		m.geometry = g;
	}
	let pressed = anyPressed;
	mouseSetFlag(encoder, GhosttyMouseEncoderOption.GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, pressed);
	mouseSetAction(event, e.action as int32);
	if (e.button == 0) {
		ghostty_mouse_event_clear_button(event);
	} else {
		mouseSetButton(event, e.button);
	}
	mouseSetMods(event, modsMask(e.mods) as uint16);
	ghostty_mouse_event_set_position(event, { x: e.x, y: e.y });
	let written: uint64 = 0;
	if (!ok(mouseEncode(encoder, event, buf, written))) { return Result.err(VtError.ReadFailed); }
	return Result.ok(written as int32);
}

function rgb(c: GhosttyColorRgb): Rgb {
	return { r: c.r, g: c.g, b: c.b };
}

export function palette(this vt: Vt): Result<Palette, VtError> {
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

function graphemesOf(
	cells: GhosttyRenderStateRowCells,
	count: uint32,
	ref extra: Vec<uint32>,
): Result<uint32, VtError> {
	if (count <= MAX_GRAPHEMES) {
		let graphemes: Graphemes = { cp: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] };
		const bufKey = GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF;
		if (!ok(cellGraphemes(cells, bufKey, graphemes))) { return Result.err(VtError.ReadFailed); }
		for (let i = 1; i < (count as int32); i++) { extra.push(graphemes.cp[i]); }
		return Result.ok(graphemes.cp[0]);
	}
	if (count > MAX_CELL_EXTRA) { return Result.err(VtError.GraphemeTooLong); }
	let all: Vec<uint32> = new Array(count as int32);
	const bufKey = GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF;
	if (!ok(cellGraphemesInto(cells, bufKey, all as Span<uint32> as Ptr<uint32>))) { return Result.err(VtError.ReadFailed); }
	for (let i = 1; i < (count as int32); i++) { extra.push(all[i]); }
	return Result.ok(all[0]);
}

// The cell's SGR 58 underline colour with a palette index resolved, or null when the cell has none
// (the text colour applies, generic.zig `underlineColor(...) orelse fg`).
function underlineColorOf(state: GhosttyRenderState, style: GhosttyStyle): Result<Rgb | null, VtError> {
	const color = style.underline_color;
	if (color.tag == GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_RGB) {
		const found: Rgb | null = rgb(color.value.rgb);
		return Result.ok(found);
	}
	if (color.tag != GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_PALETTE) { return Result.ok(null); }
	let palette: Colors256;
	if (!ok(stateColors(state, GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_COLOR_PALETTE, palette))) {
		return Result.err(VtError.ReadFailed);
	}
	const found: Rgb | null = rgb(palette.c[color.value.palette]);
	return Result.ok(found);
}

function readCell(
	state: GhosttyRenderState,
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
			underlineColor: null,
		});
	}
	const base = try graphemesOf(cells, count, extra);
	const fgKey = GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR;
	const fg = colorOr(cells, fgKey, colors.fg);
	let flags = none;
	let underline = Underline.None;
	let underlineColor: Rgb | null = null;
	let styled = false;
	const styledKey = GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING;
	if (!ok(cellHasStyling(cells, styledKey, styled))) { return Result.err(VtError.ReadFailed); }
	if (styled) {
		let style: GhosttyStyle;
		styleDefault(style);
		style.size = sizeof GhosttyStyle;
		const styleKey = GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE;
		if (!ok(cellStyle(cells, styleKey, style))) { return Result.err(VtError.ReadFailed); }
		flags = styleFlags(style);
		underline = underlineOf(style);
		if (underline != Underline.None) { underlineColor = try underlineColorOf(state, style); }
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
): Result<Row, VtError> {
	let cells = vt.cells;
	const cellsKey = GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS;
	if (!ok(rowCells(iterator, cellsKey, cells))) { return Result.err(VtError.ReadFailed); }
	let row: Row = { y: y, cells: [], extra: [] };
	while (ghostty_render_state_row_cells_next(cells)) {
		const cell = try readCell(vt.state, cells, colors, row.extra);
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

function isScalar(cp: uint32): boolean {
	return cp <= 0x10FFFF && (cp < 0xD800 || cp > 0xDFFF);
}

export function text(this row: Row): Result<string, VtError> {
	let text = "";
	let e = 0;
	for (const cell of row.cells) {
		if (cell.cp == 0) {
			text += " ";
			continue;
		}
		if (!isScalar(cell.cp)) { return Result.err(VtError.CodepointInvalid); }
		text += fromCodePoint(cell.cp as number);
		for (let i = 0; i < (cell.extra as int32); i++) {
			const cp = row.extra[e + i];
			if (!isScalar(cp)) { return Result.err(VtError.CodepointInvalid); }
			text += fromCodePoint(cp as number);
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

export function scrollOffset(this vt: Vt): Result<int32, VtError> {
	let bar: GhosttyTerminalScrollbar;
	const key = GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_SCROLLBAR;
	if (!ok(terminalScrollbar(vt.terminal, key, bar))) { return Result.err(VtError.ReadFailed); }
	return Result.ok(bar.offset as int32);
}

export function alternateScreen(this vt: Vt): Result<boolean, VtError> {
	let screen = GhosttyTerminalScreen.GHOSTTY_TERMINAL_SCREEN_PRIMARY;
	const key = GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN;
	if (!ok(terminalScreen(vt.terminal, key, screen))) { return Result.err(VtError.ReadFailed); }
	return Result.ok(screen == GhosttyTerminalScreen.GHOSTTY_TERMINAL_SCREEN_ALTERNATE);
}

export function anchoredRow(this vt: Vt): Result<int32 | null, VtError> {
	let at: GhosttyPointCoordinate = { x: 0, y: 0 };
	const r = ghostty_tracked_grid_ref_point(vt.top, GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN, at);
	if (r == GhosttyResult.GHOSTTY_NO_VALUE) { return Result.ok(null); }
	if (!ok(r)) { return Result.err(VtError.ReadFailed); }
	const row: int32 | null = at.y as int32;
	return Result.ok(row);
}

export function anchorTop(this vt: Vt): Result<Vt, VtError> {
	if (vtTopAnchor(vt.top, vt.terminal) != 0) { return Result.err(VtError.ReadFailed); }
	return Result.ok(vt);
}

export function clean(this vt: Vt): void {
	ghostty_render_state_clean(vt.state);
}

export function free(this vt: Vt): void {
	ghostty_tracked_grid_ref_free(vt.top);
	closeEffects(vt.terminal);
	const encoder = vt.mouse.encoder;
	const event = vt.mouse.event;
	if (encoder !== null) { ghostty_mouse_encoder_free(encoder); }
	if (event !== null) { ghostty_mouse_event_free(event); }
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
	if (!ok(ghostty_key_encoder_new(vtAllocator(), encoder))) {
		return Result.err(KeysError.OpenFailed);
	}
	let event: GhosttyKeyEvent;
	if (!ok(ghostty_key_event_new(vtAllocator(), event))) {
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

export function scrollLines(this vt: Vt, rows: int32): void {
	vtScroll(vt.terminal, GhosttyTerminalScrollViewportTag.GHOSTTY_SCROLL_VIEWPORT_DELTA, rows as int64);
}

export function scrollPages(this vt: Vt, pages: int32): Result<Vt, VtError> {
	let bar: GhosttyTerminalScrollbar;
	const key = GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_SCROLLBAR;
	if (!ok(terminalScrollbar(vt.terminal, key, bar))) { return Result.err(VtError.ReadFailed); }
	const delta = (pages as int64) * (bar.len as int64);
	vtScroll(vt.terminal, GhosttyTerminalScrollViewportTag.GHOSTTY_SCROLL_VIEWPORT_DELTA, delta);
	return Result.ok(vt);
}

// Scroll the viewport so the nearest prompt (OSC 133 A) above (delta < 0) or below (delta > 0) its top
// row is the top row, as Surface.zig `jump_to_prompt` does. False when there is no such prompt.
export function jumpToPrompt(this vt: Vt, delta: int32): Result<boolean, VtError> {
	let bar: GhosttyTerminalScrollbar;
	const key = GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_SCROLLBAR;
	if (delta == 0 || !ok(terminalScrollbar(vt.terminal, key, bar))) { return Result.err(VtError.ReadFailed); }
	const step: int64 = delta < 0 ? -1 : 1;
	for (let y = (bar.offset as int64) + step; y >= 0 && y < (bar.total as int64); y += step) {
		let at: GhosttyGridRef;
		let row: GhosttyRow = 0;
		let prompt = GhosttyRowSemanticPrompt.GHOSTTY_ROW_SEMANTIC_NONE;
		if (!ok(vtGridRef(vt.terminal, GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN, 0, y as int32, at))
			|| !ok(gridRefRow(at, row))
			|| !ok(rowPrompt(row, GhosttyRowData.GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, prompt))) {
			return Result.err(VtError.ReadFailed);
		}
		if (prompt == GhosttyRowSemanticPrompt.GHOSTTY_ROW_SEMANTIC_PROMPT) {
			vtScroll(vt.terminal, GhosttyTerminalScrollViewportTag.GHOSTTY_SCROLL_VIEWPORT_ROW, y);
			return Result.ok(true);
		}
	}
	return Result.ok(false);
}

export function scrollTop(this vt: Vt): void {
	vtScroll(vt.terminal, GhosttyTerminalScrollViewportTag.GHOSTTY_SCROLL_VIEWPORT_TOP, 0);
}

export function scrollBottom(this vt: Vt): void {
	vtScroll(vt.terminal, GhosttyTerminalScrollViewportTag.GHOSTTY_SCROLL_VIEWPORT_BOTTOM, 0);
}

export function atBottom(this vt: Vt): Result<boolean, VtError> {
	let bar: GhosttyTerminalScrollbar;
	const key = GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_SCROLLBAR;
	if (!ok(terminalScrollbar(vt.terminal, key, bar))) { return Result.err(VtError.ReadFailed); }
	return Result.ok(bar.offset + bar.len >= bar.total);
}

function screenRef(terminal: GhosttyTerminal, at: Point): Result<GhosttyGridRef, VtError> {
	let gridRef: GhosttyGridRef;
	const r = vtGridRef(terminal, GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN, at.col, at.row, gridRef);
	if (!ok(r)) { return Result.err(VtError.SelectFailed); }
	return Result.ok(gridRef);
}

function screenPoint(terminal: GhosttyTerminal, gridRef: GhosttyGridRef): Result<Point, VtError> {
	let at = gridRef;
	let c: GhosttyPointCoordinate;
	if (!ok(pointOf(terminal, at, GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN, c))) {
		return Result.err(VtError.SelectFailed);
	}
	return Result.ok({ row: c.y as int32, col: c.x as int32 });
}

function markedOf(terminal: GhosttyTerminal, selection: GhosttySelection): Result<Marked, VtError> {
	let given = selection;
	let ordered: GhosttySelection = { size: sizeof GhosttySelection };
	const forward = GhosttySelectionOrder.GHOSTTY_SELECTION_ORDER_FORWARD;
	if (!ok(selectionOrdered(terminal, given, forward, ordered))) { return Result.err(VtError.SelectFailed); }
	const start = try screenPoint(terminal, ordered.start);
	const end = try screenPoint(terminal, ordered.end);
	return Result.ok({ range: { start: start, end: end }, block: selection.rectangle });
}

function rangeFound(terminal: GhosttyTerminal, r: GhosttyResult, selection: GhosttySelection): Result<Range | null, VtError> {
	if (r == GhosttyResult.GHOSTTY_NO_VALUE) { return Result.ok(null); }
	if (!ok(r)) { return Result.err(VtError.SelectFailed); }
	const m = try markedOf(terminal, selection);
	const found: Range | null = m.range;
	return Result.ok(found);
}

export function selectionSet(this vt: Vt, m: Marked): Result<Vt, VtError> {
	let selection: GhosttySelection = {
		size: sizeof GhosttySelection,
		start: try screenRef(vt.terminal, m.range.start),
		end: try screenRef(vt.terminal, m.range.end),
		rectangle: m.block,
	};
	const option = GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_SELECTION;
	if (!ok(setSelection(vt.terminal, option, selection))) { return Result.err(VtError.SelectFailed); }
	return Result.ok(vt);
}

export function selectionClear(this vt: Vt): void {
	const _cleared = unset(vt.terminal, GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_SELECTION, null);
}

export function selection(this vt: Vt): Result<Marked | null, VtError> {
	let selection: GhosttySelection = { size: sizeof GhosttySelection };
	const r = terminalSelection(vt.terminal, GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_SELECTION, selection);
	if (r == GhosttyResult.GHOSTTY_NO_VALUE) { return Result.ok(null); }
	if (!ok(r)) { return Result.err(VtError.SelectFailed); }
	const got: Marked | null = try markedOf(vt.terminal, selection);
	return Result.ok(got);
}

export function wordAt(this vt: Vt, at: Point): Result<Range | null, VtError> {
	let options: GhosttyTerminalSelectWordOptions = {
		size: sizeof GhosttyTerminalSelectWordOptions,
		ref: try screenRef(vt.terminal, at),
	};
	let selection: GhosttySelection = { size: sizeof GhosttySelection };
	return rangeFound(vt.terminal, selectWord(vt.terminal, options, selection), selection);
}

export function lineAt(this vt: Vt, at: Point): Result<Range | null, VtError> {
	let options: GhosttyTerminalSelectLineOptions = {
		size: sizeof GhosttyTerminalSelectLineOptions,
		ref: try screenRef(vt.terminal, at),
		semantic_prompt_boundary: true,
	};
	let selection: GhosttySelection = { size: sizeof GhosttySelection };
	return rangeFound(vt.terminal, selectLine(vt.terminal, options, selection), selection);
}

export function unitAt(this vt: Vt, unit: Unit, at: Point): Result<Range, VtError> {
	const here: Range = { start: at, end: at };
	if (unit == Unit.Cell) { return Result.ok(here); }
	if (unit == Unit.Line) {
		const line = try vt.lineAt(at);
		if (line === null) { return Result.ok(here); }
		return Result.ok(line);
	}
	const word = try vt.wordAt(at);
	if (word !== null) { return Result.ok(word); }
	if (at.col > 0) {
		const head = try vt.wordAt({ row: at.row, col: at.col - 1 });
		if (head !== null) { return Result.ok(head); }
	}
	return Result.ok(here);
}

// The active selection as plain text, the way Ghostty's Screen.selectionString copies it (unwrap and
// trim), or null when there is none.
export function selectedText(this vt: Vt): Result<string | null, VtError> {
	const options: GhosttyTerminalSelectionFormatOptions = {
		size: sizeof GhosttyTerminalSelectionFormatOptions,
		emit: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_PLAIN,
		unwrap: true,
		trim: true,
	};
	let buf: Vec<uint8> = new Array(4096);
	let written: uint64 = 0;
	let r = selectionFormat(vt.terminal, options, buf, written);
	if (r == GhosttyResult.GHOSTTY_OUT_OF_SPACE) {
		buf = new Array(written as int32);
		r = selectionFormat(vt.terminal, options, buf, written);
	}
	if (!ok(r)) { return Result.ok(null); }
	const text: string | null = buf[0..(written as int32)].asString();
	return Result.ok(text);
}

const PASTE_END = "\x1b[201~";

// Surface.zig completeClipboardPaste with its defaults: bracketed, the data is unsafe only when it holds
// the end marker; unbracketed, it is unsafe when it holds a newline.
export function pasteBytes(this vt: Vt, text: string, allowUnsafe: boolean): Result<Vec<uint8>, PasteError> {
	const bracketed = modeOn(vt.terminal, MODE_BRACKETED_PASTE) == true;
	const unsafe = bracketed ? text.includes(PASTE_END) : !pasteSafe(text.asBytes());
	if (unsafe && !allowUnsafe) { return Result.err(PasteError.Unsafe); }
	let data: Vec<uint8> = [];
	for (const b of text.asBytes()) { data.push(b); }
	let out: Vec<uint8> = new Array(data.length + 16);
	let written: uint64 = 0;
	if (!ok(pasteEncode(data, bracketed, out, written))) { return Result.err(PasteError.EncodeFailed); }
	out.shrink(written as int32);
	return Result.ok(out);
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

test "bells, a title and a pwd reach the host as events once each" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("a]2;build: ok]7;file:///C:/Users/me");
		const first = vt.takeEvents();
		assert first.ok;
		if (first.ok) {
			assert first.value.bells == 2;
			assert first.value.titleChanged;
			assert first.value.pwdChanged;
		}
		const title = vt.title();
		assert title.ok;
		if (title.ok) { assert title.value == "build: ok"; }
		const pwd = vt.pwd();
		assert pwd.ok;
		if (pwd.ok) { assert pwd.value == "file:///C:/Users/me"; }
		const second = vt.takeEvents();
		assert second.ok;
		if (second.ok) {
			assert second.value.bells == 0;
			assert !second.value.titleChanged;
			assert !second.value.pwdChanged;
		}
		vt.free();
	}
}

test "an untitled terminal has an empty title" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const title = vt.title();
		assert title.ok;
		if (title.ok) { assert title.value == ""; }
		vt.free();
	}
}

test "the input modes a program sets are readable, and a fresh terminal sets none but alternate scroll" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const fresh = vt.modes();
		assert fresh.ok;
		if (fresh.ok) {
			assert !fresh.value.focusEvents;
			assert !fresh.value.bracketedPaste;
			assert !fresh.value.cursorKeys;
			assert !fresh.value.mouseTracking;
			assert fresh.value.altScroll;
		}
		vt.writeText("[?1004h[?2004h[?1h[?1000h[?1007l");
		const set = vt.modes();
		assert set.ok;
		if (set.ok) {
			assert set.value.focusEvents;
			assert set.value.bracketedPaste;
			assert set.value.cursorKeys;
			assert set.value.mouseTracking;
			assert !set.value.altScroll;
		}
		vt.free();
	}
}

test "a focus change is reported only once the program asked for it" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		let buf: Vec<uint8> = new Array(16);
		const before = vt.focusReport(true, buf);
		assert before.ok;
		if (before.ok) { assert before.value == 0; }
		vt.writeText("[?1004h");
		const gained = vt.focusReport(true, buf);
		assert gained.ok;
		if (gained.ok) { assert ascii(buf[0..gained.value]) == "[I"; }
		const lost = vt.focusReport(false, buf);
		assert lost.ok;
		if (lost.ok) { assert ascii(buf[0..lost.value]) == "[O"; }
		vt.free();
	}
}

const CELLS: MouseGeometry = { cellWidth: 10, cellHeight: 20, width: 200, height: 80 };

function mouseBytes(vt: Vt, action: MouseAction, button: int32, mods: BitSet<KeyMod>, anyPressed: boolean): string {
	let buf: Vec<uint8> = new Array(32);
	const e: MouseInput = { action: action, button: button, mods: mods, x: 25.0, y: 25.0 };
	const n = vt.mouseReport(e, CELLS, anyPressed, buf);
	if (!n.ok) { return "error"; }
	return ascii(buf[0..n.value]);
}

test "a mouse event is silent until the program turns mouse reporting on" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const none = 0 as BitSet<KeyMod>;
		assert mouseBytes(vt, MouseAction.Press, 1, none, true) == "";
		vt.free();
	}
}

test "SGR reporting names the cell, the button and the modifiers" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const none = 0 as BitSet<KeyMod>;
		vt.writeText("[?1000h[?1006h");
		assert mouseBytes(vt, MouseAction.Press, 1, none, true) == "[<0;3;2M";
		assert mouseBytes(vt, MouseAction.Release, 1, none, false) == "[<0;3;2m";
		assert mouseBytes(vt, MouseAction.Press, 3, none, true) == "[<1;3;2M";
		assert mouseBytes(vt, MouseAction.Press, 4, none, false) == "[<64;3;2M";
		assert mouseBytes(vt, MouseAction.Press, 1, none.incl(KeyMod.Shift), true) == "[<4;3;2M";
		vt.free();
	}
}

test "motion is reported only under button or any-event tracking" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const none = 0 as BitSet<KeyMod>;
		vt.writeText("[?1000h[?1006h");
		assert mouseBytes(vt, MouseAction.Motion, 1, none, true) == "";
		vt.writeText("[?1002h");
		assert mouseBytes(vt, MouseAction.Motion, 1, none, true) == "[<32;3;2M";
		vt.writeText("[?1003h");
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "[<35;3;2M";
		vt.free();
	}
}

test "the same cell is not reported twice for motion, and SGR-pixels reports pixels" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const none = 0 as BitSet<KeyMod>;
		vt.writeText("[?1003h[?1006h");
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "[<35;3;2M";
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "";
		vt.writeText("[?1016h");
		assert mouseBytes(vt, MouseAction.Press, 1, none, true) == "[<0;25;25M";
		vt.free();
	}
}

test "a frame drawn under synchronized output shows only once the program ends the hold" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("one");
		assert vt.update().ok;
		vt.writeText("[?2026h[2J[Hhalf");
		assert vt.holding();
		assert vt.update().ok;
		const held = vt.lines();
		assert held.ok;
		if (held.ok) { assert held.value[0] == "one"; }
		vt.writeText(" drawn[?2026l");
		assert !vt.holding();
		assert vt.update().ok;
		const shown = vt.lines();
		assert shown.ok;
		if (shown.ok) { assert shown.value[0] == "half drawn"; }
		vt.free();
	}
}

test "a hold the program never ends is dropped after its limit" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.holdLimit(0);
		vt.writeText("[?2026hstuck");
		assert vt.update().ok;
		assert !vt.holding();
		const shown = vt.lines();
		assert shown.ok;
		if (shown.ok) { assert shown.value[0] == "stuck"; }
		vt.writeText("[?2026h");
		vt.holdLimit(1000);
		assert vt.holding();
		vt.free();
	}
}

function lookAfter(input: string): CursorLook | null {
	const created = Vt.create(20, 4);
	if (!created.ok) { return null; }
	const vt = created.value;
	vt.writeText(input);
	const updated = vt.update();
	const look = vt.cursorLook();
	vt.free();
	if (!updated.ok || !look.ok) { return null; }
	const found: CursorLook | null = look.value;
	return found;
}

test "a fresh cursor is a visible blinking block" {
	const look = lookAfter("");
	assert look !== null;
	if (look !== null) {
		assert look.visible;
		assert look.shape == CursorShape.Block;
		assert look.blinking;
	}
}

test "DECTCEM hides and shows the cursor" {
	const hidden = lookAfter("[?25l");
	assert hidden !== null;
	if (hidden !== null) { assert !hidden.visible; }
	const shown = lookAfter("[?25l[?25h");
	assert shown !== null;
	if (shown !== null) { assert shown.visible; }
}

test "DECSCUSR picks the cursor's shape and blink" {
	const bar = lookAfter("[5 q");
	assert bar !== null;
	if (bar !== null) {
		assert bar.shape == CursorShape.Bar;
		assert bar.blinking;
	}
	const underline = lookAfter("[4 q");
	assert underline !== null;
	if (underline !== null) {
		assert underline.shape == CursorShape.Underline;
		assert !underline.blinking;
	}
	const block = lookAfter("[6 q[2 q");
	assert block !== null;
	if (block !== null) {
		assert block.shape == CursorShape.Block;
		assert !block.blinking;
	}
}

function replyTo(query: string): string {
	const created = Vt.create(20, 4);
	if (!created.ok) { return "create failed"; }
	const vt = created.value;
	vt.writeText(query);
	let buf: Vec<uint8> = new Array(64);
	const n = vt.replies(buf);
	vt.free();
	if (!n.ok) { return "read failed"; }
	return ascii(buf[0..n.value]);
}

test "the device attributes and the version name Haro as a VT220 with colour and clipboard" {
	assert replyTo("[c") == "[?62;22;52c";
	assert replyTo("[>c") == "[>1;10;0c";
	assert replyTo("[>q") == "P>|haro\\";
}

test "the tertiary device attributes carry a zero unit id" {
	assert replyTo("[=c") == "P!|00000000\\";
}

test "a mode report names a mode set, reset and unknown" {
	assert replyTo("[?2004$p") == "[?2004;2$y";
	assert replyTo("[?2004h[?2004$p") == "[?2004;1$y";
	assert replyTo("[?9999$p") == "[?9999;0$y";
}

test "the colour queries answer with the host's default colours, a program's override and the palette" {
	assert replyTo("]11;?") == "]11;rgb:0000/0000/0000";
	assert replyTo("]10;?") == "]10;rgb:ffff/ffff/ffff";
	assert replyTo("]11;rgb:10/20/30]11;?") == "]11;rgb:1010/2020/3030";
	assert replyTo("]4;1;?") == "]4;1;rgb:cccc/6666/6666";
}

test "a theme the host sets is what a colour query reports" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		assert vt.setDefaultColors({ r: 0x28, g: 0x2c, b: 0x34 }, { r: 0xff, g: 0xff, b: 0xfe }).ok;
		vt.writeText("]11;?\\");
		let buf: Vec<uint8> = new Array(64);
		const n = vt.replies(buf);
		assert n.ok;
		if (n.ok) { assert ascii(buf[0..n.value]) == "]11;rgb:ffff/ffff/fefe\\"; }
		vt.free();
	}
}

function rowsAfterGrowing(pull: boolean): string {
	const created = Vt.create(10, 3);
	if (!created.ok) { return "create failed"; }
	const vt = created.value;
	vt.setPullScrollback(pull);
	vt.writeText("l1\r\nl2\r\nl3\r\nl4\r\nl5");
	vt.resize(10, 5);
	vt.update();
	const lines = vt.lines();
	vt.free();
	if (!lines.ok) { return "read failed"; }
	return lines.value.join("|");
}

function keptAfter(lines: int32, keep: int64): int32 {
	const created = Vt.create(20, 4);
	if (!created.ok) { return -1; }
	const vt = created.value;
	if (keep != SCROLLBACK_LINES && !vt.setScrollback(keep).ok) { return -1; }
	vt.writeText(numbered(lines));
	vt.scrollTop();
	if (!vt.update().ok) { return -1; }
	const oldest = top(vt);
	vt.free();
	return lines - (oldest.slice(1).parseInt() as int32);
}

test "scrollback keeps about ten thousand lines by default, and a set limit replaces it" {
	const byDefault = keptAfter(30000, SCROLLBACK_LINES);
	assert byDefault > 9000 && byDefault < 12000;
	const set = keptAfter(30000, 500);
	assert set > 400 && set < 2500;
}

test "growing the grid reveals scrollback unless the pty keeps its own screen" {
	assert rowsAfterGrowing(true) == "l1|l2|l3|l4|l5";
	assert rowsAfterGrowing(false) == "l3|l4|l5||";
}

test "an OSC 52 write reaches the host once, and only for the standard clipboard" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		const none = vt.takeClipboard();
		assert none.ok;
		if (none.ok) { assert none.value === null; }
		vt.writeText("]52;p;cHJpbWFyeQ==");
		const primary = vt.takeClipboard();
		assert primary.ok;
		if (primary.ok) { assert primary.value === null; }
		vt.writeText("]52;c;aGVsbG8gd29ybGQ=");
		const first = vt.takeClipboard();
		assert first.ok;
		if (first.ok) { assert first.value == "hello world"; }
		const second = vt.takeClipboard();
		assert second.ok;
		if (second.ok) { assert second.value === null; }
		vt.free();
	}
}

function linkText(vt: Vt, x: int32, y: int32): string {
	const link = vt.linkAt(x, y);
	if (!link.ok) { return "<failed>"; }
	const got = link.value;
	if (got !== null) { return got; }
	return "<none>";
}

test "an OSC 8 link answers for each of its cells and for no others" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("]8;;https://example.com/a?b=1\\link]8;;\\ plain");
		assert linkText(vt, 0, 0) == "https://example.com/a?b=1";
		assert linkText(vt, 3, 0) == "https://example.com/a?b=1";
		assert linkText(vt, 4, 0) == "<none>";
		assert linkText(vt, 0, 1) == "<none>";
		assert linkText(vt, 0, 40) == "<failed>";
		vt.free();
	}
}

function topAfterJump(vt: Vt, delta: int32): string {
	const jumped = vt.jumpToPrompt(delta);
	if (!jumped.ok) { return "<failed>"; }
	if (!jumped.value) { return "<none>"; }
	vt.update();
	const lines = vt.lines();
	if (!lines.ok) { return "<unreadable>"; }
	return lines.value[0];
}

test "the viewport jumps between OSC 133 prompts" {
	const created = Vt.create(10, 3);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("\x1b]133;A\x07p1
\r\nout1
\r\nout2
\r\n\x1b]133;A\x07p2
\r\nout3
\r\n\x1b]133;A\x07p3");
		vt.update();
		assert vt.lines().ok;
		assert topAfterJump(vt, -1) == "p1";
		assert topAfterJump(vt, -1) == "<none>";
		assert topAfterJump(vt, 1) == "p2";
		vt.free();
	}
}

test "a screen without prompt marks has nothing to jump to" {
	const created = Vt.create(10, 3);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("a
\r\nb
\r\nc
\r\nd
\r\ne");
		assert topAfterJump(vt, -1) == "<none>";
		assert topAfterJump(vt, 1) == "<none>";
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

test "a cluster of forty codepoints is one cell that keeps them all" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		let cluster = "a";
		for (let i = 0; i < 39; i++) { cluster += String.fromCharCode(0x301); }
		vt.writeText(cluster + "b");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const row = rows.value[0];
			assert row.cells[0].cp == 0x61;
			assert row.cells[0].extra == 39;
			assert row.cells[1].cp == 0x62;
			const text = row.text();
			assert text.ok;
			if (text.ok) { assert text.value.startsWith(cluster + "b"); }
		}
		vt.free();
	}
}

test "a character above the basic plane reads back whole" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("x😀");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			assert rows.value[0].cells[1].cp == 0x1F600;
			const text = rows.value[0].text();
			assert text.ok;
			if (text.ok) { assert text.value.startsWith("x😀"); }
		}
		vt.free();
	}
}

test "an underline carries the SGR 58 colour, resolved from the palette when it is an index" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("[4:3m[58;2;255;80;80ma[58;5;1mb[59mc[24;58;2;1;2;3md");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const cells = rows.value[0].cells;
			const rgb = cells[0].underlineColor;
			assert rgb !== null;
			if (rgb !== null) {
				assert rgb.r == 255;
				assert rgb.g == 80;
				assert rgb.b == 80;
			}
			const indexed = cells[1].underlineColor;
			assert indexed !== null;
			if (indexed !== null) { assert indexed.r > indexed.g && indexed.r > indexed.b && indexed.r != 255; }
			assert cells[2].underline == Underline.Curly;
			assert cells[2].underlineColor === null;
			assert cells[3].underline == Underline.None;
			assert cells[3].underlineColor === null;
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

test "a grapheme longer than the inline buffer arrives whole" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText(`e${"\u0301".repeat(20)}x`);
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const row = rows.value[0];
			assert row.cells[0].cp == 0x65;
			assert row.cells[0].extra == 20;
			assert row.extra.length == 20;
			assert row.extra[19] == 0x301;
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
		vt.writeText("a\nb");
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

test "AltGr text reaches the program as the text once the consumed Ctrl+Alt is dropped" {
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
			const brace: KeyEvent = {
				action: KeyAction.Press, key: "Digit7", mods: ctrlAlt, consumedMods: ctrlAlt, unshifted: 0x37, text: "{",
			};
			assert encoded(k, vt, brace.withoutAltGr()) == "{";
			const polish: KeyEvent = { ...brace, key: "KeyA", unshifted: 0x61, text: "ą" };
			assert encoded(k, vt, polish.withoutAltGr()) == "Ä";
			k.freeKeys();
		}
		vt.free();
	}
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

function cursorAfter(text: string): string {
	const created = Vt.create(20, 4);
	if (!created.ok) { return "create failed"; }
	const vt = created.value;
	vt.writeText(text);
	const updated = vt.update();
	const at = vt.cursor();
	vt.free();
	if (!updated.ok || !at.ok) { return "read failed"; }
	const c = at.value;
	if (c === null) { return "none"; }
	return `${c.x}${c.wide ? " wide" : ""}`;
}

test "a cursor on a wide character covers both its cells, from the character or its tail, as ghostty draws it" {
	assert cursorAfter("\u4e2d\x1b[1G") == "0 wide";
	assert cursorAfter("\u4e2d\x1b[2G") == "0 wide";
	assert cursorAfter("\u4e2d") == "2";
	assert cursorAfter("ab\x1b[2G") == "1";
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

function numbered(count: int32): string {
	let text = "r0";
	for (let i = 1; i < count; i++) { text += `\r\nr${i}`; }
	return text;
}

function newText(count: int32): string {
	let text = "";
	for (let i = 0; i < count; i++) { text += `
q${i}`; }
	return text;
}

function top(vt: Vt): string {
	const lines = vt.lines();
	if (lines.ok) { return lines.value[0]; }
	return "<unreadable>";
}

function at(row: int32, col: int32): Point {
	return { row: row, col: col };
}

function marked(r0: int32, c0: int32, r1: int32, c1: int32): Marked {
	return { range: { start: at(r0, c0), end: at(r1, c1) }, block: false };
}

function copied(vt: Vt): string {
	const text = vt.selectedText();
	if (!text.ok) { return "<failed>"; }
	const got = text.value;
	if (got !== null) { return got; }
	return "<none>";
}

test "the viewport scrolls by lines, pages, to the top and back to the bottom" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText(numbered(10));
		assert vt.update().ok;
		assert top(vt) == "r6";
		assert (try vt.atBottom() catch false);
		vt.scrollLines(-2);
		assert vt.update().ok;
		assert top(vt) == "r4";
		assert !(try vt.atBottom() catch true);
		assert (try vt.scrollOffset() catch -1) == 4;
		vt.scrollLines(1);
		assert vt.update().ok;
		assert top(vt) == "r5";
		vt.scrollTop();
		assert vt.update().ok;
		assert top(vt) == "r0";
		vt.scrollLines(-5);
		assert vt.update().ok;
		assert top(vt) == "r0";
		assert vt.scrollPages(1).ok;
		assert vt.update().ok;
		assert top(vt) == "r4";
		vt.scrollBottom();
		assert vt.update().ok;
		assert top(vt) == "r6";
		assert (try vt.atBottom() catch false);
		vt.scrollLines(5);
		assert vt.update().ok;
		assert top(vt) == "r6";
		vt.free();
	}
}

test "new output while scrolled up leaves the view where it was" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText(numbered(10));
		vt.scrollLines(-3);
		assert vt.update().ok;
		assert top(vt) == "r3";
		vt.writeText("\r\nr10\r\nr11\r\nr12\r\nr13\r\nr14");
		assert vt.update().ok;
		assert top(vt) == "r3";
		assert !(try vt.atBottom() catch true);
		vt.scrollBottom();
		assert vt.update().ok;
		assert top(vt) == "r11";
		vt.free();
	}
}

test "a selection across two wrapped rows copies one logical line" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("abcdefghijklmnop\r\nnext");
		assert vt.update().ok;
		assert vt.selectionSet(marked(0, 2, 1, 4)).ok;
		assert copied(vt) == "cdefghijklmno";
		assert vt.selectionSet(marked(0, 0, 2, 3)).ok;
		assert copied(vt) == "abcdefghijklmnop\nnext";
		vt.free();
	}
}

test "trailing spaces are trimmed on each copied line" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("hi   \r\nthere");
		assert vt.update().ok;
		assert vt.selectionSet(marked(0, 0, 1, 9)).ok;
		assert copied(vt) == "hi\nthere";
		vt.free();
	}
}

test "a double click picks the word under the pointer and a triple click the logical line" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("foo bar-baz qux again");
		assert vt.update().ok;
		const word = vt.unitAt(Unit.Word, at(0, 5));
		assert word.ok;
		if (word.ok) {
			assert word.value.start == at(0, 4);
			const sel = Selection.press(Unit.Word, word.value, false);
			assert vt.selectionSet(sel.marked()).ok;
			assert copied(vt) == "bar-baz";
		}
		const line = vt.unitAt(Unit.Line, at(1, 3));
		assert line.ok;
		if (line.ok) {
			assert line.value.start == at(0, 0);
			assert vt.selectionSet({ range: line.value, block: false }).ok;
			assert copied(vt) == "foo bar-baz qux again";
		}
		vt.free();
	}
}

test "a click on the second half of a wide character picks that character" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("中文 x");
		assert vt.update().ok;
		const first = vt.unitAt(Unit.Word, at(0, 1));
		assert first.ok;
		if (first.ok) {
			assert first.value.start == at(0, 0);
			assert vt.selectionSet({ range: first.value, block: false }).ok;
			assert copied(vt) == "中";
		}
		const second = vt.unitAt(Unit.Word, at(0, 3));
		assert second.ok;
		if (second.ok) {
			assert vt.selectionSet({ range: second.value, block: false }).ok;
			assert copied(vt) == "文";
		}
		vt.free();
	}
}

test "a selection survives five lines of new output" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText(numbered(4));
		assert vt.update().ok;
		assert vt.selectionSet(marked(1, 0, 2, 1)).ok;
		assert copied(vt) == "r1\nr2";
		vt.writeText("\r\nn0\r\nn1\r\nn2\r\nn3\r\nn4");
		assert vt.update().ok;
		const kept = vt.selection();
		assert kept.ok;
		if (kept.ok) {
			const m = kept.value;
			assert m !== null;
			if (m !== null) {
				assert m.range.start == at(1, 0);
				assert m.range.end == at(2, 1);
			}
		}
		assert copied(vt) == "r1\nr2";
		vt.free();
	}
}

test "a selection follows its text when scrollback is pruned" {
	const created = Vt.create(80, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		assert vt.setScrollback(1000).ok;
		vt.writeText(numbered(6000));
		assert vt.update().ok;
		const row = (try vt.scrollOffset() catch 0) + 3;
		assert vt.selectionSet(marked(row, 0, row, 5)).ok;
		assert copied(vt) == "r5999";
		vt.writeText(newText(400));
		assert vt.update().ok;
		const kept = vt.selection();
		assert kept.ok;
		if (kept.ok) {
			const m = kept.value;
			assert m !== null;
			if (m !== null) { assert m.range.start.row < row; }
		}
		assert copied(vt) == "r5999";
		vt.free();
	}
}

test "an erased selection is gone from the terminal" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("hello");
		assert vt.update().ok;
		assert vt.selectionSet(marked(0, 0, 0, 4)).ok;
		vt.selectionClear();
		const none = vt.selection();
		assert none.ok;
		if (none.ok) { assert none.value === null; }
		const text = vt.selectedText();
		assert text.ok;
		if (text.ok) { assert text.value === null; }
		vt.free();
	}
}

function pasted(vt: Vt, text: string, allowUnsafe: boolean): string {
	const bytes = vt.pasteBytes(text, allowUnsafe);
	if (bytes.ok) { return ascii(bytes.value); }
	return bytes.error == PasteError.Unsafe ? "<unsafe>" : "<failed>";
}

test "an unbracketed paste turns newlines into carriage returns and refuses them unconfirmed" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		assert pasted(vt, "hello", false) == "hello";
		assert pasted(vt, "a\nb", false) == "<unsafe>";
		assert pasted(vt, "a\nb", true) == "a\rb";
		vt.free();
	}
}

test "a bracketed paste is framed and only its end marker is unsafe" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("\x1b[?2004h");
		assert pasted(vt, "a\nb", false) == "\x1b[200~a\nb\x1b[201~";
		assert pasted(vt, "x\x1b[31my", false) == "\x1b[200~x [31my\x1b[201~";
		assert pasted(vt, "evil\x1b[201~rm", false) == "<unsafe>";
		vt.writeText("\x1b[?2004l");
		assert pasted(vt, "plain", false) == "plain";
		vt.free();
	}
}

function pending(vt: Vt): string {
	let buf: Vec<uint8> = new Array(128);
	const n = vt.replies(buf);
	if (!n.ok) { return "read failed"; }
	return ascii(buf[0..n.value]);
}

test "an OSC 52 read waits for the host and is answered in the frame the program used" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		assert !vt.clipboardAsked();
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert pending(vt) == "";
		assert vt.clipboardAsked();
		assert !vt.clipboardAsked();
		assert vt.answerClipboard("hello", true).ok;
		assert pending(vt) == "\x1b]52;c;aGVsbG8=\x1b\\";
		assert !vt.answerClipboard("again", true).ok;
		vt.writeText("\x1b]52;c;?\x07");
		assert vt.clipboardAsked();
		assert vt.answerClipboard("secret", false).ok;
		assert pending(vt) == "\x1b]52;c;\x07";
		vt.free();
	}
}

test "base64 in an OSC 52 answer pads one and two leftover bytes" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert vt.answerClipboard("ab", true).ok;
		assert pending(vt) == "\x1b]52;c;YWI=\x1b\\";
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert vt.answerClipboard("a", true).ok;
		assert pending(vt) == "\x1b]52;c;YQ==\x1b\\";
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert vt.answerClipboard("", true).ok;
		assert pending(vt) == "\x1b]52;c;\x1b\\";
		vt.free();
	}
}

test "a kitty OSC 5522 read is refused at once rather than waiting for an OSC 52 answer" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("\x1b]5522;type=read:id=r1;dGV4dC9wbGFpbg==\x1b\\");
		assert !vt.clipboardAsked();
		assert pending(vt) == "\x1b]5522;type=read:status=EPERM:id=r1\x1b\\";
		vt.free();
	}
}

test "clipboard writes while a read waits leave the waiting answer intact" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert vt.clipboardAsked();
		vt.writeText("\x1b]52;c;YQ==\x1b\\\x1b]52;c;Yg==\x1b\\");
		assert vt.answerClipboard("hello", true).ok;
		assert pending(vt) == "\x1b]52;c;aGVsbG8=\x1b\\";
		vt.free();
	}
}

test "a second read while one waits, and a read of the primary selection, get an empty answer at once" {
	const created = Vt.create(20, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert vt.clipboardAsked();
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert pending(vt) == "\x1b]52;c;\x1b\\";
		assert !vt.clipboardAsked();
		assert vt.answerClipboard("x", true).ok;
		assert pending(vt) == "\x1b]52;c;eA==\x1b\\";
		vt.writeText("\x1b]52;p;?\x1b\\");
		assert pending(vt) == "\x1b]52;p;\x1b\\";
		assert !vt.clipboardAsked();
		vt.free();
	}
}

test "the cursor blinks until the program asks for a steady one, and DECSCUSR 0 blinks again" {
	const fresh = lookAfter("");
	assert fresh !== null;
	if (fresh !== null) { assert fresh.blinking; }
	const steady = lookAfter("\x1b[2 q");
	assert steady !== null;
	if (steady !== null) { assert !steady.blinking; }
	const reset = lookAfter("\x1b[2 q\x1b[0 q");
	assert reset !== null;
	if (reset !== null) { assert reset.blinking; }
}
