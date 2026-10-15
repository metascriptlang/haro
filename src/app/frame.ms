import { List } from "../../../neon/src/core/list";
import { GridLine, line } from "../grid/lines";
import { Cursor, Vt } from "../vt/vt";

export interface RowSlot {
	line: GridLine;
}

export enum FrameError {
	UpdateFailed,
	CursorFailed,
	DirtyRowsFailed,
	LineFailed,
}

export function applyFrame(grid: List<RowSlot>, vt: Vt): Result<Cursor | null, FrameError> {
	if (!vt.update().ok) { return Result.err(FrameError.UpdateFailed); }
	const at = vt.cursor();
	if (!at.ok) { return Result.err(FrameError.CursorFailed); }
	const cursor = at.value;
	const dirty = vt.dirtyRows();
	if (!dirty.ok) { return Result.err(FrameError.DirtyRowsFailed); }
	for (const row of dirty.value) {
		const cursorCell = cursor !== null && cursor.y == row.y ? cursor.x : -1;
		const built = row.line(cursorCell);
		if (!built.ok) { return Result.err(FrameError.LineFailed); }
		grid.set(row.y, { line: built.value });
	}
	vt.clean();
	return Result.ok(cursor);
}
