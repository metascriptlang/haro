import { CellInk, GridLine, RowNote, RowTint, cellOnRow, line } from "../grid/lines";
import { PlanKind, plan } from "../screen/plan";
import {
	Cursor,
	Rgb,
	Row,
	Vt,
	VtError,
	alternateScreen,
	anchorRow,
	scrollOffset,
} from "../vt/vt";

export const SELECTION: CellInk = { fg: null, bg: null };

export enum FrameError {
	PlanFailed,
	CursorFailed,
	LineFailed,
	TintFailed,
}

function inkOn(this ink: CellInk | null, cell: int32): CellInk | null {
	return cell >= 0 ? ink : null;
}

export struct Shown {
	cell: int32;
	ink: CellInk | null;
	tint: RowTint | null;
	note: RowNote | null;
}

export struct Decoration {
	id: int32;
	from: int32;
	to: int32;
	tint: RowTint;
}

export struct Annotation {
	id: int32;
	at: int32;
	note: RowNote;
}

export const DECORATION_CAP = 256;

export interface Decor {
	decorations: Vec<Decoration>;
	annotations: Vec<Annotation>;
	tints: Vec<RowTint | null>;
	notes: Vec<RowNote | null>;
	stale: boolean;
}

export function empty(this typeof Decor): Decor {
	return { decorations: [], annotations: [], tints: [], notes: [], stale: false };
}

export function decorate(this d: Decor, decoration: Decoration): void {
	if (d.decorations.length >= DECORATION_CAP) { d.decorations.shift(); }
	d.decorations.push(decoration);
	d.stale = true;
}

export function undecorate(this d: Decor, id: int32): void {
	let kept: Vec<Decoration> = [];
	for (const x of d.decorations) {
		if (x.id != id) { kept.push(x); }
	}
	d.decorations = kept;
	d.stale = true;
}

export function annotate(this d: Decor, annotation: Annotation): void {
	if (d.annotations.length >= DECORATION_CAP) { d.annotations.shift(); }
	d.annotations.push(annotation);
	d.stale = true;
}

export function unannotate(this d: Decor, id: int32): void {
	let kept: Vec<Annotation> = [];
	for (const x of d.annotations) {
		if (x.id != id) { kept.push(x); }
	}
	d.annotations = kept;
	d.stale = true;
}

function tintAt(this d: Decor, y: int32): RowTint | null {
	return y < (d.tints.length as int32) ? d.tints[y] : null;
}

function noteAt(this d: Decor, y: int32): RowNote | null {
	return y < (d.notes.length as int32) ? d.notes[y] : null;
}

function over(under: RowTint | null, tint: RowTint): RowTint {
	if (under === null) { return tint; }
	return { fg: tint.fg ?? under.fg, bg: tint.bg ?? under.bg };
}

function retint(this d: Decor, vt: Vt, rows: int32): Result<void, VtError> {
	d.stale = false;
	d.tints = [];
	d.notes = [];
	if (d.decorations.length == 0 && d.annotations.length == 0) { return Result.ok(null); }
	if (try vt.alternateScreen()) { return Result.ok(null); }
	const offset = try vt.scrollOffset();
	let live: Vec<Decoration> = [];
	for (let i = 0; i < rows; i++) {
		d.tints.push(null);
		d.notes.push(null);
	}
	for (const decoration of d.decorations) {
		const from = try vt.anchorRow(decoration.from);
		const to = try vt.anchorRow(decoration.to);
		if (from === null || to === null) { continue; }
		live.push(decoration);
		for (let y = Math.max(from - offset, 0); y < Math.min(to - offset, rows); y++) {
			d.tints[y] = over(d.tints[y], decoration.tint);
		}
	}
	d.decorations = live;
	let noted: Vec<Annotation> = [];
	for (const annotation of d.annotations) {
		const at = try vt.anchorRow(annotation.at);
		if (at === null) { continue; }
		noted.push(annotation);
		const y = at - offset;
		if (y >= 0 && y < rows) { d.notes[y] = annotation.note; }
	}
	d.annotations = noted;
	return Result.ok(null);
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

export function fitShown(this ref shown: Vec<Shown>, rows: int32): void {
	while ((shown.length as int32) < rows) {
		shown.push({ cell: -1, ink: null, tint: null, note: null });
	}
	while ((shown.length as int32) > rows) { shown.pop(); }
}

function rowOf(
	ref shown: Vec<Shown>,
	row: Row,
	cursor: Cursor | null,
	ink: CellInk | null,
	background: Rgb,
	decor: Decor,
): Result<RowUpdate, FrameError> {
	const cell = cursor.cellOnRow(row.y);
	const tint = decor.tintAt(row.y);
	const note = decor.noteAt(row.y);
	const built = row.line(cell, ink.inkOn(cell), SELECTION, background, tint, note);
	if (!built.ok) { return Result.err(FrameError.LineFailed); }
	shown[row.y] = { cell: cell, ink: ink.inkOn(cell), tint: tint, note: note };
	return Result.ok({ y: row.y, line: move built.value });
}

function relight(
	ref out: Vec<RowUpdate>,
	ref shown: Vec<Shown>,
	vt: Vt,
	cursor: Cursor | null,
	ink: CellInk | null,
	background: Rgb,
	decor: Decor,
): Result<void, FrameError> {
	for (let i = 0; i < vt.painted.rows.length; i++) {
		const y = vt.painted.rows[i].y;
		const cell = cursor.cellOnRow(y);
		const was = shown[y];
		const same = was.cell == cell && was.ink == ink.inkOn(cell) &&
			was.tint == decor.tintAt(y) && was.note == decor.noteAt(y);
		if (!same) {
			const built = try rowOf(shown, vt.painted.rows[i], cursor, ink, background, decor);
			out.push(move built);
		}
	}
	return Result.ok(null);
}

export function relitRows(
	this ref shown: Vec<Shown>,
	vt: Vt,
	ink: CellInk | null,
	decor: Decor,
): Result<FrameRows, FrameError> {
	const colors = vt.painted.palette;
	if (colors === null || shown.length != vt.painted.rows.length) { return Result.ok(FrameRows.none()); }
	const at = vt.cursor();
	if (!at.ok) { return Result.err(FrameError.CursorFailed); }
	let rows: Vec<RowUpdate> = [];
	try relight(rows, shown, vt, at.value, ink, colors.bg, decor);
	return Result.ok({ scrolled: 0, rows: rows, background: colors.bg });
}

export struct Planned {
	cursor: Cursor | null;
	rows: FrameRows;
}

export function planRows(
	this ref shown: Vec<Shown>,
	vt: Vt,
	ink: CellInk | null,
	decor: Decor,
): Result<Planned, FrameError> {
	const planned = vt.plan();
	if (!planned.ok) { return Result.err(FrameError.PlanFailed); }
	const moved = planned.value.kind != PlanKind.Idle;
	if ((moved || decor.stale) && !decor.retint(vt, shown.length as int32).ok) {
		return Result.err(FrameError.TintFailed);
	}
	const at = vt.cursor();
	if (!at.ok) { return Result.err(FrameError.CursorFailed); }
	const cursor = at.value;
	const p = planned.value;
	for (let i = 0; i < p.scrolled; i++) { shown.push(shown.shift()); }
	let rows: Vec<RowUpdate> = [];
	for (const y of p.ys) {
		const built = try rowOf(shown, vt.painted.rows[y], cursor, ink, p.colors.bg, decor);
		rows.push(move built);
	}
	try relight(rows, shown, vt, cursor, ink, p.colors.bg, decor);
	return Result.ok({ cursor: cursor, rows: { scrolled: p.scrolled, rows: rows, background: p.colors.bg } });
}
