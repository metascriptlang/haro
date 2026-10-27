import { CellInk, GridLine, cellOnRow, line } from "../grid/lines";
import { plan } from "../screen/plan";
import { Cursor, Rgb, Row, Vt } from "../vt/vt";

export const SELECTION: CellInk = { fg: null, bg: null };

export enum FrameError {
	PlanFailed,
	CursorFailed,
	LineFailed,
}

function inkOn(this ink: CellInk | null, cell: int32): CellInk | null {
	return cell >= 0 ? ink : null;
}

export struct Shown {
	cell: int32;
	ink: CellInk | null;
}

export struct RowUpdate {
	y: int32;
	line: GridLine;
}

export struct FrameRows {
	scrolled: int32;
	rows: Vec<RowUpdate>;
	background: Rgb;
}

export function none(this typeof FrameRows): FrameRows {
	return { scrolled: 0, rows: [], background: { r: 0, g: 0, b: 0 } };
}

export function fitShown(ref shown: Vec<Shown>, rows: int32): void {
	while ((shown.length as int32) < rows) { shown.push({ cell: -1, ink: null }); }
	while ((shown.length as int32) > rows) { shown.pop(); }
}

function rowOf(
	ref shown: Vec<Shown>,
	row: Row,
	cursor: Cursor | null,
	ink: CellInk | null,
	background: Rgb,
): Result<RowUpdate, FrameError> {
	const cell = cursor.cellOnRow(row.y);
	const built = row.line(cell, ink.inkOn(cell), SELECTION, background);
	if (!built.ok) { return Result.err(FrameError.LineFailed); }
	shown[row.y] = { cell: cell, ink: ink.inkOn(cell) };
	return Result.ok({ y: row.y, line: move built.value });
}

function relight(
	ref out: Vec<RowUpdate>,
	ref shown: Vec<Shown>,
	vt: Vt,
	cursor: Cursor | null,
	ink: CellInk | null,
	background: Rgb,
): Result<void, FrameError> {
	for (let i = 0; i < vt.painted.rows.length; i++) {
		const y = vt.painted.rows[i].y;
		const cell = cursor.cellOnRow(y);
		if (shown[y].cell != cell || shown[y].ink != ink.inkOn(cell)) {
			const built = try rowOf(shown, vt.painted.rows[i], cursor, ink, background);
			out.push(move built);
		}
	}
	return Result.ok(null);
}

export function relitRows(ref shown: Vec<Shown>, vt: Vt, ink: CellInk | null): Result<FrameRows, FrameError> {
	const colors = vt.painted.palette;
	if (colors === null || shown.length != vt.painted.rows.length) { return Result.ok(FrameRows.none()); }
	const at = vt.cursor();
	if (!at.ok) { return Result.err(FrameError.CursorFailed); }
	let rows: Vec<RowUpdate> = [];
	const _relit = try relight(rows, shown, vt, at.value, ink, colors.bg);
	return Result.ok({ scrolled: 0, rows: rows, background: colors.bg });
}

export struct Planned {
	cursor: Cursor | null;
	rows: FrameRows;
}

export function planRows(ref shown: Vec<Shown>, vt: Vt, ink: CellInk | null): Result<Planned, FrameError> {
	const planned = vt.plan();
	if (!planned.ok) { return Result.err(FrameError.PlanFailed); }
	const at = vt.cursor();
	if (!at.ok) { return Result.err(FrameError.CursorFailed); }
	const cursor = at.value;
	const p = planned.value;
	for (let i = 0; i < p.scrolled; i++) { shown.push(shown.shift()); }
	let rows: Vec<RowUpdate> = [];
	for (const y of p.ys) {
		const built = try rowOf(shown, vt.painted.rows[y], cursor, ink, p.colors.bg);
		rows.push(move built);
	}
	const _relit = try relight(rows, shown, vt, cursor, ink, p.colors.bg);
	return Result.ok({ cursor: cursor, rows: { scrolled: p.scrolled, rows: rows, background: p.colors.bg } });
}
