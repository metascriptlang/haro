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
	row: int32;
	from: int32;
	to: int32;
}

export struct Block {
	row: int32;
	col: int32;
	rows: int32;
	cols: int32;
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

export function spans(this m: Marked, top: int32, rows: int32, cols: int32): Vec<RowSpan> {
	const r = m.range;
	let out: Vec<RowSpan> = [];
	for (let y = 0; y < rows; y++) {
		const row = top + y;
		if (row < r.start.row || row > r.end.row) { continue; }
		const first = m.block || row == r.start.row ? r.start.col : 0;
		const last = m.block || row == r.end.row ? r.end.col : cols - 1;
		if (first >= cols) { continue; }
		out.push({ row: y, from: first, to: Math.min(last, cols - 1) });
	}
	return out;
}

function width(this s: RowSpan): int32 {
	return s.to - s.from + 1;
}

function isContinuedBy(this b: Block, s: RowSpan): boolean {
	return b.col == s.from && b.cols == s.width() && b.row + b.rows == s.row;
}

export function covering(this s: RowSpan, first: CellWidth, last: CellWidth): RowSpan {
	const from = first == CellWidth.Tail ? s.from - 1 : s.from;
	const to = last == CellWidth.Wide ? s.to + 1 : s.to;
	return { row: s.row, from: from, to: to };
}

export function merged(spans: Vec<RowSpan>): Vec<Block> {
	let out: Vec<Block> = [];
	for (const s of spans) {
		const n = out.length as int32;
		if (n > 0 && out[n - 1].isContinuedBy(s)) {
			out[n - 1].rows += 1;
			continue;
		}
		out.push({ row: s.row, col: s.from, rows: 1, cols: s.width() });
	}
	return out;
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
	return { ...sel, unit: Unit.Cell, origin: pointRange(now.range.start), focus: pointRange(now.range.end) };
}

function pointRange(at: Point): Range {
	return { start: at, end: at };
}

function at(row: int32, col: int32): Point {
	return { row: row, col: col };
}

function range(r0: int32, c0: int32, r1: int32, c1: int32): Range {
	return { start: at(r0, c0), end: at(r1, c1) };
}

function span(row: int32, from: int32, to: int32): RowSpan {
	return { row: row, from: from, to: to };
}

function block(row: int32, col: int32, rows: int32, cols: int32): Block {
	return { row: row, col: col, rows: rows, cols: cols };
}

test "a press with no drag selects nothing for a cell and the unit for a word" {
	const cell = Selection.press(Unit.Cell, pointRange(at(3, 4)), false);
	assert cell.collapsed();
	const word = Selection.press(Unit.Word, range(3, 4, 3, 8), false);
	assert !word.collapsed();
	assert word.bounds() == range(3, 4, 3, 8);
}

test "a drag backwards normalises to reading order" {
	const sel = Selection.press(Unit.Cell, pointRange(at(10, 5)), false)
		.drag(pointRange(at(8, 20)));
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

test "a linear selection highlights the first row's tail, the middle rows and the last row's head" {
	const m: Marked = { range: range(10, 5, 12, 3), block: false };
	const all = m.spans(8, 6, 20);
	assert all.length == 3;
	assert all[0] == span(2, 5, 19);
	assert all[1] == span(3, 0, 19);
	assert all[2] == span(4, 0, 3);
}

test "a selection partly above the viewport highlights only the rows in view" {
	const m: Marked = { range: range(2, 5, 12, 3), block: false };
	const lower = m.spans(10, 4, 20);
	assert lower.length == 3;
	assert lower[0] == span(0, 0, 19);
	assert lower[2] == span(2, 0, 3);
	const above = m.spans(30, 4, 20);
	assert above.length == 0;
	const below = m.spans(0, 2, 20);
	assert below.length == 0;
}

test "a single row selection is one span from its start to its end" {
	const m: Marked = { range: range(4, 6, 4, 9), block: false };
	const one = m.spans(0, 10, 20);
	assert one.length == 1;
	assert one[0] == span(4, 6, 9);
}

test "a block selection keeps the same columns on every row whichever corner it was dragged from" {
	const sel = Selection.press(Unit.Cell, pointRange(at(6, 12)), true).drag(pointRange(at(4, 3)));
	assert sel.bounds() == range(4, 3, 6, 12);
	const m = sel.marked();
	assert m.block;
	const rows = m.spans(0, 10, 20);
	assert rows.length == 3;
	assert rows[0] == span(4, 3, 12);
	assert rows[2] == span(6, 3, 12);
}

test "a span stops at the last column" {
	const m: Marked = { range: range(1, 2, 1, 40), block: false };
	assert m.spans(0, 3, 10)[0] == span(1, 2, 9);
}

test "a rebase follows the terminal's shift and drops a selection the terminal lost" {
	const sel = Selection.press(Unit.Cell, pointRange(at(10, 2)), false)
		.drag(pointRange(at(12, 4)));
	const was = sel.bounds();
	const kept = sel.rebased({ range: range(10, 2, 12, 4), block: false });
	assert kept !== null;
	if (kept !== null) { assert kept.bounds() == was; }
	const moved = sel.rebased({ range: range(7, 2, 9, 4), block: false });
	assert moved !== null;
	if (moved !== null) { assert moved.bounds() == range(7, 2, 9, 4); }
	assert sel.rebased(null) === null;
}

test "a linear selection draws as at most three rectangles: head, full middle rows, tail" {
	const m: Marked = { range: range(10, 5, 14, 3), block: false };
	const drawn = merged(m.spans(8, 10, 20));
	assert drawn.length == 3;
	assert drawn[0] == block(2, 5, 1, 15);
	assert drawn[1] == block(3, 0, 3, 20);
	assert drawn[2] == block(6, 0, 1, 4);
}

test "a head that starts at column 0 joins the full rows under it" {
	const m: Marked = { range: range(2, 0, 4, 7), block: false };
	const drawn = merged(m.spans(0, 10, 20));
	assert drawn.length == 2;
	assert drawn[0] == block(2, 0, 2, 20);
	assert drawn[1] == block(4, 0, 1, 8);
}

test "a block selection is one rectangle however many rows it covers" {
	const sel = Selection.press(Unit.Cell, pointRange(at(6, 12)), true).drag(pointRange(at(3, 3)));
	const drawn = merged(sel.marked().spans(0, 10, 20));
	assert drawn.length == 1;
	assert drawn[0] == block(3, 3, 4, 10);
}

test "a wide character is shaded whole whichever of its cells the selection reaches" {
	const s = span(0, 3, 6);
	assert s.covering(CellWidth.Narrow, CellWidth.Wide) == span(0, 3, 7);
	assert s.covering(CellWidth.Tail, CellWidth.Tail) == span(0, 2, 6);
	assert span(0, 3, 3).covering(CellWidth.Tail, CellWidth.Tail) == span(0, 2, 3);
}

test "a selection scrolled out of view draws nothing" {
	const m: Marked = { range: range(2, 5, 4, 3), block: false };
	assert merged(m.spans(30, 5, 20)).length == 0;
}
