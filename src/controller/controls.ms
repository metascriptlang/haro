import { KeyMod } from "../keys/keys";
import { Action, Keybind } from "../input/bindings";
import { Point, Selection, Unit, drag, marked, pointRange, press } from "../select/select";
import { Pointer, Spot } from "../input/pointer";
import { Wheel } from "../input/wheel";
import { Held } from "../input/paste";
import {
	MouseGeometry,
	Vt,
	VtError,
	scrollBottom,
	scrollLines,
	scrollOffset,
	selectionSet,
	size,
} from "../vt/vt";
import { MouseButton } from "./mouseButton";
import { Term, TermError, fit, vtFailed } from "./term";

export enum ClipRead {
	Paste,
	Answer,
}

export struct Asks {
	copy: string | null;
	opens: Vec<string>;
	actions: Vec<Action>;
	reads: int32;
	close: boolean;
}

export function none(this typeof Asks): Asks {
	return { copy: null, opens: [], actions: [], reads: 0, close: false };
}

export struct Hit {
	at: Spot;
	x: float64;
	y: float64;
	scale: float64;
	mods: BitSet<KeyMod>;
	cell: MouseGeometry;
}

export interface Controls {
	pointer: Pointer;
	wheel: Wheel;
	held: Held | null;
	reading: string | null;
	button: MouseButton;
	autoscroll: int32;
	keybinds: Vec<Keybind>;
	consumedKey: string;
	closing: boolean;
	ended: boolean;
	asks: Asks;
	waiting: Vec<ClipRead>;
}

export function open(this typeof Controls): Controls {
	return {
		pointer: Pointer.open(),
		wheel: Wheel.open(),
		held: null,
		reading: null,
		button: MouseButton.None,
		autoscroll: 0,
		keybinds: [],
		consumedKey: "",
		closing: false,
		ended: false,
		asks: Asks.none(),
		waiting: [],
	};
}

export function vtOf(this t: Term): Vt | null {
	const s = t.session;
	if (s === null) { return null; }
	return s.vt;
}

export function takeAsks(this c: Controls): Asks {
	const asks = c.asks;
	c.asks = Asks.none();
	return asks;
}

export function askRead(this c: Controls, kind: ClipRead): void {
	c.waiting.push(kind);
	c.asks.reads += 1;
}

export function holding(this c: Controls): boolean {
	return c.held !== null || c.reading !== null || c.closing || c.ended;
}

export function refit(
	this c: Controls,
	t: Term,
	cols: int32,
	rows: int32,
	cellWidth: int32 = 0,
	cellHeight: int32 = 0,
): Result<boolean, TermError> {
	const reflows = cols != t.cols;
	const fitted = t.fit(cols, rows, cellWidth, cellHeight);
	const vt = t.vtOf();
	if (fitted.ok && reflows && vt !== null) { try c.pointer.clear(vt); }
	return fitted;
}

export function typed(this c: Controls, t: Term): Result<boolean, TermError> {
	const vt = t.vtOf();
	if (vt === null) { return Result.ok(false); }
	const bottom = try vt.atBottom();
	if (c.pointer.sel === null && bottom) { return Result.ok(false); }
	try c.pointer.clear(vt);
	vt.scrollBottom();
	return Result.ok(true);
}

function screenRows(this vt: Vt): Result<int32, VtError> {
	const was = try vt.scrollOffset();
	vt.scrollBottom();
	const bottom = try vt.scrollOffset();
	vt.scrollLines(was - bottom);
	const shown = try vt.size();
	return Result.ok(bottom + shown[1]);
}

export function selectAll(this c: Controls, vt: Vt): Result<void, VtError> {
	const rows = try vt.screenRows();
	const shown = try vt.size();
	const first: Point = { row: 0, col: 0 };
	const last: Point = { row: rows - 1, col: shown[0] - 1 };
	const sel = Selection.press(Unit.Cell, first.pointRange(), false).drag(last.pointRange());
	c.pointer.sel = sel;
	c.pointer.dragging = false;
	return vt.selectionSet(sel.marked());
}
