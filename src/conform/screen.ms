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

export function feedBytes(this s: Screen, values: int32[]): boolean {
	let bytes: Vec<uint8> = new Array(values.length);
	for (let i = 0; i < values.length; i++) { bytes[i] = values[i] as uint8; }
	s.vt.write(bytes);
	return s.paint();
}

export function step(this s: Screen, bytes: string): boolean {
	return s.feed(bytes) && s.sameAsFreshRead();
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

export function history(this s: Screen): Vec<string> | null {
	let out: Vec<string> = [];
	s.vt.scrollTop();
	if (!s.paint()) { return null; }
	while (true) {
		const offset = s.vt.scrollOffset();
		if (!offset.ok) { return null; }
		for (let y = 0; y < s.rows; y++) {
			while ((out.length as int32) <= offset.value + y) { out.push(""); }
			out[offset.value + y] = s.text(y);
		}
		const bottom = s.vt.atBottom();
		if (!bottom.ok) { return null; }
		if (bottom.value) { break; }
		s.vt.scrollLines(s.rows);
		if (!s.paint()) { return null; }
		const next = s.vt.scrollOffset();
		if (!next.ok || next.value <= offset.value) { return null; }
	}
	s.vt.scrollBottom();
	if (!s.paint()) { return null; }
	return out;
}

export function joined(lines: Vec<string>): string {
	let out = "";
	for (let i = 0; i < (lines.length as int32); i++) {
		if (i > 0) { out += "\n"; }
		out += lines[i];
	}
	return out;
}

function runText(r: LineRun): string {
	return `${r.units}:${r.fg.r},${r.fg.g},${r.fg.b}/${r.bg.r},${r.bg.g},${r.bg.b}/u${r.underline as int32}${r.bold ? "B" : ""}${r.italic ? "I" : ""}${r.strikethrough ? "S" : ""}`;
}

function runsText(runs: Vec<LineRun>): string {
	let out = "";
	for (const r of runs) { out += runText(r) + " "; }
	return out;
}

export function mismatch(this s: Screen): string {
	const fresh = s.vt.rows();
	if (!fresh.ok) { return "the fresh read failed"; }
	const all = fresh.value;
	if ((all.length as int32) != s.rows) { return `the vt has ${all.length} rows, the screen ${s.rows}`; }
	for (let y = 0; y < s.rows; y++) {
		const l = all[y].line(-1);
		if (!l.ok) { return `row ${y}: no line`; }
		if (l.value.text != s.raw(y)) { return `row ${y}: text [${s.raw(y)}] but the vt has [${l.value.text}]`; }
		const have = runsText(s.runs(y));
		const want = runsText(l.value.runs);
		if (have != want) { return `row ${y}: runs ${have} but the vt has ${want}`; }
		const spans = s.spans(y);
		let spanned = "";
		for (const sp of spans) { spanned += sp.text; }
		if (spanned != s.raw(y) || (spans.length as int32) != (s.runs(y).length as int32)) {
			return `row ${y}: spans do not cover the line`;
		}
	}
	const at = s.vt.cursor();
	if (!at.ok) { return "the cursor read failed"; }
	const c = at.value;
	const shown = s.cursor;
	if ((c === null) != (shown === null)) { return "the cursor's presence differs"; }
	if (c !== null && shown !== null && (c.x != shown.x || c.y != shown.y)) {
		return `cursor ${shown.x},${shown.y} but the vt has ${c.x},${c.y}`;
	}
	return "";
}

export function sameAsFreshRead(this s: Screen): boolean {
	return s.mismatch() == "";
}

export function rgb(r: int32, g: int32, b: int32): Rgb {
	return { r: r as uint8, g: g as uint8, b: b as uint8 };
}
