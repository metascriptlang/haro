import { Cell, CellFlag, Row, Rgb, Underline, Vt } from "../vt/vt";

export enum GridError {
	CodepointAboveBmp,
}

export struct LineRun {
	units: int32;
	fg: Rgb;
	bg: Rgb;
	underline: Underline;
	bold: boolean;
	italic: boolean;
	strikethrough: boolean;
}

export struct GridLine {
	text: string;
	runs: Vec<LineRun>;
	cursorCell: int32;
}

function sameStyle(this a: LineRun, b: LineRun): boolean {
	return a.fg == b.fg &&
		a.bg == b.bg &&
		a.underline == b.underline &&
		a.bold == b.bold &&
		a.italic == b.italic &&
		a.strikethrough == b.strikethrough;
}

function lineRun(this cell: Cell): LineRun {
	return {
		units: 0,
		fg: cell.fg,
		bg: cell.bg,
		underline: cell.underline,
		bold: cell.flags.has(CellFlag.Bold),
		italic: cell.flags.has(CellFlag.Italic),
		strikethrough: cell.flags.has(CellFlag.Strikethrough),
	};
}

function isWideSpacer(this row: Row, i: int32): boolean {
	return row.cells[i].cp == 0 && i > 0 && row.cells[i - 1].flags.has(CellFlag.Wide);
}

function pushUnit(ref runs: Vec<LineRun>, run: LineRun): void {
	const last = runs.length;
	if (last > 0 && runs[last - 1].sameStyle(run)) {
		runs[last - 1].units += 1;
		return;
	}
	runs.push({ ...run, units: 1 });
}

export function line(this row: Row, cursorCell: int32): Result<GridLine, GridError> {
	let text = "";
	let runs: Vec<LineRun> = [];
	let extra = 0;
	for (let i = 0; i < (row.cells.length as int32); i++) {
		const cell = row.cells[i];
		if (row.isWideSpacer(i)) {
			extra += cell.extra as int32;
			continue;
		}
		const run = cell.lineRun();
		if (cell.cp == 0) {
			text += " ";
			pushUnit(runs, run);
			continue;
		}
		let cps: Vec<uint32> = [cell.cp];
		for (let k = 0; k < (cell.extra as int32); k++) { cps.push(row.extra[extra + k]); }
		extra += cell.extra as int32;
		for (const cp of cps) {
			if (cp > 0xFFFF) { return Result.err(GridError.CodepointAboveBmp); }
			text += String.fromCharCode(cp as int32);
			pushUnit(runs, run);
		}
	}
	return Result.ok({ text: text, runs: runs, cursorCell: cursorCell });
}

test "a plain row is one run over its whole text" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("hello");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const line = rows.value[0].line(-1);
			assert line.ok;
			if (line.ok) {
				assert line.value.text == "hello     ";
				assert line.value.runs.length == 1;
				assert line.value.runs[0].units == 10;
				assert line.value.cursorCell == -1;
			}
		}
		vt.free();
	}
}

test "each styled stretch is its own run" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("\x1b[1;38;2;255;0;0mA\x1b[0mb");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const red: Rgb = { r: 255, g: 0, b: 0 };
			const line = rows.value[0].line(0);
			assert line.ok;
			if (line.ok) {
				assert line.value.text == "Ab        ";
				assert line.value.runs.length == 2;
				assert line.value.runs[0].units == 1;
				assert line.value.runs[0].bold;
				assert line.value.runs[0].fg == red;
				assert line.value.runs[1].units == 9;
				assert !line.value.runs[1].bold;
				assert line.value.cursorCell == 0;
			}
		}
		vt.free();
	}
}

test "underline kinds travel through, wavy as curly" {
	const created = Vt.create(20, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("\x1b[4:2md\x1b[4:3mw\x1b[4:5mv");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const line = rows.value[0].line(-1);
			assert line.ok;
			if (line.ok) {
				assert line.value.runs[0].underline == Underline.Double;
				assert line.value.runs[1].underline == Underline.Curly;
				assert line.value.runs[2].underline == Underline.Dashed;
			}
		}
		vt.free();
	}
}

test "a wide cell carries no spacer text and holds its run" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("中a");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const line = rows.value[0].line(2);
			assert line.ok;
			if (line.ok) {
				assert line.value.text == "中a       ";
				assert line.value.runs.length == 1;
				assert line.value.runs[0].units == 9;
				assert line.value.cursorCell == 2;
			}
		}
		vt.free();
	}
}

test "an erased line keeps its background as a run" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("\x1b[48;2;255;0;0m\x1b[K");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const red: Rgb = { r: 255, g: 0, b: 0 };
			const line = rows.value[0].line(-1);
			assert line.ok;
			if (line.ok) {
				assert line.value.text == "          ";
				assert line.value.runs.length == 1;
				assert line.value.runs[0].units == 10;
				assert line.value.runs[0].bg == red;
			}
		}
		vt.free();
	}
}

test "strikethrough is part of the run" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("\x1b[9mx\x1b[0my");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const line = rows.value[0].line(-1);
			assert line.ok;
			if (line.ok) {
				assert line.value.runs[0].strikethrough;
				assert !line.value.runs[1].strikethrough;
			}
		}
		vt.free();
	}
}
