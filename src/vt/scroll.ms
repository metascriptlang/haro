import {
	GhosttyGridRef,
	GhosttyPointCoordinate,
	GhosttyPointTag,
	GhosttyResult,
	GhosttyRow,
	GhosttyRowData,
	GhosttyRowSemanticPrompt,
	GhosttyTerminalData,
	GhosttyTerminalScreen,
	GhosttyTerminalScrollViewportTag,
	GhosttyTerminalScrollbar,
	ghostty_tracked_grid_ref_point,
} from "../../vendor/ghostty/include/ghostty/vt.h";
import { Vt } from "./terminal";
import {
	checked,
	gridRefRow,
	rowPrompt,
	terminalGet,
	vtGridRef,
	vtScroll,
	vtTopAnchor,
} from "./vtNative";
import { VtError } from "./vtTypes";

function scrollbar(this vt: Vt): Result<GhosttyTerminalScrollbar, VtError> {
	let bar: GhosttyTerminalScrollbar;
	const key = GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_SCROLLBAR;
	try checked(terminalGet(vt.terminal, key, bar), VtError.ReadFailed);
	return Result.ok(bar);
}

export function scrollOffset(this vt: Vt): Result<int32, VtError> {
	const bar = try vt.scrollbar();
	return Result.ok(bar.offset as int32);
}

export function alternateScreen(this vt: Vt): Result<boolean, VtError> {
	let screen = GhosttyTerminalScreen.GHOSTTY_TERMINAL_SCREEN_PRIMARY;
	const key = GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN;
	try checked(terminalGet(vt.terminal, key, screen), VtError.ReadFailed);
	return Result.ok(screen == GhosttyTerminalScreen.GHOSTTY_TERMINAL_SCREEN_ALTERNATE);
}

export function anchoredRow(this vt: Vt): Result<int32 | null, VtError> {
	let at: GhosttyPointCoordinate = { x: 0, y: 0 };
	const screen = GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN;
	const r = ghostty_tracked_grid_ref_point(vt.anchor, screen, at);
	if (r == GhosttyResult.GHOSTTY_NO_VALUE) { return Result.ok(null); }
	try checked(r, VtError.ReadFailed);
	const row: int32 | null = at.y as int32;
	return Result.ok(row);
}

export function anchorTop(this vt: Vt): Result<void, VtError> {
	try checked(vtTopAnchor(vt.anchor, vt.terminal), VtError.ReadFailed);
	return Result.ok(null);
}

export function scrollLines(this vt: Vt, rows: int32): void {
	const delta = GhosttyTerminalScrollViewportTag.GHOSTTY_SCROLL_VIEWPORT_DELTA;
	vtScroll(vt.terminal, delta, rows as int64);
}

export function scrollPages(this vt: Vt, pages: int32): Result<void, VtError> {
	const bar = try vt.scrollbar();
	const delta = (pages as int64) * (bar.len as int64);
	vtScroll(vt.terminal, GhosttyTerminalScrollViewportTag.GHOSTTY_SCROLL_VIEWPORT_DELTA, delta);
	return Result.ok(null);
}

export enum PromptJump {
	Previous,
	Next,
}

export function jumpToPrompt(this vt: Vt, toward: PromptJump): Result<boolean, VtError> {
	const bar = try vt.scrollbar();
	const step: int64 = toward == PromptJump.Previous ? -1 : 1;
	for (let y = (bar.offset as int64) + step; y >= 0 && y < (bar.total as int64); y += step) {
		let at: GhosttyGridRef;
		let row: GhosttyRow = 0;
		let prompt = GhosttyRowSemanticPrompt.GHOSTTY_ROW_SEMANTIC_NONE;
		try checked(vtGridRef(vt.terminal, GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN, 0, y as int32, at), VtError.ReadFailed);
		try checked(gridRefRow(at, row), VtError.ReadFailed);
		try checked(rowPrompt(row, GhosttyRowData.GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, prompt), VtError.ReadFailed);
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
	const bar = try vt.scrollbar();
	return Result.ok(bar.offset + bar.len >= bar.total);
}
