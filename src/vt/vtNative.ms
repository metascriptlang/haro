@passC("-I../../vendor/ghostty/include");
@passC("-DGHOSTTY_STATIC");
when (emcc) {
	@link("../../out/wasm/libghostty-vt.a");
} else when (windows) {
	@link("../../out/ghostty/ghostty-vt-static.lib");
} else {
	@link("../../out/ghostty/libghostty-vt.a");
}
@include("./effects.h");
@compile("./effects.c");

import {
	GhosttyAllocator,
	GhosttyCell,
	GhosttyCellData,
	GhosttyCellWide,
	GhosttyColorRgb,
	GhosttyFocusEvent,
	GhosttyGridRef,
	GhosttyKeyEncoder,
	GhosttyKeyEncoderOption,
	GhosttyKeyEvent,
	GhosttyMouseEncoder,
	GhosttyMouseEncoderOption,
	GhosttyMouseEncoderSize,
	GhosttyMouseEvent,
	GhosttyOptionAsAlt,
	GhosttyPoint,
	GhosttyPointCoordinate,
	GhosttyPointTag,
	GhosttyRenderState,
	GhosttyRenderStateCursorVisualStyle,
	GhosttyRenderStateData,
	GhosttyRenderStateRowCells,
	GhosttyRenderStateRowCellsData,
	GhosttyRenderStateRowData,
	GhosttyRenderStateRowIterator,
	GhosttyRenderStateRowSelection,
	GhosttyResult,
	GhosttyRow,
	GhosttyRowData,
	GhosttyRowSemanticPrompt,
	GhosttySelection,
	GhosttySelectionOrder,
	GhosttyString,
	GhosttyStyle,
	GhosttyTerminal,
	GhosttyTerminalData,
	GhosttyTerminalModeConfig,
	GhosttyTerminalOption,
	GhosttyTerminalScreen,
	GhosttyTerminalScrollViewport,
	GhosttyTerminalScrollViewportTag,
	GhosttyTerminalScrollbar,
	GhosttyTerminalSelectLineOptions,
	GhosttyTerminalSelectWordOptions,
	GhosttyTerminalSelectionFormatOptions,
	GhosttyTrackedGridRef,
} from "../../vendor/ghostty/include/ghostty/vt.h";
import { Rgb, VtError } from "./vtTypes";

export struct Colors256 { c: GhosttyColorRgb[256]; }

export extern function vtWriteBytes(terminal: GhosttyTerminal, bytes: Readonly<Span<uint8>>): void
	from "ghostty_terminal_vt_write";
export extern function vtAllocator(): Ptr<GhosttyAllocator>;
export extern function vtEffectsWire(terminal: GhosttyTerminal, effects: Ptr<void> | null): int32;
export extern function mouseSetFlag(
	encoder: GhosttyMouseEncoder,
	option: GhosttyMouseEncoderOption,
	ref value: boolean,
): void from "ghostty_mouse_encoder_setopt";
export extern function mouseSetSize(
	encoder: GhosttyMouseEncoder,
	option: GhosttyMouseEncoderOption,
	ref size: GhosttyMouseEncoderSize,
): void from "ghostty_mouse_encoder_setopt";
export extern function mouseSetButton(event: GhosttyMouseEvent, button: int32): void
	from "ghostty_mouse_event_set_button";
export extern function mouseSetMods(event: GhosttyMouseEvent, mods: uint16): void
	from "ghostty_mouse_event_set_mods";
export extern function mouseEncode(
	encoder: GhosttyMouseEncoder,
	event: GhosttyMouseEvent,
	buf: Span<uint8>,
	out written: uint64,
): GhosttyResult from "ghostty_mouse_encoder_encode";
export extern function terminalText(
	terminal: GhosttyTerminal,
	key: GhosttyTerminalData,
	out text: GhosttyString,
): GhosttyResult from "ghostty_terminal_get";
extern function gridRefTrack(
	terminal: GhosttyTerminal,
	point: GhosttyPoint,
	out ref: GhosttyTrackedGridRef,
): GhosttyResult from "ghostty_terminal_grid_ref_track";
extern function trackedGridRefSet(
	ref: GhosttyTrackedGridRef,
	terminal: GhosttyTerminal,
	point: GhosttyPoint,
): GhosttyResult from "ghostty_tracked_grid_ref_set";
export extern function terminalScrollbar(
	terminal: GhosttyTerminal,
	key: GhosttyTerminalData,
	out scrollbar: GhosttyTerminalScrollbar,
): GhosttyResult from "ghostty_terminal_get";
export extern function terminalScreen(
	terminal: GhosttyTerminal,
	key: GhosttyTerminalData,
	out screen: GhosttyTerminalScreen,
): GhosttyResult from "ghostty_terminal_get";
export extern function terminalFlag(
	terminal: GhosttyTerminal,
	key: GhosttyTerminalData,
	out value: boolean,
): GhosttyResult from "ghostty_terminal_get";
export extern function terminalU16(
	terminal: GhosttyTerminal,
	key: GhosttyTerminalData,
	out value: uint16,
): GhosttyResult from "ghostty_terminal_get";
export extern function terminalU32(
	terminal: GhosttyTerminal,
	key: GhosttyTerminalData,
	out value: uint32,
): GhosttyResult from "ghostty_terminal_get";
extern function terminalMode(
	terminal: GhosttyTerminal,
	key: GhosttyTerminalData,
	ref mode: GhosttyTerminalModeConfig,
): GhosttyResult from "ghostty_terminal_get";
export extern function terminalColors(
	terminal: GhosttyTerminal,
	key: GhosttyTerminalData,
	out colors: Colors256,
): GhosttyResult from "ghostty_terminal_get";
export extern function setColor(
	terminal: GhosttyTerminal,
	option: GhosttyTerminalOption,
	ref color: GhosttyColorRgb,
): GhosttyResult from "ghostty_terminal_set";
export extern function setColors(
	terminal: GhosttyTerminal,
	option: GhosttyTerminalOption,
	ref colors: Colors256,
): GhosttyResult from "ghostty_terminal_set";
export extern function setSize(
	terminal: GhosttyTerminal,
	option: GhosttyTerminalOption,
	ref value: uint64,
): GhosttyResult from "ghostty_terminal_set";
export extern function setFlag(
	terminal: GhosttyTerminal,
	option: GhosttyTerminalOption,
	ref value: boolean,
): GhosttyResult from "ghostty_terminal_set";
export extern function setMode(
	terminal: GhosttyTerminal,
	option: GhosttyTerminalOption,
	ref mode: GhosttyTerminalModeConfig,
): GhosttyResult from "ghostty_terminal_set";
export extern function unset(
	terminal: GhosttyTerminal,
	option: GhosttyTerminalOption,
	value: Ptr<void> | null,
): GhosttyResult from "ghostty_terminal_set";
export extern function focusEncode(
	event: GhosttyFocusEvent,
	buf: Span<uint8>,
	out written: uint64,
): GhosttyResult from "ghostty_focus_encode";
export extern function eventSetMods(event: GhosttyKeyEvent, mods: uint16): void
	from "ghostty_key_event_set_mods";
export extern function eventSetConsumedMods(event: GhosttyKeyEvent, mods: uint16): void
	from "ghostty_key_event_set_consumed_mods";
export extern function encoderSetOptionAsAlt(
	encoder: GhosttyKeyEncoder,
	option: GhosttyKeyEncoderOption,
	ref value: GhosttyOptionAsAlt,
): void from "ghostty_key_encoder_setopt";
export extern function encoderEncode(
	encoder: GhosttyKeyEncoder,
	event: GhosttyKeyEvent,
	buf: Span<uint8>,
	out written: uint64,
): GhosttyResult from "ghostty_key_encoder_encode";

export extern function stateRowIterator(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out it: GhosttyRenderStateRowIterator,
): GhosttyResult from "ghostty_render_state_get";
export extern function rowCells(
	it: GhosttyRenderStateRowIterator,
	key: GhosttyRenderStateRowData,
	out cells: GhosttyRenderStateRowCells,
): GhosttyResult from "ghostty_render_state_row_get";
export extern function rowSelection(
	it: GhosttyRenderStateRowIterator,
	key: GhosttyRenderStateRowData,
	ref selection: GhosttyRenderStateRowSelection,
): GhosttyResult from "ghostty_render_state_row_get";
export extern function cellGraphemeCount(
	cells: GhosttyRenderStateRowCells,
	key: GhosttyRenderStateRowCellsData,
	out count: uint32,
): GhosttyResult from "ghostty_render_state_row_cells_get";
export extern function cellGraphemesInto(
	cells: GhosttyRenderStateRowCells,
	key: GhosttyRenderStateRowCellsData,
	buf: Ptr<uint32>,
): GhosttyResult from "ghostty_render_state_row_cells_get";
export extern function stateColor(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out color: GhosttyColorRgb,
): GhosttyResult from "ghostty_render_state_get";
export extern function stateFlag(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out value: boolean,
): GhosttyResult from "ghostty_render_state_get";
export extern function stateU16(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out value: uint16,
): GhosttyResult from "ghostty_render_state_get";
export extern function stateCursorStyle(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out style: GhosttyRenderStateCursorVisualStyle,
): GhosttyResult from "ghostty_render_state_get";
export extern function stateColors(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out colors: Colors256,
): GhosttyResult from "ghostty_render_state_get";
export extern function cellColor(
	cells: GhosttyRenderStateRowCells,
	key: GhosttyRenderStateRowCellsData,
	out color: GhosttyColorRgb,
): GhosttyResult from "ghostty_render_state_row_cells_get";
export extern function cellHasStyling(
	cells: GhosttyRenderStateRowCells,
	key: GhosttyRenderStateRowCellsData,
	out styled: boolean,
): GhosttyResult from "ghostty_render_state_row_cells_get";
export extern function cellStyle(
	cells: GhosttyRenderStateRowCells,
	key: GhosttyRenderStateRowCellsData,
	out style: GhosttyStyle,
): GhosttyResult from "ghostty_render_state_row_cells_get";
export extern function cellRaw(
	cells: GhosttyRenderStateRowCells,
	key: GhosttyRenderStateRowCellsData,
	out raw: GhosttyCell,
): GhosttyResult from "ghostty_render_state_row_cells_get";
export extern function cellWide(
	raw: GhosttyCell,
	key: GhosttyCellData,
	out wide: GhosttyCellWide,
): GhosttyResult from "ghostty_cell_get";

extern function terminalGridRef(
	terminal: GhosttyTerminal,
	point: GhosttyPoint,
	ref gridRef: GhosttyGridRef,
): GhosttyResult from "ghostty_terminal_grid_ref";
extern function scrollViewport(
	terminal: GhosttyTerminal,
	behavior: GhosttyTerminalScrollViewport,
): void from "ghostty_terminal_scroll_viewport";
export extern const GHOSTTY_DA_CONFORMANCE_LEVEL_2: uint16;
export extern const GHOSTTY_DA_FEATURE_ANSI_COLOR: uint16;
export extern const GHOSTTY_DA_FEATURE_CLIPBOARD: uint16;
export extern const GHOSTTY_DA_DEVICE_TYPE_VT220: uint16;

function pointAt(tag: GhosttyPointTag, x: int32, y: int32): GhosttyPoint {
	let p: GhosttyPoint = { tag: tag };
	p.value.coordinate.x = x as uint16;
	p.value.coordinate.y = y as uint32;
	return p;
}

export function vtGridRef(
	terminal: GhosttyTerminal,
	tag: GhosttyPointTag,
	x: int32,
	y: int32,
	out gridRef: GhosttyGridRef,
): GhosttyResult {
	gridRef = { size: sizeof GhosttyGridRef };
	if (x < 0 || y < 0) { return GhosttyResult.GHOSTTY_INVALID_VALUE; }
	return terminalGridRef(terminal, pointAt(tag, x, y), gridRef);
}

export function vtScroll(terminal: GhosttyTerminal, tag: GhosttyTerminalScrollViewportTag, amount: int64): void {
	let v: GhosttyTerminalScrollViewport = { tag: tag };
	if (tag == GhosttyTerminalScrollViewportTag.GHOSTTY_SCROLL_VIEWPORT_DELTA) { v.value.delta = amount; }
	if (tag == GhosttyTerminalScrollViewportTag.GHOSTTY_SCROLL_VIEWPORT_ROW) { v.value.row = amount as uint64; }
	scrollViewport(terminal, v);
}

export function vtTopTrack(terminal: GhosttyTerminal, out ref: GhosttyTrackedGridRef): GhosttyResult {
	return gridRefTrack(terminal, pointAt(GhosttyPointTag.GHOSTTY_POINT_TAG_VIEWPORT, 0, 0), ref);
}

export function vtTopAnchor(ref: GhosttyTrackedGridRef, terminal: GhosttyTerminal): GhosttyResult {
	return trackedGridRefSet(ref, terminal, pointAt(GhosttyPointTag.GHOSTTY_POINT_TAG_VIEWPORT, 0, 0));
}
export extern function gridRefLink(
	ref gridRef: GhosttyGridRef,
	buf: Span<uint8>,
	out len: uint64,
): GhosttyResult from "ghostty_grid_ref_hyperlink_uri";
export extern function gridRefCell(ref gridRef: GhosttyGridRef, out cell: GhosttyCell): GhosttyResult
	from "ghostty_grid_ref_cell";
export extern function gridRefRow(ref gridRef: GhosttyGridRef, out row: GhosttyRow): GhosttyResult
	from "ghostty_grid_ref_row";
export extern function rowPrompt(
	row: GhosttyRow,
	key: GhosttyRowData,
	out prompt: GhosttyRowSemanticPrompt,
): GhosttyResult from "ghostty_row_get";
export extern function pointOf(
	terminal: GhosttyTerminal,
	ref gridRef: GhosttyGridRef,
	tag: GhosttyPointTag,
	out at: GhosttyPointCoordinate,
): GhosttyResult from "ghostty_terminal_point_from_grid_ref";
export extern function terminalSelection(
	terminal: GhosttyTerminal,
	key: GhosttyTerminalData,
	ref selection: GhosttySelection,
): GhosttyResult from "ghostty_terminal_get";
export extern function setSelection(
	terminal: GhosttyTerminal,
	option: GhosttyTerminalOption,
	ref selection: GhosttySelection,
): GhosttyResult from "ghostty_terminal_set";
export extern function selectionOrdered(
	terminal: GhosttyTerminal,
	ref selection: GhosttySelection,
	order: GhosttySelectionOrder,
	ref ordered: GhosttySelection,
): GhosttyResult from "ghostty_terminal_selection_ordered";
export extern function selectWord(
	terminal: GhosttyTerminal,
	ref options: GhosttyTerminalSelectWordOptions,
	ref selection: GhosttySelection,
): GhosttyResult from "ghostty_terminal_select_word";
export extern function selectLine(
	terminal: GhosttyTerminal,
	ref options: GhosttyTerminalSelectLineOptions,
	ref selection: GhosttySelection,
): GhosttyResult from "ghostty_terminal_select_line";
export extern function selectionFormat(
	terminal: GhosttyTerminal,
	options: GhosttyTerminalSelectionFormatOptions,
	buf: Span<uint8>,
	out written: uint64,
): GhosttyResult from "ghostty_terminal_selection_format_buf";
export extern function pasteSafe(data: Readonly<Span<uint8>>): boolean from "ghostty_paste_is_safe";
export extern function pasteEncode(
	data: Span<uint8>,
	bracketed: boolean,
	buf: Span<uint8>,
	out written: uint64,
): GhosttyResult from "ghostty_paste_encode";

export function ok(r: GhosttyResult): boolean {
	return r == GhosttyResult.GHOSTTY_SUCCESS;
}

export function pushAll<T>(ref out: Vec<T>, from: Readonly<Span<T>>): void {
	for (const x of from) { out.push(x); }
}

export const MODE_DECCKM: uint16 = 1;
export const MODE_CURSOR_BLINKING: uint16 = 12;
export const MODE_FOCUS_EVENT: uint16 = 1004;
export const MODE_ALT_SCROLL: uint16 = 1007;
export const MODE_BRACKETED_PASTE: uint16 = 2004;
export const MODE_SYNC_OUTPUT: uint16 = 2026;
export const MODE_GRAPHEME_CLUSTER: uint16 = 2027;
export const MODE_WIN32_INPUT: uint16 = 9001;

export function modeOn(terminal: GhosttyTerminal, mode: uint16): Result<boolean, VtError> {
	let m: GhosttyTerminalModeConfig = { mode: mode, value: false };
	if (!ok(terminalMode(terminal, GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_MODE, m))) {
		return Result.err(VtError.ReadFailed);
	}
	return Result.ok(m.value);
}

export function rgb(c: GhosttyColorRgb): Rgb {
	return { r: c.r, g: c.g, b: c.b };
}

export function ghosttyColor(c: Rgb): GhosttyColorRgb {
	return { r: c.r, g: c.g, b: c.b };
}
