import { Marked } from "../select/select";
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

function newLines(from: int32, count: int32): string {
	let text = "";
	for (let i = 0; i < count; i++) { text += `\r\nrow ${from + i}`; }
	return text;
}

function filledScreen(cols: int32): Result<Vt, VtError> {
	const vt = try Vt.create(cols, 24);
	vt.writeText("row 0" + newLines(1, 23));
	try vt.plan();
	return Result.ok(vt);
}

function rowNumbers(ys: Readonly<Span<int32>>): string {
	let out: string[] = [];
	for (const y of ys) { out.push(`${y}`); }
	return out.join(",");
}

function textOf(this row: Row): string {
	const text = row.text();
	if (text.ok) { return text.value.trimEnd(); }
	return "<unreadable>";
}

test "the first frame repaints every row, the next one is idle" {
	const created = Vt.create(10, 24);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		defer vt.free();
		vt.writeText("hello");
		const first = vt.plan();
		assert first.ok;
		if (first.ok) {
			assert first.value.kind == PlanKind.Repaint;
			assert first.value.ys.length == 24;
			assert vt.painted.rows[first.value.ys[0]].textOf() == "hello";
		}
		const second = vt.plan();
		assert second.ok;
		if (second.ok) {
			assert second.value.kind == PlanKind.Idle;
			assert second.value.scrolled == 0;
			assert second.value.ys.length == 0;
		}
	}
}

test "overwriting a row gives that row, not the unchanged one the cursor left" {
	const opening = filledScreen(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		defer vt.free();
		vt.writeText("\x1b[6;1Hoverwrite");
		const p = vt.plan();
		assert p.ok;
		if (p.ok) {
			assert p.value.kind == PlanKind.Rows;
			assert p.value.scrolled == 0;
			assert rowNumbers(p.value.ys) == "5";
			assert vt.painted.rows[p.value.ys[0]].textOf() == "overwrite";
		}
	}
}

test "new lines at the bottom scroll by their count and give only the new rows" {
	const opening = filledScreen(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		defer vt.free();
		vt.writeText(newLines(24, 1));
		const one = vt.plan();
		assert one.ok;
		if (one.ok) {
			assert one.value.kind == PlanKind.Scroll;
			assert one.value.scrolled == 1;
			assert rowNumbers(one.value.ys) == "23";
			assert vt.painted.rows[one.value.ys[0]].textOf() == "row 24";
		}
		vt.writeText(newLines(25, 3));
		const three = vt.plan();
		assert three.ok;
		if (three.ok) {
			assert three.value.kind == PlanKind.Scroll;
			assert three.value.scrolled == 3;
			assert rowNumbers(three.value.ys) == "21,22,23";
			assert vt.painted.rows[three.value.ys[2]].textOf() == "row 27";
		}
		vt.writeText(newLines(28, 23));
		const most = vt.plan();
		assert most.ok;
		if (most.ok) {
			assert most.value.kind == PlanKind.Scroll;
			assert most.value.scrolled == 23;
			assert most.value.ys.length == 23;
			assert most.value.ys[0] == 1;
			assert vt.painted.rows[most.value.ys[22]].textOf() == "row 50";
		}
		const after = vt.plan();
		assert after.ok;
		if (after.ok) { assert after.value.kind == PlanKind.Idle; }
	}
}

test "a screenful of new lines or more repaints" {
	const opening = filledScreen(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		defer vt.free();
		vt.writeText(newLines(24, 24));
		const exact = vt.plan();
		assert exact.ok;
		if (exact.ok) {
			assert exact.value.kind == PlanKind.Repaint;
			assert exact.value.ys.length == 24;
			assert vt.painted.rows[exact.value.ys[23]].textOf() == "row 47";
		}
		vt.writeText(newLines(48, 30));
		const more = vt.plan();
		assert more.ok;
		if (more.ok) {
			assert more.value.kind == PlanKind.Repaint;
			assert vt.painted.rows[more.value.ys[23]].textOf() == "row 77";
		}
		vt.writeText(newLines(78, 1));
		const next = vt.plan();
		assert next.ok;
		if (next.ok) {
			assert next.value.kind == PlanKind.Scroll;
			assert next.value.scrolled == 1;
		}
	}
}

test "a row changed in the frame that scrolls is rewritten with the new rows" {
	const opening = filledScreen(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		defer vt.free();
		vt.writeText("\x1b[5;1HMOD\x1b[24;1H" + newLines(24, 2));
		const edited = vt.plan();
		assert edited.ok;
		if (edited.ok) {
			assert edited.value.kind == PlanKind.Scroll;
			assert edited.value.scrolled == 2;
			assert rowNumbers(edited.value.ys) == "2,22,23";
			assert vt.painted.rows[edited.value.ys[0]].textOf() == "MOD 4";
		}
		vt.writeText("!!" + newLines(26, 1));
		const appended = vt.plan();
		assert appended.ok;
		if (appended.ok) {
			assert appended.value.kind == PlanKind.Scroll;
			assert rowNumbers(appended.value.ys) == "22,23";
			assert vt.painted.rows[appended.value.ys[0]].textOf() == "row 25!!";
		}
	}
}

test "a row an earlier frame painted is not rewritten when a later one scrolls" {
	const opening = filledScreen(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		defer vt.free();
		vt.writeText("\x1b[6;1Hxx\x1b[24;1H");
		const edited = vt.plan();
		assert edited.ok;
		if (edited.ok) { assert edited.value.kind == PlanKind.Rows; }
		vt.writeText(newLines(24, 1));
		const scrolled = vt.plan();
		assert scrolled.ok;
		if (scrolled.ok) {
			assert scrolled.value.kind == PlanKind.Scroll;
			assert rowNumbers(scrolled.value.ys) == "23";
		}
	}
}

test "a clear rewrites every row without scrolling" {
	const opening = filledScreen(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		defer vt.free();
		vt.writeText("\x1b[2J\x1b[H");
		const p = vt.plan();
		assert p.ok;
		if (p.ok) {
			assert p.value.kind == PlanKind.Rows;
			assert p.value.scrolled == 0;
			assert p.value.ys.length == 24;
			assert vt.painted.rows[p.value.ys[0]].textOf() == "";
		}
	}
}

test "entering and leaving the alternate screen each repaint, then scrolling resumes" {
	const opening = filledScreen(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		defer vt.free();
		vt.writeText("\x1b[?1049h");
		const entered = vt.plan();
		assert entered.ok;
		if (entered.ok) {
			assert entered.value.kind == PlanKind.Repaint;
			assert entered.value.ys.length == 24;
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
			assert vt.painted.rows[left.value.ys[0]].textOf() == "row 0";
		}
		vt.writeText(newLines(24, 1));
		const next = vt.plan();
		assert next.ok;
		if (next.ok) {
			assert next.value.kind == PlanKind.Scroll;
			assert next.value.scrolled == 1;
		}
	}
}

test "a top row pruned from scrollback repaints and anchors again" {
	const opening = filledScreen(80);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		defer vt.free();
		assert vt.setScrollback(1000).ok;
		vt.writeText(newLines(24, 5000));
		const lost = vt.anchoredRow();
		assert lost.ok;
		if (lost.ok) { assert lost.value === null; }
		const p = vt.plan();
		assert p.ok;
		if (p.ok) {
			assert p.value.kind == PlanKind.Repaint;
			assert vt.painted.rows[p.value.ys[23]].textOf() == "row 5023";
		}
		vt.writeText(newLines(5024, 1));
		const next = vt.plan();
		assert next.ok;
		if (next.ok) {
			assert next.value.kind == PlanKind.Scroll;
			assert next.value.scrolled == 1;
		}
	}
}

test "a resize repaints at the new size" {
	const opening = filledScreen(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		defer vt.free();
		const resized = vt.resize(10, 12);
		assert resized.ok;
		const p = vt.plan();
		assert p.ok;
		if (p.ok) {
			assert p.value.kind == PlanKind.Repaint;
			assert p.value.ys.length == 12;
		}
		vt.writeText(newLines(24, 1));
		const next = vt.plan();
		assert next.ok;
		if (next.ok) {
			assert next.value.kind == PlanKind.Scroll;
			assert next.value.scrolled == 1;
		}
	}
}

test "scrolling the viewport down plans a scroll by that many rows and up repaints" {
	const opening = filledScreen(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		defer vt.free();
		vt.writeText(newLines(24, 76));
		const bottom = vt.plan();
		assert bottom.ok;
		vt.scrollLines(-3);
		const up = vt.plan();
		assert up.ok;
		if (up.ok) {
			assert up.value.kind == PlanKind.Repaint;
			assert up.value.ys.length == 24;
			assert vt.painted.rows[up.value.ys[0]].textOf() == "row 73";
		}
		const idle = vt.plan();
		assert idle.ok;
		if (idle.ok) { assert idle.value.kind == PlanKind.Idle; }
		vt.scrollLines(2);
		const down = vt.plan();
		assert down.ok;
		if (down.ok) {
			assert down.value.kind == PlanKind.Scroll;
			assert down.value.scrolled == 2;
			assert rowNumbers(down.value.ys) == "22,23";
			assert vt.painted.rows[down.value.ys[1]].textOf() == "row 98";
		}
	}
}

test "output while scrolled up plans nothing, and snapping back to the bottom plans the new rows" {
	const opening = filledScreen(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		defer vt.free();
		vt.writeText(newLines(24, 76));
		const bottom = vt.plan();
		assert bottom.ok;
		vt.scrollLines(-3);
		const up = vt.plan();
		assert up.ok;
		vt.writeText(newLines(100, 5));
		const held = vt.plan();
		assert held.ok;
		if (held.ok) { assert held.value.kind == PlanKind.Idle; }
		vt.scrollBottom();
		const snapped = vt.plan();
		assert snapped.ok;
		if (snapped.ok) {
			assert snapped.value.kind == PlanKind.Scroll;
			assert snapped.value.scrolled == 8;
			assert vt.painted.rows[snapped.value.ys[7]].textOf() == "row 104";
		}
	}
}

function kindAfter(this vt: Vt, bytes: string): PlanKind | null {
	vt.writeText(bytes);
	const planned = vt.plan();
	if (!planned.ok) { return null; }
	return planned.value.kind;
}

test "a new default colour or reverse video repaints every row once" {
	const created = Vt.create(10, 6);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		defer vt.free();
		assert vt.kindAfter("hello") == PlanKind.Repaint;
		assert vt.kindAfter("") == PlanKind.Idle;
		assert vt.kindAfter("\x1b]11;rgb:10/10/10\x07") == PlanKind.Repaint;
		assert vt.kindAfter("") == PlanKind.Idle;
		assert vt.kindAfter("\x1b]10;rgb:ff/00/00\x07") == PlanKind.Repaint;
		assert vt.kindAfter("\x1b[?5h") == PlanKind.Repaint;
		assert vt.kindAfter("\x1b[?5l") == PlanKind.Repaint;
		assert vt.kindAfter("x") == PlanKind.Rows;
	}
}

function marked(fromRow: int32, fromCol: int32, toRow: int32, toCol: int32): Marked {
	return {
		range: { start: { row: fromRow, col: fromCol }, end: { row: toRow, col: toCol } },
		block: false,
	};
}

function selectedOf(this row: Row): string {
	const s = row.selected;
	return s === null ? "none" : `${s.from}-${s.to}`;
}

test "a selection change plans only the rows it enters, leaves or reshapes" {
	const opening = filledScreen(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		defer vt.free();
		assert vt.selectionSet(marked(3, 2, 4, 5)).ok;
		const set = vt.plan();
		assert set.ok;
		if (set.ok) { assert rowNumbers(set.value.ys) == "3,4"; }
		assert vt.painted.rows[3].selectedOf() == "2-9";
		assert vt.painted.rows[4].selectedOf() == "0-5";
		assert vt.selectionSet(marked(3, 2, 5, 1)).ok;
		const grown = vt.plan();
		assert grown.ok;
		if (grown.ok) { assert rowNumbers(grown.value.ys) == "4,5"; }
		vt.selectionClear();
		const cleared = vt.plan();
		assert cleared.ok;
		if (cleared.ok) { assert rowNumbers(cleared.value.ys) == "3,4,5"; }
		assert vt.painted.rows[4].selectedOf() == "none";
	}
}

test "a selection stays on its text as the viewport scrolls back" {
	const opening = filledScreen(10);
	assert opening.ok;
	if (opening.ok) {
		const vt = opening.value;
		defer vt.free();
		vt.writeText(newLines(24, 76));
		assert vt.selectionSet(marked(90, 0, 90, 3)).ok;
		const bottom = vt.plan();
		assert bottom.ok;
		assert vt.painted.rows[14].textOf() == "row 90";
		assert vt.painted.rows[14].selectedOf() == "0-3";
		vt.scrollLines(-3);
		const up = vt.plan();
		assert up.ok;
		assert vt.painted.rows[14].selectedOf() == "none";
		assert vt.painted.rows[17].selectedOf() == "0-3";
	}
}
