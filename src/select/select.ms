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

export function pointRange(this point: Point): Range {
	return { start: point, end: point };
}
