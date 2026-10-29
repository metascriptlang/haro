import { Point, Range, Selection, Unit, pointRange } from "./select";

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
	const sel = Selection.press(Unit.Cell, at(6, 12).pointRange(), true)
		.drag(at(4, 3).pointRange());
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
