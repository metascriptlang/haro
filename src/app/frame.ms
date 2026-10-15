import { List } from "../../../neon/src/core/list";
import { GridLine, line } from "../grid/lines";
import { PlanKind, plan } from "../screen/plan";
import { Cursor, Row, Vt } from "../vt/vt";

export interface RowSlot {
	line: GridLine;
}

export enum FrameError {
	PlanFailed,
	CursorFailed,
	LineFailed,
}

function slotOf(row: Row, cursor: Cursor | null): Result<RowSlot, FrameError> {
	const cursorCell = cursor !== null && cursor.y == row.y ? cursor.x : -1;
	const built = row.line(cursorCell);
	if (!built.ok) { return Result.err(FrameError.LineFailed); }
	return Result.ok({ line: built.value });
}

export function applyFrame(grid: List<RowSlot>, vt: Vt): Result<Cursor | null, FrameError> {
	const planned = vt.plan();
	if (!planned.ok) { return Result.err(FrameError.PlanFailed); }
	const at = vt.cursor();
	if (!at.ok) { return Result.err(FrameError.CursorFailed); }
	const cursor = at.value;
	const p = planned.value;
	const kept = (grid.length() as int32) - p.scrolled;
	for (let i = 0; i < p.scrolled; i++) { grid.remove(0); }
	for (const row of p.rows) {
		const slot = try slotOf(row, cursor);
		if (p.kind == PlanKind.Scroll && row.y >= kept) {
			grid.push(slot);
		} else {
			grid.set(row.y, slot);
		}
	}
	return Result.ok(cursor);
}
