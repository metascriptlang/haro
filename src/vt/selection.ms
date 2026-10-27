import {
	GhosttyFormatterFormat,
	GhosttyGridRef,
	GhosttyPointCoordinate,
	GhosttyPointTag,
	GhosttyResult,
	GhosttySelection,
	GhosttySelectionOrder,
	GhosttyTerminal,
	GhosttyTerminalData,
	GhosttyTerminalOption,
	GhosttyTerminalSelectLineOptions,
	GhosttyTerminalSelectWordOptions,
	GhosttyTerminalSelectionFormatOptions,
} from "../../vendor/ghostty/include/ghostty/vt.h";
import {
	Marked,
	Point,
	Range,
	Unit,
} from "../select/select";
import { Vt } from "./terminal";
import {
	checked,
	pointOf,
	selectLine,
	selectWord,
	selectionFormat,
	selectionOrdered,
	terminalGet,
	terminalSet,
	unset,
	vtGridRef,
} from "./vtNative";
import { VtError } from "./vtTypes";

function screenRef(terminal: GhosttyTerminal, at: Point): Result<GhosttyGridRef, VtError> {
	let gridRef: GhosttyGridRef;
	const screen = GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN;
	const r = vtGridRef(terminal, screen, at.col, at.row, gridRef);
	try checked(r, VtError.SelectFailed);
	return Result.ok(gridRef);
}

function screenPoint(terminal: GhosttyTerminal, gridRef: GhosttyGridRef): Result<Point, VtError> {
	let at = gridRef;
	let c: GhosttyPointCoordinate;
	try checked(pointOf(terminal, at, GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN, c), VtError.SelectFailed);
	return Result.ok({ row: c.y as int32, col: c.x as int32 });
}

function markedOf(terminal: GhosttyTerminal, selection: GhosttySelection): Result<Marked, VtError> {
	let given = selection;
	let ordered: GhosttySelection = { size: sizeof GhosttySelection };
	const forward = GhosttySelectionOrder.GHOSTTY_SELECTION_ORDER_FORWARD;
	try checked(selectionOrdered(terminal, given, forward, ordered), VtError.SelectFailed);
	const start = try screenPoint(terminal, ordered.start);
	const end = try screenPoint(terminal, ordered.end);
	return Result.ok({ range: { start: start, end: end }, block: selection.rectangle });
}

function markedFound(
	terminal: GhosttyTerminal,
	r: GhosttyResult,
	selection: GhosttySelection,
): Result<Marked | null, VtError> {
	if (r == GhosttyResult.GHOSTTY_NO_VALUE) { return Result.ok(null); }
	try checked(r, VtError.SelectFailed);
	const m: Marked | null = try markedOf(terminal, selection);
	return Result.ok(m);
}

export function selectionSet(this vt: Vt, m: Marked): Result<void, VtError> {
	let selection: GhosttySelection = {
		size: sizeof GhosttySelection,
		start: try screenRef(vt.terminal, m.range.start),
		end: try screenRef(vt.terminal, m.range.end),
		rectangle: m.block,
	};
	const option = GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_SELECTION;
	try checked(terminalSet(vt.terminal, option, selection), VtError.SelectFailed);
	return Result.ok(null);
}

export function selectionClear(this vt: Vt): void {
	const _cleared = unset(vt.terminal, GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_SELECTION, null);
}

export function selection(this vt: Vt): Result<Marked | null, VtError> {
	let selection: GhosttySelection = { size: sizeof GhosttySelection };
	const key = GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_SELECTION;
	const r = terminalGet(vt.terminal, key, selection);
	return markedFound(vt.terminal, r, selection);
}

function wordAt(this vt: Vt, at: Point): Result<Marked | null, VtError> {
	let options: GhosttyTerminalSelectWordOptions = {
		size: sizeof GhosttyTerminalSelectWordOptions,
		ref: try screenRef(vt.terminal, at),
	};
	let selection: GhosttySelection = { size: sizeof GhosttySelection };
	return markedFound(vt.terminal, selectWord(vt.terminal, options, selection), selection);
}

function lineAt(this vt: Vt, at: Point): Result<Marked | null, VtError> {
	let options: GhosttyTerminalSelectLineOptions = {
		size: sizeof GhosttyTerminalSelectLineOptions,
		ref: try screenRef(vt.terminal, at),
		semantic_prompt_boundary: true,
	};
	let selection: GhosttySelection = { size: sizeof GhosttySelection };
	return markedFound(vt.terminal, selectLine(vt.terminal, options, selection), selection);
}

export function unitAt(this vt: Vt, unit: Unit, at: Point): Result<Range, VtError> {
	const here: Range = { start: at, end: at };
	return match (unit) {
		Unit.Cell => Result.ok(here),
		Unit.Line => {
			const line = try vt.lineAt(at);
			if (line === null) { return Result.ok(here); }
			return Result.ok(line.range);
		},
		Unit.Word => {
			const word = try vt.wordAt(at);
			if (word !== null) { return Result.ok(word.range); }
			return Result.ok(here);
		},
	};
}

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
	if (r == GhosttyResult.GHOSTTY_NO_VALUE) { return Result.ok(null); }
	try checked(r, VtError.ReadFailed);
	const text: string | null = buf[0..(written as int32)].asString();
	return Result.ok(text);
}
