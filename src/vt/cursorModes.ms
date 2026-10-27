import {
	GhosttyCell,
	GhosttyFocusEvent,
	GhosttyGridRef,
	GhosttyPointTag,
	GhosttyRenderStateCursorVisualStyle,
	GhosttyRenderStateData,
	GhosttyTerminal,
	GhosttyTerminalData,
} from "../../vendor/ghostty/include/ghostty/vt.h";
import { CellWidth } from "../select/select";
import { widthOf } from "./render";
import { Vt } from "./terminal";
import {
	MODE_ALT_SCROLL,
	MODE_BRACKETED_PASTE,
	MODE_DECCKM,
	MODE_FOCUS_EVENT,
	MODE_WIN32_INPUT,
	focusEncode,
	gridRefCell,
	modeOn,
	ok,
	stateGet,
	terminalGet,
	vtGridRef,
} from "./vtNative";
import { VtError } from "./vtTypes";

function mouseTracking(terminal: GhosttyTerminal): Result<boolean, VtError> {
	let tracking = false;
	const key = GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING;
	if (!ok(terminalGet(terminal, key, tracking))) { return Result.err(VtError.ReadFailed); }
	return Result.ok(tracking);
}

export struct Cursor {
	x: int32;
	y: int32;
	wide: boolean;
}

export function cursor(this vt: Vt): Result<Cursor | null, VtError> {
	const hasKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE;
	let hasValue = false;
	if (!ok(stateGet(vt.state, hasKey, hasValue))) {
		return Result.err(VtError.ReadFailed);
	}
	if (!hasValue) { return Result.ok(null); }
	let x: uint16 = 0;
	let y: uint16 = 0;
	const xKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X;
	const yKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y;
	if (!ok(stateGet(vt.state, xKey, x)) || !ok(stateGet(vt.state, yKey, y))) {
		return Result.err(VtError.ReadFailed);
	}
	let tail = false;
	const tailKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL;
	if (!ok(stateGet(vt.state, tailKey, tail))) { return Result.err(VtError.ReadFailed); }
	if (tail) {
		const onTail: Cursor | null = { x: (x as int32) - 1, y: y as int32, wide: true };
		return Result.ok(onTail);
	}
	let under: GhosttyGridRef;
	let cell: GhosttyCell = 0;
	const viewport = GhosttyPointTag.GHOSTTY_POINT_TAG_VIEWPORT;
	if (!ok(vtGridRef(vt.terminal, viewport, x as int32, y as int32, under))
		|| !ok(gridRefCell(under, cell))) {
		return Result.err(VtError.ReadFailed);
	}
	const width = try widthOf(cell);
	const at: Cursor | null = {
		x: x as int32,
		y: y as int32,
		wide: width == CellWidth.Wide,
	};
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

export function cursorLook(this vt: Vt): Result<CursorLook, VtError> {
	let visible = false;
	let blinking = false;
	let style: GhosttyRenderStateCursorVisualStyle;
	const visibleKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE;
	const styleKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE;
	const blinkingKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING;
	if (!ok(stateGet(vt.state, visibleKey, visible))
		|| !ok(stateGet(vt.state, styleKey, style))
		|| !ok(stateGet(vt.state, blinkingKey, blinking))) {
		return Result.err(VtError.ReadFailed);
	}
	return Result.ok({ visible: visible, shape: try shapeOf(style), blinking: blinking });
}

function shapeOf(style: GhosttyRenderStateCursorVisualStyle): Result<CursorShape, VtError> {
	return match (style) {
		GhosttyRenderStateCursorVisualStyle.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR =>
			Result.ok(CursorShape.Bar),
		GhosttyRenderStateCursorVisualStyle.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK =>
			Result.ok(CursorShape.Block),
		GhosttyRenderStateCursorVisualStyle.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE =>
			Result.ok(CursorShape.Underline),
		GhosttyRenderStateCursorVisualStyle.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW =>
			Result.ok(CursorShape.BlockHollow),
		_ => Result.err(VtError.ReadFailed),
	};
}

export struct Modes {
	focusEvents: boolean;
	bracketedPaste: boolean;
	altScroll: boolean;
	cursorKeys: boolean;
	mouseTracking: boolean;
	win32Input: boolean;
}

export function modes(this vt: Vt): Result<Modes, VtError> {
	return Result.ok({
		focusEvents: try modeOn(vt.terminal, MODE_FOCUS_EVENT),
		bracketedPaste: try modeOn(vt.terminal, MODE_BRACKETED_PASTE),
		altScroll: try modeOn(vt.terminal, MODE_ALT_SCROLL),
		cursorKeys: try modeOn(vt.terminal, MODE_DECCKM),
		mouseTracking: try mouseTracking(vt.terminal),
		win32Input: try modeOn(vt.terminal, MODE_WIN32_INPUT),
	});
}

export function focusReport(
	this vt: Vt,
	gained: boolean,
	buf: Span<uint8>,
): Result<int32, VtError> {
	const on = try modeOn(vt.terminal, MODE_FOCUS_EVENT);
	if (!on) { return Result.ok(0); }
	const event = gained
		? GhosttyFocusEvent.GHOSTTY_FOCUS_GAINED
		: GhosttyFocusEvent.GHOSTTY_FOCUS_LOST;
	let written: uint64 = 0;
	if (!ok(focusEncode(event, buf, written))) { return Result.err(VtError.ReadFailed); }
	return Result.ok(written as int32);
}
