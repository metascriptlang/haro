export struct Point {
	row: int32;
	col: int32;
}

export struct Range {
	start: Point;
	end: Point;
}

export enum Unit {
	Cell,
	Word,
	Line,
}

export struct Marked {
	range: Range;
	block: boolean;
}

export struct Selection {
	unit: Unit;
	origin: Range;
	focus: Range;
	block: boolean;
}

export enum CellWidth {
	Narrow,
	Wide,
	Tail,
}

export struct RowSpan {
	from: int32;
	to: int32;
}

function precedes(this a: Point, b: Point): boolean {
	return a.row < b.row || (a.row == b.row && a.col < b.col);
}

export function press(this typeof Selection, unit: Unit, at: Range, block: boolean): Selection {
	return { unit: unit, origin: at, focus: at, block: block };
}

export function drag(this sel: Selection, to: Range): Selection {
	return { ...sel, focus: to };
}

export function collapsed(this sel: Selection): boolean {
	return sel.unit == Unit.Cell && sel.origin == sel.focus;
}

export function bounds(this sel: Selection): Range {
	const a = sel.origin;
	const b = sel.focus;
	if (sel.block) {
		const top = Math.min(Math.min(a.start.row, a.end.row), Math.min(b.start.row, b.end.row));
		const bottom = Math.max(Math.max(a.start.row, a.end.row), Math.max(b.start.row, b.end.row));
		const left = Math.min(Math.min(a.start.col, a.end.col), Math.min(b.start.col, b.end.col));
		const right = Math.max(Math.max(a.start.col, a.end.col), Math.max(b.start.col, b.end.col));
		return { start: { row: top, col: left }, end: { row: bottom, col: right } };
	}
	const start = b.start.precedes(a.start) ? b.start : a.start;
	const end = a.end.precedes(b.end) ? b.end : a.end;
	return { start: start, end: end };
}

export function marked(this sel: Selection): Marked {
	return { range: sel.bounds(), block: sel.block };
}

function shiftedBy(this r: Range, rows: int32): Range {
	return {
		start: { row: r.start.row + rows, col: r.start.col },
		end: { row: r.end.row + rows, col: r.end.col },
	};
}

export function rebased(this sel: Selection, now: Marked | null): Selection | null {
	if (now === null) { return null; }
	const was = sel.bounds();
	const shift = now.range.end.row - was.end.row;
	if (now.range == was.shiftedBy(shift)) {
		if (shift == 0) { return sel; }
		return { ...sel, origin: sel.origin.shiftedBy(shift), focus: sel.focus.shiftedBy(shift) };
	}
	return {
		...sel,
		unit: Unit.Cell,
		origin: now.range.start.pointRange(),
		focus: now.range.end.pointRange(),
	};
}

function pointRange(this point: Point): Range {
	return { start: point, end: point };
}

function at(row: int32, col: int32): Point {
	return { row: row, col: col };
}

function range(r0: int32, c0: int32, r1: int32, c1: int32): Range {
	return { start: at(r0, c0), end: at(r1, c1) };
}

test "a press with no drag selects nothing for a cell and the unit for a word" {
	const cell = Selection.press(Unit.Cell, at(3, 4).pointRange(), false);
	assert cell.collapsed();
	const word = Selection.press(Unit.Word, range(3, 4, 3, 8), false);
	assert !word.collapsed();
	assert word.bounds() == range(3, 4, 3, 8);
}

test "a drag backwards normalises to reading order" {
	const sel = Selection.press(Unit.Cell, at(10, 5).pointRange(), false)
		.drag(at(8, 20).pointRange());
	assert !sel.collapsed();
	assert sel.bounds() == range(8, 20, 10, 5);
}

test "a drag after a word press keeps the whole word in either direction" {
	const word: Range = range(5, 10, 5, 14);
	const forward = Selection.press(Unit.Word, word, false).drag(range(5, 20, 5, 25));
	assert forward.bounds() == range(5, 10, 5, 25);
	const backward = Selection.press(Unit.Word, word, false).drag(range(4, 2, 4, 6));
	assert backward.bounds() == range(4, 2, 5, 14);
}

test "a block selection keeps the same columns on every row whichever corner it was dragged from" {
	const sel = Selection.press(Unit.Cell, at(6, 12).pointRange(), true).drag(at(4, 3).pointRange());
	assert sel.bounds() == range(4, 3, 6, 12);
	assert sel.marked().block;
}

test "a rebase follows the terminal's shift and drops a selection the terminal lost" {
	const sel = Selection.press(Unit.Cell, at(10, 2).pointRange(), false)
		.drag(at(12, 4).pointRange());
	const was = sel.bounds();
	const kept = sel.rebased({ range: range(10, 2, 12, 4), block: false });
	assert kept !== null;
	if (kept !== null) { assert kept.bounds() == was; }
	const moved = sel.rebased({ range: range(7, 2, 9, 4), block: false });
	assert moved !== null;
	if (moved !== null) { assert moved.bounds() == range(7, 2, 9, 4); }
	assert sel.rebased(null) === null;
}
