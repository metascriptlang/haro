import { createList, List } from "../../../neon/src/core/list";
import { TextSpan } from "../../../neon/src/render/hostTypes";
import { Style } from "../../../neon/src/render/style";
import { RowSlot, applyFrame } from "../app/frame";
import { LineRun, line } from "../grid/lines";
import { Cursor, Rgb, Vt } from "../vt/vt";

export interface Screen {
	vt: Vt;
	grid: List<RowSlot>;
	styles: Map<string, Style>;
	cols: int32;
	rows: int32;
	cursor: Cursor | null;
}

export enum ScreenError {
	CreateFailed,
	FrameFailed,
}

function blankSlot(): RowSlot {
	return { line: { text: "", runs: [], cursorCell: -1 }, spans: [] };
}

export function open(this typeof Screen, cols: int32, rows: int32): Result<Screen, ScreenError> {
	const created = Vt.create(cols, rows);
	if (!created.ok) { return Result.err(ScreenError.CreateFailed); }
	let slots: RowSlot[] = [];
	for (let i = 0; i < rows; i++) { slots.push(blankSlot()); }
	return Result.ok({
		vt: created.value,
		grid: createList<RowSlot>(slots),
		styles: new Map<string, Style>(),
		cols: cols,
		rows: rows,
		cursor: null,
	});
}

export function paint(this s: Screen): boolean {
	const applied = applyFrame(s.grid, s.styles, s.vt);
	if (!applied.ok) { return false; }
	s.cursor = applied.value;
	return true;
}

export function feed(this s: Screen, bytes: string): boolean {
	s.vt.writeText(bytes);
	return s.paint();
}

export function feedChunks(this s: Screen, text: string, chunk: int32): boolean {
	const view = text.asBytes();
	const total = view.length as int32;
	let bytes: Vec<uint8> = new Array(total);
	for (let i = 0; i < total; i++) { bytes[i] = view[i]; }
	const size = chunk > 0 ? chunk : total;
	let at = 0;
	while (at < total) {
		const n = total - at < size ? total - at : size;
		s.vt.write(bytes[at..at + n]);
		if (!s.paint()) { return false; }
		at += n;
	}
	return true;
}

export function resize(this s: Screen, cols: int32, rows: int32): boolean {
	if (!s.vt.resize(cols, rows).ok) { return false; }
	s.cols = cols;
	s.rows = rows;
	const have = s.grid.length() as int32;
	for (let i = have; i < rows; i++) { s.grid.push(blankSlot()); }
	for (let i = have; i > rows; i--) { s.grid.remove(i - 1); }
	return s.paint();
}

export function close(this s: Screen): void {
	s.vt.free();
}

export function raw(this s: Screen, y: int32): string {
	return s.grid.at(y).line.text;
}

export function text(this s: Screen, y: int32): string {
	return s.grid.at(y).line.text.trimEnd();
}

export function runs(this s: Screen, y: int32): Vec<LineRun> {
	return s.grid.at(y).line.runs;
}

export function spans(this s: Screen, y: int32): TextSpan[] {
	return s.grid.at(y).spans;
}

export function cursorCell(this s: Screen, y: int32): int32 {
	return s.grid.at(y).line.cursorCell;
}

export function lines(this s: Screen): string {
	let out = "";
	for (let y = 0; y < s.rows; y++) {
		if (y > 0) { out += "\n"; }
		out += s.text(y);
	}
	return out;
}

export function sameAsFreshRead(this s: Screen): boolean {
	const fresh = s.vt.rows();
	if (!fresh.ok) { return false; }
	const all = fresh.value;
	if ((all.length as int32) != s.rows) { return false; }
	for (let y = 0; y < s.rows; y++) {
		const l = all[y].line(-1);
		if (!l.ok || l.value.text != s.raw(y)) { return false; }
	}
	return true;
}

export function rgb(r: int32, g: int32, b: int32): Rgb {
	return { r: r as uint8, g: g as uint8, b: b as uint8 };
}
