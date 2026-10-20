import { Block, Selection } from "../select/select";
import { Vt, VtError } from "../vt/vt";
import { Clicks, unitOf } from "./clicks";

export struct Spot {
	col: int32;
	row: int32;
}

export interface Pointer {
	clicks: Clicks;
	sel: Selection | null;
	dragging: boolean;
	last: Spot;
}

export function open(this typeof Pointer): Pointer {
	return { clicks: Clicks.open(), sel: null, dragging: false, last: { col: 0, row: 0 } };
}

export function spotAt(
	x: float64,
	y: float64,
	cellWidth: float64,
	rowHeight: float64,
	cols: int32,
	rows: int32,
): Spot {
	const col = Math.floor(x / cellWidth) as int32;
	const row = Math.floor(y / rowHeight) as int32;
	return { col: Math.max(0, Math.min(col, cols - 1)), row: Math.max(0, Math.min(row, rows - 1)) };
}

const AUTOSCROLL_EDGE_PX: float64 = 1;

export function autoscrollOf(yPx: float64, heightPx: float64): int32 {
	if (yPx <= AUTOSCROLL_EDGE_PX) { return -1; }
	if (yPx > heightPx - AUTOSCROLL_EDGE_PX) { return 1; }
	return 0;
}

export function claimsMouse(tracking: boolean, shift: boolean): boolean {
	return tracking && !shift;
}

function shown(this p: Pointer): Selection | null {
	const sel = p.sel;
	if (sel === null || sel.collapsed()) { return null; }
	return sel;
}

export function selected(this p: Pointer): boolean {
	return p.shown() !== null;
}

function publish(this p: Pointer, vt: Vt): Result<boolean, VtError> {
	const sel = p.shown();
	if (sel === null) {
		vt.selectionClear();
		return Result.ok(false);
	}
	const _set = try vt.selectionSet(sel.marked());
	return Result.ok(true);
}

export function press(
	this p: Pointer,
	vt: Vt,
	at: Spot,
	x: float64,
	y: float64,
	time: float64,
	reach: float64,
): Result<boolean, VtError> {
	const unit = unitOf(p.clicks.register(x, y, time, reach));
	const top = try vt.scrollOffset();
	const range = try vt.unitAt(unit, { row: top + at.row, col: at.col });
	p.sel = Selection.press(unit, range, false);
	p.dragging = true;
	p.last = at;
	return p.publish(vt);
}

export function drag(this p: Pointer, vt: Vt, at: Spot): Result<boolean, VtError> {
	const sel = p.sel;
	if (!p.dragging || sel === null) { return Result.ok(false); }
	const top = try vt.scrollOffset();
	const range = try vt.unitAt(sel.unit, { row: top + at.row, col: at.col });
	p.sel = sel.drag(range);
	p.last = at;
	return p.publish(vt);
}

export function release(this p: Pointer): void {
	p.dragging = false;
}

export function clear(this p: Pointer, vt: Vt): void {
	p.sel = null;
	p.dragging = false;
	vt.selectionClear();
}

export function sync(this p: Pointer, vt: Vt): Result<boolean, VtError> {
	const sel = p.shown();
	if (sel === null) { return Result.ok(false); }
	const now = try vt.selection();
	p.sel = sel.rebased(sel.bounds(), now);
	if (p.sel === null) { p.dragging = false; }
	return Result.ok(p.sel !== null);
}

export function copyText(this p: Pointer, vt: Vt): Result<string | null, VtError> {
	if (!p.selected()) { return Result.ok(null); }
	const text = try vt.selectedText();
	if (text === null || text == "") { return Result.ok(null); }
	// Typed local until card 2026-10-21-result-ok-drops-null-from-declared-return.md
	const found: string | null = text;
	return Result.ok(found);
}

export function blocks(
	this p: Pointer,
	vt: Vt,
	rows: int32,
	cols: int32,
): Result<Vec<Block>, VtError> {
	const sel = p.shown();
	if (sel === null) { return Result.ok([]); }
	const top = try vt.scrollOffset();
	return Result.ok(sel.marked().blocks(top, rows, cols));
}

const CELL_WIDTH: float64 = 8;
const ROW_HEIGHT: float64 = 16;
const REACH: float64 = CELL_WIDTH;

function viewOf(cols: int32, rows: int32, text: string): Vt | null {
	const created = Vt.create(cols, rows);
	if (!created.ok) { return null; }
	const vt = created.value;
	vt.writeText(text);
	if (!vt.update().ok) { return null; }
	return vt;
}

function spot(col: int32, row: int32): Spot {
	return { col: col, row: row };
}

function shaded(row: int32, col: int32, rows: int32, cols: int32): Block {
	return { row: row, col: col, rows: rows, cols: cols };
}

function click(p: Pointer, vt: Vt, col: int32, row: int32, time: float64): boolean {
	const x = col as float64 * CELL_WIDTH;
	const y = row as float64 * ROW_HEIGHT;
	return p.press(vt, spot(col, row), x, y, time, REACH).ok;
}

test "the spot under a point is its cell, held inside the grid" {
	assert spotAt(0, 0, 8, 16, 80, 24) == spot(0, 0);
	assert spotAt(7.9, 15.9, 8, 16, 80, 24) == spot(0, 0);
	assert spotAt(8, 16, 8, 16, 80, 24) == spot(1, 1);
	assert spotAt(-5, -5, 8, 16, 80, 24) == spot(0, 0);
	assert spotAt(9999, 9999, 8, 16, 80, 24) == spot(79, 23);
}

test "a press with no drag leaves nothing selected and a drag selects the cells it crosses" {
	const vt = viewOf(20, 3, "hello world");
	assert vt !== null;
	if (vt !== null) {
		const p = Pointer.open();
		assert click(p, vt, 1, 0, 0);
		assert !p.selected();
		assert p.copyText(vt).ok;
		assert p.drag(vt, spot(4, 0)).ok;
		assert p.selected();
		const text = p.copyText(vt);
		assert text.ok;
		if (text.ok) { assert text.value == "ello"; }
		p.release();
		assert p.selected();
		vt.free();
	}
}

test "a drag back past the press selects the other way" {
	const vt = viewOf(20, 3, "hello world");
	assert vt !== null;
	if (vt !== null) {
		const p = Pointer.open();
		assert click(p, vt, 8, 0, 0);
		assert p.drag(vt, spot(6, 0)).ok;
		const text = p.copyText(vt);
		assert text.ok;
		if (text.ok) { assert text.value == "wor"; }
		vt.free();
	}
}

test "a double click selects a word, a triple click the line, and a fourth starts over" {
	const vt = viewOf(20, 3, "foo bar-baz qux");
	assert vt !== null;
	if (vt !== null) {
		const p = Pointer.open();
		assert click(p, vt, 5, 0, 0);
		assert !p.selected();
		assert click(p, vt, 5, 0, 100);
		const word = p.copyText(vt);
		assert word.ok;
		if (word.ok) { assert word.value == "bar-baz"; }
		assert click(p, vt, 5, 0, 200);
		const line = p.copyText(vt);
		assert line.ok;
		if (line.ok) { assert line.value == "foo bar-baz qux"; }
		assert click(p, vt, 5, 0, 300);
		assert !p.selected();
		vt.free();
	}
}

test "a drag after a double click grows the selection by whole words" {
	const vt = viewOf(30, 3, "foo bar baz qux");
	assert vt !== null;
	if (vt !== null) {
		const p = Pointer.open();
		assert click(p, vt, 5, 0, 0);
		assert click(p, vt, 5, 0, 100);
		assert p.drag(vt, spot(9, 0)).ok;
		const text = p.copyText(vt);
		assert text.ok;
		if (text.ok) { assert text.value == "bar baz"; }
		vt.free();
	}
}

test "a click away from a selection clears it, and so does clear" {
	const vt = viewOf(20, 3, "hello world");
	assert vt !== null;
	if (vt !== null) {
		const p = Pointer.open();
		assert click(p, vt, 0, 0, 0);
		assert p.drag(vt, spot(4, 0)).ok;
		assert p.selected();
		p.release();
		assert click(p, vt, 9, 1, 2000);
		assert !p.selected();
		const gone = vt.selectedText();
		assert gone.ok;
		if (gone.ok) { assert gone.value === null; }
		assert p.drag(vt, spot(4, 0)).ok;
		assert p.selected();
		p.clear(vt);
		assert !p.selected();
		assert !p.dragging;
		vt.free();
	}
}

test "a move with no press in progress selects nothing" {
	const vt = viewOf(20, 3, "hello world");
	assert vt !== null;
	if (vt !== null) {
		const p = Pointer.open();
		const moved = p.drag(vt, spot(4, 0));
		assert moved.ok;
		if (moved.ok) { assert !moved.value; }
		assert !p.selected();
		vt.free();
	}
}

test "the highlight follows the selection into scrolled rows and out of view" {
	const vt = viewOf(10, 3, "a\r\nb\r\nc\r\nd\r\ne\r\nf");
	assert vt !== null;
	if (vt !== null) {
		const p = Pointer.open();
		assert click(p, vt, 0, 0, 0);
		assert p.drag(vt, spot(3, 1)).ok;
		const shown = p.blocks(vt, 3, 10);
		assert shown.ok;
		if (shown.ok) {
			assert shown.value.length == 2;
			assert shown.value[0] == shaded(0, 0, 1, 10);
			assert shown.value[1] == shaded(1, 0, 1, 4);
		}
		vt.scrollLines(-1);
		assert vt.update().ok;
		const above = p.blocks(vt, 3, 10);
		assert above.ok;
		if (above.ok) { assert above.value[0].row == 1; }
		vt.scrollTop();
		assert vt.update().ok;
		const out = p.blocks(vt, 3, 10);
		assert out.ok;
		if (out.ok) { assert out.value.length == 0; }
		vt.free();
	}
}

test "new output that scrolls the terminal moves the selection with its text" {
	const vt = viewOf(10, 3, "one\r\ntwo\r\nthree");
	assert vt !== null;
	if (vt !== null) {
		const p = Pointer.open();
		assert click(p, vt, 0, 1, 0);
		assert p.drag(vt, spot(2, 1)).ok;
		vt.writeText("\r\nfour\r\nfive");
		assert vt.update().ok;
		const kept = p.sync(vt);
		assert kept.ok;
		if (kept.ok) { assert kept.value; }
		const text = p.copyText(vt);
		assert text.ok;
		if (text.ok) { assert text.value == "two"; }
		vt.free();
	}
}

test "a selection the terminal let go of is dropped here too" {
	const vt = viewOf(10, 3, "hello");
	assert vt !== null;
	if (vt !== null) {
		const p = Pointer.open();
		assert click(p, vt, 0, 0, 0);
		assert p.drag(vt, spot(3, 0)).ok;
		vt.selectionClear();
		const kept = p.sync(vt);
		assert kept.ok;
		if (kept.ok) { assert !kept.value; }
		assert !p.selected();
		assert !p.dragging;
		vt.free();
	}
}

test "an app that tracks the mouse owns it unless shift is held" {
	assert claimsMouse(true, false);
	assert !claimsMouse(true, true);
	assert !claimsMouse(false, false);
	assert !claimsMouse(false, true);
}

test "a drag within a pixel of the top or the bottom scrolls that way" {
	assert autoscrollOf(-40, 300) == -1;
	assert autoscrollOf(1, 300) == -1;
	assert autoscrollOf(2, 300) == 0;
	assert autoscrollOf(299, 300) == 0;
	assert autoscrollOf(299.5, 300) == 1;
	assert autoscrollOf(420, 300) == 1;
}
