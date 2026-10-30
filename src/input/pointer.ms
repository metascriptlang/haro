import { KeyMod, modSet } from "../keys/keys";
import { chordOf } from "./bindings";
import { Link } from "../screen/linksGrid";
import { Point, Selection, Unit } from "../select/select";
import { Vt, VtError } from "../vt/vt";
import { Clicks, unitOf } from "./clicks";

export struct Spot {
	col: int32;
	row: int32;
}

export interface Pointer {
	clicks: Clicks;
	anchor: Point;
	sel: Selection | null;
	dragging: boolean;
	last: Spot;
	hover: Link | null;
	over: Spot | null;
	copyOnSelect: boolean;
}

export function open(this typeof Pointer): Pointer {
	return {
		clicks: Clicks.open(),
		anchor: { row: 0, col: 0 },
		sel: null,
		dragging: false,
		last: { col: 0, row: 0 },
		hover: null,
		over: null,
		copyOnSelect: false,
	};
}

export function showHover(this p: Pointer, link: Link | null): boolean {
	if (p.hover == link) { return false; }
	p.hover = link;
	return true;
}

export function spotAt(
	x: float64,
	y: float64,
	cellWidth: float64,
	rowHeight: float64,
	cols: int32,
	rows: int32,
): Spot {
	return { col: cellIndex(x, cellWidth, cols), row: cellIndex(y, rowHeight, rows) };
}

function cellIndex(offset: float64, size: float64, count: int32): int32 {
	if (!(size > 0)) { return 0; }
	const cell = Math.floor(offset / size);
	if (Number.isNaN(cell)) { return 0; }
	return Math.max(0, Math.min(cell, count - 1)) as int32;
}

const AUTOSCROLL_EDGE_PX: float64 = 1;

export function autoscrollOf(yPx: float64, heightPx: float64): int32 {
	if (yPx <= AUTOSCROLL_EDGE_PX) { return -1; }
	if (yPx > heightPx - AUTOSCROLL_EDGE_PX) { return 1; }
	return 0;
}

when (macos) {
	export const OPEN_MOD: KeyMod = KeyMod.Super;
} else {
	export const OPEN_MOD: KeyMod = KeyMod.Ctrl;
}

export function opensLinks(mods: BitSet<KeyMod>): boolean {
	return chordOf(mods) == modSet(OPEN_MOD);
}

export function rectangular(mods: BitSet<KeyMod>): boolean {
	when (macos) {
		return mods.has(KeyMod.Alt);
	} else {
		return mods.has(KeyMod.Ctrl) && mods.has(KeyMod.Alt);
	}
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
		try vt.selectionClear();
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
	block: boolean = false,
): Result<boolean, VtError> {
	p.hover = null;
	const count = p.clicks.register(x, y, time, reach);
	const top = try vt.scrollOffset();
	if (count == 1) { p.anchor = { row: top + at.row, col: at.col }; }
	const unit = unitOf(count);
	const range = try vt.unitAt(unit, p.anchor);
	p.sel = Selection.press(unit, range, block && unit == Unit.Cell);
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

export function canExtend(this p: Pointer, time: float64): boolean {
	return p.shown() !== null && !p.clicks.recent(time);
}

export function extend(this p: Pointer, vt: Vt, at: Spot): Result<boolean, VtError> {
	p.hover = null;
	p.dragging = true;
	return p.drag(vt, at);
}

export function release(this p: Pointer): void {
	p.dragging = false;
}

export function clear(this p: Pointer, vt: Vt): Result<void, VtError> {
	p.sel = null;
	p.dragging = false;
	return vt.selectionClear();
}

export function sync(this p: Pointer, vt: Vt): Result<boolean, VtError> {
	const sel = p.shown();
	if (sel === null) { return Result.ok(false); }
	const now = try vt.selection();
	p.sel = sel.rebased(now);
	if (p.shown() === null) {
		try p.clear(vt);
		return Result.ok(false);
	}
	return Result.ok(true);
}

export function copyText(this p: Pointer, vt: Vt): Result<string | null, VtError> {
	if (!p.selected()) { return Result.ok(null); }
	const text = try vt.selectedText();
	if (text === null || text == "") { return Result.ok(null); }
	// Typed local until card 2026-10-28-result-ok-of-a-struct-is-not-assignable-to-a-nullable-result.md
	const found: string | null = text;
	return Result.ok(found);
}

const CELL_WIDTH: float64 = 8;
const ROW_HEIGHT: float64 = 16;
const REACH: float64 = CELL_WIDTH;

function viewOf(cols: int32, rows: int32, text: string): Vt | null {
	const created = Vt.create(cols, rows);
	if (!created.ok) { return null; }
	const vt = created.value;
	vt.writeText(text);
	if (!vt.update().ok) {
		vt.free();
		return null;
	}
	return vt;
}

function spot(col: int32, row: int32): Spot {
	return { col: col, row: row };
}

function click(
	this p: Pointer,
	vt: Vt,
	col: int32,
	row: int32,
	time: float64,
	block: boolean = false,
): boolean {
	const x = col as float64 * CELL_WIDTH;
	const y = row as float64 * ROW_HEIGHT;
	return p.press(vt, spot(col, row), x, y, time, REACH, block).ok;
}

function copied(this p: Pointer, vt: Vt): string {
	const text = p.copyText(vt);
	return text.ok ? (text.value ?? "none") : "read failed";
}

test "the spot under a point is its cell, held inside the grid" {
	assert spotAt(0, 0, 8, 16, 80, 24) == spot(0, 0);
	assert spotAt(7.9, 15.9, 8, 16, 80, 24) == spot(0, 0);
	assert spotAt(8, 16, 8, 16, 80, 24) == spot(1, 1);
	assert spotAt(-5, -5, 8, 16, 80, 24) == spot(0, 0);
	assert spotAt(9999, 9999, 8, 16, 80, 24) == spot(79, 23);
}

test "a point or cell size that is not a usable number lands on the first cell" {
	assert spotAt(NaN, 5, 8, 16, 80, 24) == spot(0, 0);
	assert spotAt(5, 5, 0, 0, 80, 24) == spot(0, 0);
	assert spotAt(1e30, 1e30, 8, 16, 80, 24) == spot(79, 23);
	assert spotAt(Infinity, 5, 8, 16, 80, 24) == spot(79, 0);
}

test "a press with no drag leaves nothing selected and a drag selects the cells it crosses" {
	const vt = viewOf(20, 3, "hello world");
	assert vt !== null;
	if (vt !== null) {
		defer vt.free();
		const p = Pointer.open();
		assert p.click(vt, 1, 0, 0);
		assert !p.selected();
		assert p.copyText(vt).ok;
		assert p.drag(vt, spot(4, 0)).ok;
		assert p.selected();
		assert p.copied(vt) == "ello";
		p.release();
		assert p.selected();
	}
}

test "a rectangular drag copies the block of cells between its corners, one line per row" {
	const vt = viewOf(10, 3, "abcdef\r\nghijkl\r\nmnopqr");
	assert vt !== null;
	if (vt !== null) {
		defer vt.free();
		const p = Pointer.open();
		assert p.click(vt, 1, 0, 0, true);
		assert p.drag(vt, spot(3, 2)).ok;
		assert p.copied(vt) == "bcd\nhij\nnop";
		assert p.drag(vt, spot(0, 1)).ok;
		assert p.copied(vt) == "ab\ngh";
		const q = Pointer.open();
		assert q.click(vt, 1, 0, 1000);
		assert q.drag(vt, spot(3, 2)).ok;
		assert q.copied(vt) == "bcdef\nghijkl\nmnop";
	}
}

test "a double click stays a word selection even with the rectangle modifiers held" {
	const vt = viewOf(20, 3, "foo bar baz");
	assert vt !== null;
	if (vt !== null) {
		defer vt.free();
		const p = Pointer.open();
		assert p.click(vt, 5, 0, 0, true);
		assert p.click(vt, 5, 0, 100, true);
		assert p.copied(vt) == "bar";
		assert p.sel !== null;
		if (p.sel !== null) { assert !p.sel.block; }
	}
}

test "rectangular selection takes Option on macOS and Ctrl with Alt elsewhere" {
	const none = 0 as BitSet<KeyMod>;
	assert !rectangular(none);
	assert !rectangular(none.incl(KeyMod.Shift));
	when (macos) {
		assert rectangular(none.incl(KeyMod.Alt));
		assert !rectangular(none.incl(KeyMod.Ctrl));
	} else {
		assert rectangular(none.incl(KeyMod.Ctrl).incl(KeyMod.Alt));
		assert !rectangular(none.incl(KeyMod.Alt));
		assert !rectangular(none.incl(KeyMod.Ctrl));
	}
}

test "a later press may extend a selection, but not one that would count as a repeated click" {
	const vt = viewOf(20, 3, "hello world");
	assert vt !== null;
	if (vt !== null) {
		defer vt.free();
		const p = Pointer.open();
		assert !p.canExtend(10000);
		assert p.click(vt, 1, 0, 0);
		assert !p.canExtend(10000);
		assert p.drag(vt, spot(4, 0)).ok;
		p.release();
		assert !p.canExtend(100);
		assert p.canExtend(10000);
		assert p.extend(vt, spot(8, 0)).ok;
		assert p.dragging;
		assert p.copied(vt) == "ello wor";
		assert p.drag(vt, spot(0, 0)).ok;
		assert p.copied(vt) == "he";
	}
}

test "a drag back past the press selects the other way" {
	const vt = viewOf(20, 3, "hello world");
	assert vt !== null;
	if (vt !== null) {
		defer vt.free();
		const p = Pointer.open();
		assert p.click(vt, 8, 0, 0);
		assert p.drag(vt, spot(6, 0)).ok;
		assert p.copied(vt) == "wor";
	}
}

test "a double click selects a word, a triple click the line, and a fourth starts over" {
	const vt = viewOf(20, 3, "foo bar-baz qux");
	assert vt !== null;
	if (vt !== null) {
		defer vt.free();
		const p = Pointer.open();
		assert p.click(vt, 5, 0, 0);
		assert !p.selected();
		assert p.click(vt, 5, 0, 100);
		assert p.copied(vt) == "bar-baz";
		assert p.click(vt, 5, 0, 200);
		assert p.copied(vt) == "foo bar-baz qux";
		assert p.click(vt, 5, 0, 300);
		assert !p.selected();
	}
}

test "a double click takes its word from the first press, though the second drifts a cell" {
	const vt = viewOf(20, 3, "foo bar baz");
	assert vt !== null;
	if (vt !== null) {
		defer vt.free();
		const p = Pointer.open();
		assert p.click(vt, 4, 0, 0);
		assert p.click(vt, 3, 0, 100);
		assert p.copied(vt) == "bar";
	}
}

test "a drag after a double click grows the selection by whole words" {
	const vt = viewOf(30, 3, "foo bar baz qux");
	assert vt !== null;
	if (vt !== null) {
		defer vt.free();
		const p = Pointer.open();
		assert p.click(vt, 5, 0, 0);
		assert p.click(vt, 5, 0, 100);
		assert p.drag(vt, spot(9, 0)).ok;
		assert p.copied(vt) == "bar baz";
	}
}

test "a click away from a selection clears it, and so does clear" {
	const vt = viewOf(20, 3, "hello world");
	assert vt !== null;
	if (vt !== null) {
		defer vt.free();
		const p = Pointer.open();
		assert p.click(vt, 0, 0, 0);
		assert p.drag(vt, spot(4, 0)).ok;
		assert p.selected();
		p.release();
		assert p.click(vt, 9, 1, 2000);
		assert !p.selected();
		const gone = vt.selectedText();
		assert gone.ok;
		if (gone.ok) { assert gone.value === null; }
		assert p.drag(vt, spot(4, 0)).ok;
		assert p.selected();
		assert p.clear(vt).ok;
		assert !p.selected();
		assert !p.dragging;
	}
}

test "a move with no press in progress selects nothing" {
	const vt = viewOf(20, 3, "hello world");
	assert vt !== null;
	if (vt !== null) {
		defer vt.free();
		const p = Pointer.open();
		const moved = p.drag(vt, spot(4, 0));
		assert moved.ok;
		if (moved.ok) { assert !moved.value; }
		assert !p.selected();
	}
}

function prunedLines(from: int32, count: int32): string {
	let text = "";
	for (let i = 0; i < count; i++) { text += `\nr${from + i}`; }
	return text;
}

const PAGE_SPAN: int32 = 700;

function prunable(): Vt | null {
	const vt = viewOf(80, 4, "r0");
	if (vt === null) { return null; }
	if (!vt.setScrollback(1000).ok) {
		vt.free();
		return null;
	}
	vt.writeText(prunedLines(1, 6000));
	for (let next = 6001; next < 8001; next += 20) {
		const offset = vt.update().ok ? vt.scrollOffset() : null;
		if (offset === null || !offset.ok) {
			vt.free();
			return null;
		}
		if (offset.value >= PAGE_SPAN) { return vt; }
		vt.writeText(prunedLines(next, 20));
	}
	vt.free();
	return null;
}

function pruneOnePage(this vt: Vt): boolean {
	const before = vt.scrollOffset();
	if (!before.ok) { return false; }
	for (let i = 0; i < 100; i++) {
		vt.writeText(prunedLines(100000 + i * 20, 20));
		if (!vt.update().ok) { return false; }
		const after = vt.scrollOffset();
		if (!after.ok) { return false; }
		if (after.value < before.value) { return true; }
	}
	return false;
}

test "a selection whose start is pruned from scrollback shows what the terminal still holds" {
	const vt = prunable();
	assert vt !== null;
	if (vt !== null) {
		defer vt.free();
		const bottom = (try vt.scrollOffset() catch 0) + 3;
		const p = Pointer.open();
		const sel = Selection
			.press(Unit.Cell, { start: { row: 0, col: 1 }, end: { row: 0, col: 1 } }, false)
			.drag({ start: { row: bottom, col: 2 }, end: { row: bottom, col: 2 } });
		p.sel = sel;
		assert vt.selectionSet(sel.marked()).ok;
		assert vt.pruneOnePage();
		const kept = p.sync(vt);
		assert kept.ok;
		if (kept.ok) { assert kept.value; }
		const now = vt.selection();
		assert now.ok;
		if (now.ok) {
			const m = now.value;
			assert m !== null;
			if (m !== null) {
				assert m.range.start.row == 0 && m.range.start.col == 0;
				assert p.sel !== null;
				if (p.sel !== null) { assert p.sel.marked().range == m.range; }
			}
		}
	}
}

test "a selection pruned whole from scrollback is gone" {
	const vt = prunable();
	assert vt !== null;
	if (vt !== null) {
		defer vt.free();
		const p = Pointer.open();
		const sel = Selection
			.press(Unit.Cell, { start: { row: 0, col: 0 }, end: { row: 0, col: 0 } }, false)
			.drag({ start: { row: 1, col: 1 }, end: { row: 1, col: 1 } });
		p.sel = sel;
		assert vt.selectionSet(sel.marked()).ok;
		assert vt.pruneOnePage();
		const kept = p.sync(vt);
		assert kept.ok;
		if (kept.ok) { assert !kept.value; }
		assert !p.selected();
		const now = vt.selection();
		assert now.ok;
		if (now.ok) { assert now.value === null; }
	}
}

test "new output that scrolls the terminal moves the selection with its text" {
	const vt = viewOf(10, 3, "one\r\ntwo\r\nthree");
	assert vt !== null;
	if (vt !== null) {
		defer vt.free();
		const p = Pointer.open();
		assert p.click(vt, 0, 1, 0);
		assert p.drag(vt, spot(2, 1)).ok;
		vt.writeText("\r\nfour\r\nfive");
		assert vt.update().ok;
		const kept = p.sync(vt);
		assert kept.ok;
		if (kept.ok) { assert kept.value; }
		assert p.copied(vt) == "two";
	}
}

test "a selection the terminal let go of is dropped here too" {
	const vt = viewOf(10, 3, "hello");
	assert vt !== null;
	if (vt !== null) {
		defer vt.free();
		const p = Pointer.open();
		assert p.click(vt, 0, 0, 0);
		assert p.drag(vt, spot(3, 0)).ok;
		assert vt.selectionClear().ok;
		const kept = p.sync(vt);
		assert kept.ok;
		if (kept.ok) { assert !kept.value; }
		assert !p.selected();
		assert !p.dragging;
	}
}

test "only the open modifier alone opens links: Cmd on macOS, Ctrl elsewhere" {
	const none = 0 as BitSet<KeyMod>;
	assert opensLinks(none.incl(OPEN_MOD));
	assert opensLinks(none.incl(OPEN_MOD).incl(KeyMod.CapsLock).incl(KeyMod.NumLock));
	assert !opensLinks(none);
	assert !opensLinks(none.incl(OPEN_MOD).incl(KeyMod.Shift));
	assert !opensLinks(none.incl(OPEN_MOD).incl(KeyMod.Alt));
	assert !opensLinks(none.incl(KeyMod.Alt));
	when (macos) {
		assert !opensLinks(none.incl(KeyMod.Ctrl));
	} else {
		assert !opensLinks(none.incl(KeyMod.Super));
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

function selectedAndCopied(this p: Pointer, vt: Vt, from: int32, to: int32): string {
	if (!p.click(vt, from, 0, 0) || !p.drag(vt, spot(to, 0)).ok) { return "select failed"; }
	return p.copied(vt);
}

test "a wide character is copied whole whichever of its cells the selection reaches" {
	const vt = viewOf(10, 1, "中文 x");
	assert vt !== null;
	if (vt !== null) {
		defer vt.free();
		assert Pointer.open().selectedAndCopied(vt, 0, 2) == "中文";
		assert Pointer.open().selectedAndCopied(vt, 1, 4) == "中文";
	}
}

test "a wide character in a row scrolled into view is copied whole" {
	const vt = viewOf(10, 1, "a\r\n中文 x\r\nab");
	assert vt !== null;
	if (vt !== null) {
		defer vt.free();
		vt.scrollLines(-1);
		assert vt.update().ok;
		assert Pointer.open().selectedAndCopied(vt, 1, 2) == "中文";
	}
}
