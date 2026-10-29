import { Palette, Row, Vt, VtError } from "../vt/vt";

export enum PlanKind {
	Idle,
	Rows,
	Scroll,
	Repaint,
}

export struct Plan {
	kind: PlanKind;
	scrolled: int32;
	ys: Vec<int32>;
	colors: Palette;
}

function sameContent(this a: Readonly<Row>, b: Readonly<Row>): boolean {
	return a.cells == b.cells && a.extra == b.extra && a.selected == b.selected;
}

function scrolledRows(this vt: Vt): Result<int32 | null, VtError> {
	const anchored = try vt.anchoredRow();
	if (anchored === null) { return Result.ok(null); }
	const offset = try vt.scrollOffset();
	// Typed local until card 2026-10-21-result-ok-drops-null-from-declared-return.md
	const scrolled: int32 | null = offset - anchored;
	return Result.ok(scrolled);
}

function changedRowsAfterScroll(all: Readonly<Span<Row>>, painted: Readonly<Span<Row>>, scrolled: int32): Vec<int32> {
	const rowCount = all.length as int32;
	let out: Vec<int32> = [];
	for (let y = 0; y < rowCount; y++) {
		const isNew = y >= rowCount - scrolled;
		if (isNew || !all[y].sameContent(painted[y + scrolled])) { out.push(y); }
	}
	return out;
}

export function plan(this vt: Vt): Result<Plan, VtError> {
	try vt.update();
	const rowCount = (try vt.size())[1];
	const alternate = try vt.alternateScreen();
	const colors = try vt.palette();
	const painted = vt.painted;
	const recoloured = painted.palette !== null && painted.palette != colors;
	const scrolled = try vt.scrolledRows();
	let kind = PlanKind.Rows;
	let moved = 0;
	const resized = (painted.rows.length as int32) != rowCount;
	if (resized || painted.alternate != alternate || recoloured) {
		kind = PlanKind.Repaint;
	} else if (scrolled === null || scrolled < 0 || scrolled >= rowCount) {
		kind = PlanKind.Repaint;
	} else if (scrolled > 0) {
		kind = PlanKind.Scroll;
		moved = scrolled;
	}
	let ys: Vec<int32> = [];
	let fresh: Vec<Row> = [];
	match (kind) {
		PlanKind.Rows => {
			let dirty = try vt.dirtyRows();
			if (dirty.length == 0) { kind = PlanKind.Idle; }
			while (dirty.length > 0) {
				const row = dirty.pop();
				if (row.sameContent(painted.rows[row.y])) { continue; }
				ys.push(row.y);
				fresh.push(row);
			}
			ys.reverse();
		},
		PlanKind.Scroll => {
			fresh = try vt.rows();
			ys = changedRowsAfterScroll(fresh, painted.rows, moved);
		},
		PlanKind.Repaint => {
			fresh = try vt.rows();
			for (let y = 0; y < (fresh.length as int32); y++) { ys.push(y); }
		},
		PlanKind.Idle => {},
	}
	if (kind != PlanKind.Idle) {
		try vt.anchorTop();
	}
	if (kind == PlanKind.Rows) {
		for (const row of fresh) { painted.rows[row.y] = row; }
	} else if (kind != PlanKind.Idle) {
		painted.rows = fresh;
	}
	painted.alternate = alternate;
	painted.palette = colors;
	vt.clean();
	return Result.ok({ kind: kind, scrolled: moved, ys: ys, colors: colors });
}
