import { Row, Vt, VtError } from "../vt/vt";

export enum PlanKind {
	Idle,
	Rows,
	Scroll,
	Repaint,
}

export struct Plan {
	kind: PlanKind;
	scrolled: int32;
	rows: Vec<Row>;
}

function sameRow(a: Row, b: Row): boolean {
	if (a.cells.length != b.cells.length || a.extra.length != b.extra.length) { return false; }
	for (let i = 0; i < (a.cells.length as int32); i++) {
		if (a.cells[i] != b.cells[i]) { return false; }
	}
	for (let i = 0; i < (a.extra.length as int32); i++) {
		if (a.extra[i] != b.extra[i]) { return false; }
	}
	return true;
}

function scrolledRows(this vt: Vt): Result<int32 | null, VtError> {
	const anchored = try vt.anchoredRow();
	if (anchored === null) { return Result.ok(null); }
	const offset = try vt.scrollOffset();
	const scrolled: int32 | null = offset - anchored;
	return Result.ok(scrolled);
}

function keptRowsChanged(all: Vec<Row>, painted: Vec<Row>, scrolled: int32): Vec<Row> {
	const rowCount = all.length as int32;
	let out: Vec<Row> = [];
	for (let y = 0; y < rowCount; y++) {
		const isNew = y >= rowCount - scrolled;
		if (isNew || !sameRow(all[y], painted[y + scrolled])) { out.push(all[y]); }
	}
	return out;
}

export function plan(this vt: Vt): Result<Plan, VtError> {
	const updated = try vt.update();
	const rowCount = (try vt.size())[1];
	const alternate = try vt.alternateScreen();
	const painted = vt.painted;
	const scrolled = try vt.scrolledRows();
	let kind = PlanKind.Rows;
	let moved = 0;
	if ((painted.rows.length as int32) != rowCount || painted.alternate != alternate) {
		kind = PlanKind.Repaint;
	} else if (scrolled === null || scrolled < 0 || scrolled >= rowCount) {
		kind = PlanKind.Repaint;
	} else if (scrolled > 0) {
		kind = PlanKind.Scroll;
		moved = scrolled;
	}
	let rows: Vec<Row> = [];
	if (kind == PlanKind.Rows) {
		rows = try vt.dirtyRows();
		if (rows.length == 0) { kind = PlanKind.Idle; }
		for (const row of rows) { painted.rows[row.y] = row; }
	} else {
		const all = try vt.rows();
		rows = kind == PlanKind.Scroll ? keptRowsChanged(all, painted.rows, moved) : all;
		painted.rows = all;
	}
	painted.alternate = alternate;
	if (kind != PlanKind.Idle) {
		const anchored = try vt.anchorTop();
	}
	vt.clean();
	return Result.ok({ kind: kind, scrolled: moved, rows: rows });
}

function newLines(from: int32, count: int32): string {
	let text = "";
	for (let i = 0; i < count; i++) { text += `\r\nrow ${from + i}`; }
	return text;
}

function opened(cols: int32): Result<Vt, VtError> {
	const vt = try Vt.create(cols, 24);
	vt.writeText("row 0" + newLines(1, 23));
	const first = try vt.plan();
	return Result.ok(vt);
}

function ys(rows: Vec<Row>): string {
	let out = "";
	for (let i = 0; i < (rows.length as int32); i++) {
		if (i > 0) { out += ","; }
		out += `${rows[i].y}`;
	}
	return out;
}

function textOf(row: Row): string {
	const text = row.text();
	if (text.ok) { return text.value.trimEnd(); }
	return "<unreadable>";
}

test "the first frame repaints every row, the next one is idle" {
	const created = Vt.create(10, 24);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("hello");
		const first = vt.plan();
		assert first.ok;
		if (first.ok) {
			assert first.value.kind == PlanKind.Repaint;
			assert first.value.rows.length == 24;
			assert textOf(first.value.rows[0]) == "hello";
		}
		const second = vt.plan();
		assert second.ok;
		if (second.ok) {
			assert second.value.kind == PlanKind.Idle;
			assert second.value.scrolled == 0;
			assert second.value.rows.length == 0;
		}
		vt.free();
	}
}

test "overwriting a row gives that row and the one the cursor left" {
	const opening = opened(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		vt.writeText("\x1b[6;1Hoverwrite");
		const p = vt.plan();
		assert p.ok;
		if (p.ok) {
			assert p.value.kind == PlanKind.Rows;
			assert p.value.scrolled == 0;
			assert ys(p.value.rows) == "5,23";
			assert textOf(p.value.rows[0]) == "overwrite";
		}
		vt.free();
	}
}

test "new lines at the bottom scroll by their count and give only the new rows" {
	const opening = opened(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		vt.writeText(newLines(24, 1));
		const one = vt.plan();
		assert one.ok;
		if (one.ok) {
			assert one.value.kind == PlanKind.Scroll;
			assert one.value.scrolled == 1;
			assert ys(one.value.rows) == "23";
			assert textOf(one.value.rows[0]) == "row 24";
		}
		vt.writeText(newLines(25, 3));
		const three = vt.plan();
		assert three.ok;
		if (three.ok) {
			assert three.value.kind == PlanKind.Scroll;
			assert three.value.scrolled == 3;
			assert ys(three.value.rows) == "21,22,23";
			assert textOf(three.value.rows[2]) == "row 27";
		}
		vt.writeText(newLines(28, 23));
		const most = vt.plan();
		assert most.ok;
		if (most.ok) {
			assert most.value.kind == PlanKind.Scroll;
			assert most.value.scrolled == 23;
			assert most.value.rows.length == 23;
			assert most.value.rows[0].y == 1;
			assert textOf(most.value.rows[22]) == "row 50";
		}
		const after = vt.plan();
		assert after.ok;
		if (after.ok) { assert after.value.kind == PlanKind.Idle; }
		vt.free();
	}
}

test "a screenful of new lines or more repaints" {
	const opening = opened(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		vt.writeText(newLines(24, 24));
		const exact = vt.plan();
		assert exact.ok;
		if (exact.ok) {
			assert exact.value.kind == PlanKind.Repaint;
			assert exact.value.rows.length == 24;
			assert textOf(exact.value.rows[23]) == "row 47";
		}
		vt.writeText(newLines(48, 30));
		const more = vt.plan();
		assert more.ok;
		if (more.ok) {
			assert more.value.kind == PlanKind.Repaint;
			assert textOf(more.value.rows[23]) == "row 77";
		}
		vt.writeText(newLines(78, 1));
		const next = vt.plan();
		assert next.ok;
		if (next.ok) {
			assert next.value.kind == PlanKind.Scroll;
			assert next.value.scrolled == 1;
		}
		vt.free();
	}
}

test "a row changed in the frame that scrolls is rewritten with the new rows" {
	const opening = opened(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		vt.writeText("\x1b[5;1HMOD\x1b[24;1H" + newLines(24, 2));
		const edited = vt.plan();
		assert edited.ok;
		if (edited.ok) {
			assert edited.value.kind == PlanKind.Scroll;
			assert edited.value.scrolled == 2;
			assert ys(edited.value.rows) == "2,22,23";
			assert textOf(edited.value.rows[0]) == "MOD 4";
		}
		vt.writeText("!!" + newLines(26, 1));
		const appended = vt.plan();
		assert appended.ok;
		if (appended.ok) {
			assert appended.value.kind == PlanKind.Scroll;
			assert ys(appended.value.rows) == "22,23";
			assert textOf(appended.value.rows[0]) == "row 25!!";
		}
		vt.free();
	}
}

test "a row an earlier frame painted is not rewritten when a later one scrolls" {
	const opening = opened(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		vt.writeText("\x1b[6;1Hxx\x1b[24;1H");
		const edited = vt.plan();
		assert edited.ok;
		if (edited.ok) { assert edited.value.kind == PlanKind.Rows; }
		vt.writeText(newLines(24, 1));
		const scrolled = vt.plan();
		assert scrolled.ok;
		if (scrolled.ok) {
			assert scrolled.value.kind == PlanKind.Scroll;
			assert ys(scrolled.value.rows) == "23";
		}
		vt.free();
	}
}

test "a clear rewrites every row without scrolling" {
	const opening = opened(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		vt.writeText("\x1b[2J\x1b[H");
		const p = vt.plan();
		assert p.ok;
		if (p.ok) {
			assert p.value.kind == PlanKind.Rows;
			assert p.value.scrolled == 0;
			assert p.value.rows.length == 24;
			assert textOf(p.value.rows[0]) == "";
		}
		vt.free();
	}
}

test "entering and leaving the alternate screen each repaint, then scrolling resumes" {
	const opening = opened(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		vt.writeText("\x1b[?1049h");
		const entered = vt.plan();
		assert entered.ok;
		if (entered.ok) {
			assert entered.value.kind == PlanKind.Repaint;
			assert entered.value.rows.length == 24;
		}
		vt.writeText("alt" + newLines(1, 30));
		const inside = vt.plan();
		assert inside.ok;
		if (inside.ok) { assert inside.value.kind == PlanKind.Rows; }
		vt.writeText("\x1b[?1049l");
		const left = vt.plan();
		assert left.ok;
		if (left.ok) {
			assert left.value.kind == PlanKind.Repaint;
			assert textOf(left.value.rows[0]) == "row 0";
		}
		vt.writeText(newLines(24, 1));
		const next = vt.plan();
		assert next.ok;
		if (next.ok) {
			assert next.value.kind == PlanKind.Scroll;
			assert next.value.scrolled == 1;
		}
		vt.free();
	}
}

test "a top row pruned from scrollback repaints and anchors again" {
	const opening = opened(80);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		vt.writeText(newLines(24, 5000));
		const lost = vt.anchoredRow();
		assert lost.ok;
		if (lost.ok) { assert lost.value === null; }
		const p = vt.plan();
		assert p.ok;
		if (p.ok) {
			assert p.value.kind == PlanKind.Repaint;
			assert textOf(p.value.rows[23]) == "row 5023";
		}
		vt.writeText(newLines(5024, 1));
		const next = vt.plan();
		assert next.ok;
		if (next.ok) {
			assert next.value.kind == PlanKind.Scroll;
			assert next.value.scrolled == 1;
		}
		vt.free();
	}
}

test "a resize repaints at the new size" {
	const opening = opened(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		const resized = vt.resize(10, 12);
		assert resized.ok;
		const p = vt.plan();
		assert p.ok;
		if (p.ok) {
			assert p.value.kind == PlanKind.Repaint;
			assert p.value.rows.length == 12;
		}
		vt.writeText(newLines(24, 1));
		const next = vt.plan();
		assert next.ok;
		if (next.ok) {
			assert next.value.kind == PlanKind.Scroll;
			assert next.value.scrolled == 1;
		}
		vt.free();
	}
}
