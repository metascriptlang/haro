import {
	GhosttyGridRef,
	GhosttyPointTag,
	GhosttyRenderState,
	GhosttyRenderStateData,
	GhosttyRenderStateRowCells,
	GhosttyRenderStateRowIterator,
	GhosttyResult,
	GhosttyString,
	GhosttyTerminal,
	GhosttyTerminalData,
	GhosttyTerminalModeConfig,
	GhosttyTerminalOption,
	GhosttyTrackedGridRef,
	ghostty_mouse_encoder_free,
	ghostty_mouse_event_free,
	ghostty_render_state_clean,
	ghostty_render_state_free,
	ghostty_render_state_new,
	ghostty_render_state_row_cells_free,
	ghostty_render_state_row_cells_new,
	ghostty_render_state_row_iterator_free,
	ghostty_render_state_row_iterator_new,
	ghostty_render_state_update,
	ghostty_terminal_free,
	ghostty_terminal_new,
	ghostty_terminal_resize,
	ghostty_tracked_grid_ref_free,
	size_t,
} from "../../vendor/ghostty/include/ghostty/vt.h";
import {
	Effects,
	NO_EVENTS,
	VtEvents,
	answerRead,
	closeEffects,
	freeAnchors,
	openEffects,
} from "./vtEffects";
import {
	Colors256,
	MODE_CURSOR_BLINKING,
	MODE_GRAPHEME_CLUSTER,
	MODE_SYNC_OUTPUT,
	checked,
	ghosttyColor,
	gridRefLink,
	ok,
	stateGet,
	terminalGet,
	terminalSet,
	unset,
	vtAllocator,
	vtGridRef,
	vtTopTrack,
	vtWriteBytes,
} from "./vtNative";
import {
	Mouse,
	Painted,
	Rgb,
	VtError,
} from "./vtTypes";
import { wellFormed } from "./wellFormed";

export struct Vt {
	terminal: GhosttyTerminal;
	state: GhosttyRenderState;
	iterator: GhosttyRenderStateRowIterator;
	cells: GhosttyRenderStateRowCells;
	effects: Effects;
	mouse: Mouse;
	anchor: GhosttyTrackedGridRef;
	painted: Painted;
}

function freeHandles(
	terminal: GhosttyTerminal,
	state: GhosttyRenderState,
	iterator: GhosttyRenderStateRowIterator,
	cells: GhosttyRenderStateRowCells,
): void {
	ghostty_render_state_row_cells_free(cells);
	ghostty_render_state_row_iterator_free(iterator);
	ghostty_render_state_free(state);
	ghostty_terminal_free(terminal);
}

export const SCROLLBACK_LINES: int64 = 10000;
const SCROLLBACK_MAX_BYTES: uint64 = 50000000;

function applyColors(terminal: GhosttyTerminal, fg: Rgb, bg: Rgb): Result<void, VtError> {
	let f = fg.ghosttyColor();
	let b = bg.ghosttyColor();
	const fgOption = GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND;
	const bgOption = GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND;
	try checked(terminalSet(terminal, fgOption, f), VtError.WriteFailed);
	try checked(terminalSet(terminal, bgOption, b), VtError.WriteFailed);
	return Result.ok(null);
}

// libghostty has no reset default for the blink mode: a full reset (RIS) leaves a steady cursor.
function applyBlinkDefault(terminal: GhosttyTerminal, on: boolean): Result<void, VtError> {
	let mode: GhosttyTerminalModeConfig = { mode: MODE_CURSOR_BLINKING, value: on };
	let blink = on;
	const blinkOption = GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK;
	try checked(terminalSet(terminal, GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_MODE, mode), VtError.WriteFailed);
	try checked(terminalSet(terminal, blinkOption, blink), VtError.WriteFailed);
	return Result.ok(null);
}

function applyGraphemeWidth(terminal: GhosttyTerminal): Result<void, VtError> {
	let mode: GhosttyTerminalModeConfig = { mode: MODE_GRAPHEME_CLUSTER, value: true };
	try checked(terminalSet(terminal, GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, mode), VtError.WriteFailed);
	return Result.ok(null);
}

function applyScrollback(terminal: GhosttyTerminal, lines: int64): Result<void, VtError> {
	if (lines < 0) { return Result.err(VtError.ScrollbackInvalid); }
	let bytes = SCROLLBACK_MAX_BYTES;
	let kept = lines as uint64;
	const bytesOption = GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES;
	const linesOption = GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES;
	try checked(terminalSet(terminal, bytesOption, bytes), VtError.WriteFailed);
	try checked(terminalSet(terminal, linesOption, kept), VtError.WriteFailed);
	return Result.ok(null);
}

const MAX_GRID_SIDE = 65535;

function gridSide(cells: int32, fail: VtError): Result<uint16, VtError> {
	if (cells < 1 || cells > MAX_GRID_SIDE) { return Result.err(fail); }
	return Result.ok(cells as uint16);
}

function configure(terminal: GhosttyTerminal, out anchor: GhosttyTrackedGridRef): Result<void, VtError> {
	try checked(vtTopTrack(terminal, anchor), VtError.AnchorFailed);
	try applyColors(terminal, { r: 255, g: 255, b: 255 }, { r: 0, g: 0, b: 0 });
	try applyBlinkDefault(terminal, true);
	try applyGraphemeWidth(terminal);
	try applyScrollback(terminal, SCROLLBACK_LINES);
	return Result.ok(null);
}

export function create(this typeof Vt, cols: int32, rows: int32): Result<Vt, VtError> {
	const wide = try gridSide(cols, VtError.CreateFailed);
	const tall = try gridSide(rows, VtError.CreateFailed);
	let terminal: GhosttyTerminal;
	try checked(ghostty_terminal_new(vtAllocator(), terminal, wide, tall), VtError.CreateFailed);
	let state: GhosttyRenderState;
	let iterator: GhosttyRenderStateRowIterator;
	let cells: GhosttyRenderStateRowCells;
	if (
		!ok(ghostty_render_state_new(vtAllocator(), state)) ||
		!ok(ghostty_render_state_row_iterator_new(vtAllocator(), iterator)) ||
		!ok(ghostty_render_state_row_cells_new(vtAllocator(), cells))
	) {
		freeHandles(terminal, state, iterator, cells);
		return Result.err(VtError.CreateFailed);
	}
	const effects = openEffects(terminal, state);
	if (!effects.ok) {
		freeHandles(terminal, state, iterator, cells);
		return Result.err(effects.error);
	}
	let anchor: GhosttyTrackedGridRef;
	const configured = configure(terminal, anchor);
	if (!configured.ok) {
		closeEffects(terminal);
		ghostty_tracked_grid_ref_free(anchor);
		freeHandles(terminal, state, iterator, cells);
		return Result.err(configured.error);
	}
	return Result.ok({
		terminal: terminal,
		state: state,
		iterator: iterator,
		cells: cells,
		effects: effects.value,
		mouse: { codec: null, stale: true, geometry: null },
		anchor: anchor,
		painted: { alternate: false, rows: [], palette: null },
	});
}

export function write(this vt: Vt, bytes: Readonly<Span<uint8>>): void {
	vtWriteBytes(vt.terminal, bytes);
	vt.mouse.stale = true;
}

export function writeText(this vt: Vt, text: string): void {
	vtWriteBytes(vt.terminal, text.asBytes());
	vt.mouse.stale = true;
}

export function takeReplies(this vt: Vt): Vec<uint8> {
	const taken = vt.effects.replies;
	vt.effects.replies = [];
	return taken;
}

export function pendingReplies(this vt: Vt): Vec<uint8> {
	return vt.effects.replies;
}

export function dropReplies(this vt: Vt): void {
	vt.effects.replies = [];
}

export function titleChanged(this vt: Vt): boolean {
	return vt.effects.events.titleChanged;
}

export function takeEvents(this vt: Vt): VtEvents {
	const e = vt.effects;
	const events = e.events;
	e.events = NO_EVENTS;
	return events;
}

function terminalString(
	terminal: GhosttyTerminal,
	key: GhosttyTerminalData,
): Result<string, VtError> {
	let text: GhosttyString;
	try checked(terminalGet(terminal, key, text), VtError.ReadFailed);
	return Result.ok(wellFormed(text.ptr[0..text.len]));
}

export function title(this vt: Vt): Result<string, VtError> {
	return terminalString(vt.terminal, GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_TITLE);
}

export function linkAt(this vt: Vt, x: int32, y: int32): Result<string | null, VtError> {
	let at: GhosttyGridRef;
	try checked(vtGridRef(vt.terminal, GhosttyPointTag.GHOSTTY_POINT_TAG_VIEWPORT, x, y, at), VtError.ReadFailed);
	let buf: Vec<uint8> = new Array(256);
	let len: size_t = 0;
	let r = gridRefLink(at, buf, len);
	if (r == GhosttyResult.GHOSTTY_OUT_OF_SPACE) {
		buf = new Array(len as int32);
		r = gridRefLink(at, buf, len);
	}
	try checked(r, VtError.ReadFailed);
	if (len == 0) { return Result.ok(null); }
	// Typed local until card
	// 2026-10-28-result-ok-of-a-struct-is-not-assignable-to-a-nullable-result.md
	const uri: string | null = wellFormed(buf[0..(len as int32)]);
	return Result.ok(uri);
}

export function pwd(this vt: Vt): Result<string, VtError> {
	return terminalString(vt.terminal, GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_PWD);
}

export function resize(
	this vt: Vt,
	cols: int32,
	rows: int32,
	cellWidth: int32 = 0,
	cellHeight: int32 = 0,
): Result<void, VtError> {
	const wide = try gridSide(cols, VtError.ResizeFailed);
	const tall = try gridSide(rows, VtError.ResizeFailed);
	if (cellWidth < 0 || cellHeight < 0) { return Result.err(VtError.CellSizeInvalid); }
	const r = ghostty_terminal_resize(
		vt.terminal,
		wide,
		tall,
		cellWidth as uint32,
		cellHeight as uint32,
	);
	try checked(r, VtError.ResizeFailed);
	vt.painted.rows = [];
	vt.painted.palette = null;
	return Result.ok(null);
}

export function setDefaultColors(this vt: Vt, fg: Rgb, bg: Rgb): Result<void, VtError> {
	return applyColors(vt.terminal, fg, bg);
}

export function setPalette(this vt: Vt, colors: Readonly<Span<Rgb>>): Result<void, VtError> {
	const option = GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE;
	let palette: Colors256;
	const defaultKey = GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT;
	if (colors.length > 256) { return Result.err(VtError.PaletteTooLong); }
	if (!ok(unset(vt.terminal, option, null)) || !ok(terminalGet(vt.terminal, defaultKey, palette))) {
		return Result.err(VtError.ReadFailed);
	}
	for (let i = 0; i < colors.length; i++) {
		palette.c[i] = colors[i].ghosttyColor();
	}
	try checked(terminalSet(vt.terminal, option, palette), VtError.WriteFailed);
	vt.painted.rows = [];
	return Result.ok(null);
}

export function setScrollback(this vt: Vt, lines: int64): Result<void, VtError> {
	return applyScrollback(vt.terminal, lines);
}

export function setPullScrollback(this vt: Vt, pull: boolean): Result<void, VtError> {
	let on = pull;
	const option = GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_RESIZE_PULL_SCROLLBACK;
	try checked(terminalSet(vt.terminal, option, on), VtError.WriteFailed);
	return Result.ok(null);
}

export function takeClipboard(this vt: Vt): string | null {
	const text = vt.effects.clipboard;
	vt.effects.clipboard = null;
	return text;
}

export function clipboardAsked(this vt: Vt): boolean {
	const asked = vt.effects.readAsked;
	vt.effects.readAsked = false;
	return asked;
}

export function answerClipboard(this vt: Vt, text: string, allow: boolean): Result<void, VtError> {
	if (!vt.effects.answerRead(text, allow)) { return Result.err(VtError.ReadFailed); }
	return Result.ok(null);
}

export function holding(this vt: Vt): boolean {
	const e = vt.effects;
	const since = e.heldSinceMs;
	return since !== null && performance.now() - since < e.holdLimitMs;
}

// A hold older than the limit ends here: the terminal has no clock, and a program that never
// releases would freeze the screen (terminal.h, "Timeouts").
function releaseExpiredHold(this vt: Vt): Result<void, VtError> {
	const e = vt.effects;
	if (e.heldSinceMs === null) { return Result.ok(null); }
	let mode: GhosttyTerminalModeConfig = { mode: MODE_SYNC_OUTPUT, value: false };
	try checked(terminalSet(vt.terminal, GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_MODE, mode), VtError.WriteFailed);
	e.heldSinceMs = null;
	return Result.ok(null);
}

export function holdLimit(this vt: Vt, ms: int64): void {
	vt.effects.holdLimitMs = ms as float64;
}

export function update(this vt: Vt): Result<void, VtError> {
	if (vt.effects.holdFailed) {
		vt.effects.holdFailed = false;
		return Result.err(VtError.UpdateFailed);
	}
	if (vt.holding()) { return Result.ok(null); }
	try vt.releaseExpiredHold();
	try checked(ghostty_render_state_update(vt.state, vt.terminal), VtError.UpdateFailed);
	return Result.ok(null);
}

export function size(this vt: Vt): Result<[int32, int32], VtError> {
	let cols: uint16 = 0;
	let rows: uint16 = 0;
	try checked(stateGet(vt.state, GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_COLS, cols), VtError.ReadFailed);
	try checked(stateGet(vt.state, GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_ROWS, rows), VtError.ReadFailed);
	return Result.ok([cols as int32, rows as int32]);
}

export function clean(this vt: Vt): void {
	ghostty_render_state_clean(vt.state);
}

export function free(this vt: Vt): void {
	if (vt.effects.freed) { return; }
	vt.effects.freed = true;
	ghostty_tracked_grid_ref_free(vt.anchor);
	vt.effects.freeAnchors();
	const closed = closeEffects(vt.terminal);
	const codec = vt.mouse.codec;
	if (codec !== null) {
		ghostty_mouse_encoder_free(codec.encoder);
		ghostty_mouse_event_free(codec.event);
	}
	freeHandles(vt.terminal, vt.state, vt.iterator, vt.cells);
	if (!closed.ok) { throw new Error("Vt.free: the terminal's effect callbacks could not be unwired"); }
}
