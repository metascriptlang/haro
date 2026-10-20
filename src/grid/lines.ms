import { fromCodePoint } from "std/core/string";
import { Cell, CellFlag, Row, Rgb, Underline, Vt } from "../vt/vt";

export enum GridError {
	CodepointInvalid,
}

export struct LineRun {
	units: int32;
	fg: Rgb;
	bg: Rgb;
	underline: Underline;
	underlineColor: Rgb | null;
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
		a.underlineColor == b.underlineColor &&
		a.bold == b.bold &&
		a.italic == b.italic &&
		a.strikethrough == b.strikethrough;
}

const FAINT_OPACITY = 0.5;

function over(fg: uint8, bg: uint8): uint8 {
	return Math.round(fg * FAINT_OPACITY + bg * (1 - FAINT_OPACITY)) as uint8;
}

function faded(fg: Rgb, bg: Rgb): Rgb {
	return { r: over(fg.r, bg.r), g: over(fg.g, bg.g), b: over(fg.b, bg.b) };
}

function lineRun(this cell: Cell): LineRun {
	const inverse = cell.flags.has(CellFlag.Inverse);
	const fg = inverse ? cell.bg : cell.fg;
	const bg = inverse ? cell.fg : cell.bg;
	return {
		units: 0,
		fg: cell.flags.has(CellFlag.Faint) ? faded(fg, bg) : fg,
		bg: bg,
		underline: cell.underline,
		underlineColor: cell.underlineColor,
		bold: cell.flags.has(CellFlag.Bold),
		italic: cell.flags.has(CellFlag.Italic),
		strikethrough: cell.flags.has(CellFlag.Strikethrough),
	};
}

function isWideSpacer(this row: Row, i: int32): boolean {
	return row.cells[i].cp == 0 && i > 0 && row.cells[i - 1].flags.has(CellFlag.Wide);
}

function pushUnits(ref runs: Vec<LineRun>, run: LineRun, units: int32, split: boolean): void {
	const last = runs.length;
	if (!split && last > 0 && runs[last - 1].sameStyle(run)) {
		runs[last - 1].units += units;
		return;
	}
	runs.push({ ...run, units: units });
}

function ligatesBadly(a: uint32, b: uint32): boolean {
	return (a == 0x66 && (b == 0x69 || b == 0x6C)) || (a == 0x73 && b == 0x74);
}

function breaksShapingBefore(this row: Row, i: int32, cursorCell: int32): boolean {
	if (i == 0) { return false; }
	const cell = row.cells[i];
	const prev = row.cells[i - 1];
	if (cell.extra == 0 && (i == cursorCell || i == cursorCell + 1)) { return true; }
	return cell.extra == 0 && prev.extra == 0 && ligatesBadly(prev.cp, cell.cp);
}

function isScalar(cp: uint32): boolean {
	return cp <= 0x10FFFF && (cp < 0xD800 || cp > 0xDFFF);
}

function isEmpty(this cell: Cell, background: Rgb): boolean {
	const run = cell.lineRun();
	return (cell.cp == 0 || cell.cp == 0x20) && cell.extra == 0 && run.bg == background &&
		run.underline == Underline.None && !run.strikethrough;
}

export function line(
	this row: Row,
	cursorCell: int32,
	background: Rgb,
): Result<GridLine, GridError> {
	let text = "";
	let runs: Vec<LineRun> = [];
	let extra = 0;
	let end = row.cells.length as int32;
	while (end > 0 && row.cells[end - 1].isEmpty(background)) { end--; }
	for (let i = 0; i < end; i++) {
		const cell = row.cells[i];
		if (row.isWideSpacer(i)) {
			extra += cell.extra as int32;
			continue;
		}
		const run = cell.lineRun();
		const split = row.breaksShapingBefore(i, cursorCell);
		if (cell.cp == 0) {
			text += " ";
			pushUnits(runs, run, 1, split);
			continue;
		}
		if (cell.flags.has(CellFlag.Invisible)) {
			const blank = cell.flags.has(CellFlag.Wide) ? "  " : " ";
			text += blank;
			const hidden: LineRun = { ...run, underline: Underline.None, strikethrough: false };
			pushUnits(runs, hidden, blank.length as int32, split);
			extra += cell.extra as int32;
			continue;
		}
		let cps: Vec<uint32> = [cell.cp];
		for (let k = 0; k < (cell.extra as int32); k++) { cps.push(row.extra[extra + k]); }
		extra += cell.extra as int32;
		for (let k = 0; k < (cps.length as int32); k++) {
			if (!isScalar(cps[k])) { return Result.err(GridError.CodepointInvalid); }
			const unit = fromCodePoint(cps[k] as number);
			text += unit;
			pushUnits(runs, run, unit.length as int32, split && k == 0);
		}
	}
	return Result.ok({ text: text, runs: runs, cursorCell: cursorCell });
}

test "a plain row is one run over its text, without the blank cells after it" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("hello");
		assert vt.update().ok;
		const colors = vt.palette();
		const rows = vt.rows();
		assert colors.ok && rows.ok;
		if (colors.ok && rows.ok) {
			const line = rows.value[0].line(-1, colors.value.bg);
			assert line.ok;
			if (line.ok) {
				assert line.value.text == "hello";
				assert line.value.runs.length == 1;
				assert line.value.runs[0].units == 5;
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
		const colors = vt.palette();
		const rows = vt.rows();
		assert colors.ok && rows.ok;
		if (colors.ok && rows.ok) {
			const red: Rgb = { r: 255, g: 0, b: 0 };
			const line = rows.value[0].line(0, colors.value.bg);
			assert line.ok;
			if (line.ok) {
				assert line.value.text == "Ab";
				assert line.value.runs.length == 2;
				assert line.value.runs[0].units == 1;
				assert line.value.runs[0].bold;
				assert line.value.runs[0].fg == red;
				assert line.value.runs[1].units == 1;
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
		const colors = vt.palette();
		const rows = vt.rows();
		assert colors.ok && rows.ok;
		if (colors.ok && rows.ok) {
			const line = rows.value[0].line(-1, colors.value.bg);
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
		const colors = vt.palette();
		const rows = vt.rows();
		assert colors.ok && rows.ok;
		if (colors.ok && rows.ok) {
			const line = rows.value[0].line(-1, colors.value.bg);
			assert line.ok;
			if (line.ok) {
				assert line.value.text == "中a";
				assert line.value.runs.length == 1;
				assert line.value.runs[0].units == 2;
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
		const colors = vt.palette();
		const rows = vt.rows();
		assert colors.ok && rows.ok;
		if (colors.ok && rows.ok) {
			const red: Rgb = { r: 255, g: 0, b: 0 };
			const line = rows.value[0].line(-1, colors.value.bg);
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
		const colors = vt.palette();
		const rows = vt.rows();
		assert colors.ok && rows.ok;
		if (colors.ok && rows.ok) {
			const line = rows.value[0].line(-1, colors.value.bg);
			assert line.ok;
			if (line.ok) {
				assert line.value.runs[0].strikethrough;
				assert !line.value.runs[1].strikethrough;
			}
		}
		vt.free();
	}
}

test "a concealed cell keeps its background and draws no text or line" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("\x1b[8;4;9;41mab\x1b[0mc\x1b[8m\u4e2d");
		assert vt.update().ok;
		const colors = vt.palette();
		const rows = vt.rows();
		assert colors.ok && rows.ok;
		if (colors.ok && rows.ok) {
			const line = rows.value[0].line(-1, colors.value.bg);
			assert line.ok;
			if (line.ok) {
				assert line.value.text == "  c  ";
				const hidden = line.value.runs[0];
				assert hidden.units == 2;
				assert hidden.underline == Underline.None;
				assert !hidden.strikethrough;
				assert hidden.bg != line.value.runs[1].bg;
			}
		}
		vt.free();
	}
}

test "a codepoint above the BMP is two UTF-16 units of its run" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("a😀\x1b[1mb");
		assert vt.update().ok;
		const colors = vt.palette();
		const rows = vt.rows();
		assert colors.ok && rows.ok;
		if (colors.ok && rows.ok) {
			const line = rows.value[0].line(-1, colors.value.bg);
			assert line.ok;
			if (line.ok) {
				assert line.value.text == "a😀b";
				assert line.value.runs.length == 2;
				assert line.value.runs[0].units == 3;
				assert line.value.text.slice(0, 3) == "a😀";
				assert line.value.runs[1].bold;
			}
		}
		vt.free();
	}
}

test "an inverse cell swaps its run's colours" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("\x1b[7mx\x1b[0my");
		assert vt.update().ok;
		const colors = vt.palette();
		const rows = vt.rows();
		assert colors.ok && rows.ok;
		if (colors.ok && rows.ok) {
			const line = rows.value[0].line(-1, colors.value.bg);
			assert line.ok;
			if (line.ok) {
				assert line.value.runs[0].fg == colors.value.bg;
				assert line.value.runs[0].bg == colors.value.fg;
				assert line.value.runs[1].fg == colors.value.fg;
			}
		}
		vt.free();
	}
}

test "a faint cell draws its foreground halfway to its background" {
	const created = Vt.create(10, 2);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("\x1b[2;38;2;200;100;0;48;2;0;0;100mx");
		assert vt.update().ok;
		const colors = vt.palette();
		const rows = vt.rows();
		assert colors.ok && rows.ok;
		if (colors.ok && rows.ok) {
			const line = rows.value[0].line(-1, colors.value.bg);
			assert line.ok;
			if (line.ok) {
				const fg = line.value.runs[0].fg;
				assert fg.r == 100 && fg.g == 50 && fg.b == 50;
				assert line.value.runs[0].bg.b == 100;
			}
		}
		vt.free();
	}
}

test "a trailing blank that shows a background, an underline or a strikethrough stays" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText("a   \r\nb\x1b[41m \x1b[0m\r\nc\x1b[4m \x1b[0m\r\nd\x1b[9m \x1b[0m");
		assert vt.update().ok;
		const colors = vt.palette();
		const rows = vt.rows();
		assert colors.ok && rows.ok;
		if (colors.ok && rows.ok) {
			let texts: Vec<string> = [];
			for (const row of rows.value) {
				const line = row.line(-1, colors.value.bg);
				assert line.ok;
				if (line.ok) { texts.push(line.value.text); }
			}
			assert texts.join("|") == "a|b |c |d ";
		}
		vt.free();
	}
}

function unitsOf(text: string, cursorCell: int32): string {
	const created = Vt.create(12, 2);
	if (!created.ok) { return "create failed"; }
	const vt = created.value;
	vt.writeText(text);
	const updated = vt.update();
	const colors = vt.palette();
	const rows = vt.rows();
	let out: string[] = [];
	if (updated.ok && colors.ok && rows.ok) {
		const line = rows.value[0].line(cursorCell, colors.value.bg);
		if (line.ok) {
			for (const run of line.value.runs) { out.push(`${run.units}`); }
		}
	}
	vt.free();
	return out.join(",");
}

test "the cursor's cell is a run of its own, so a ligature under it shows its parts" {
	assert unitsOf("a->b", -1) == "4";
	assert unitsOf("a->b", 2) == "2,1,1";
	assert unitsOf("a->b", 0) == "1,3";
}

test "fi, fl and st never share a run, so they stay unligated" {
	assert unitsOf("fifl", -1) == "1,2,1";
	assert unitsOf("ast", -1) == "2,1";
	assert unitsOf("ft", -1) == "2";
}
