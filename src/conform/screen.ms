import { createList, List } from "../../../neon/src/core/list";
import { TextSpan } from "../../../neon/src/render/hostTypes";
import { RowSlot, Styles, applyFrame, empty } from "../app/frame";
import { LineRun, cellOnRow, line } from "../grid/lines";
import { Cursor, Vt } from "../vt/vt";

export interface Screen {
	vt: Vt;
	grid: List<RowSlot>;
	styles: Styles;
	cols: int32;
	rows: int32;
	cursor: Cursor | null;
}

export enum ScreenError {
	CreateFailed,
	FrameFailed,
	ResizeFailed,
	ScrollFailed,
}

export function open(this typeof Screen, cols: int32, rows: int32): Result<Screen, ScreenError> {
	const created = Vt.create(cols, rows);
	if (!created.ok) { return Result.err(ScreenError.CreateFailed); }
	let slots: RowSlot[] = [];
	for (let i = 0; i < rows; i++) { slots.push(RowSlot.blank()); }
	return Result.ok({
		vt: created.value,
		grid: createList<RowSlot>(slots),
		styles: Styles.empty(),
		cols: cols,
		rows: rows,
		cursor: null,
	});
}

export function paint(this s: Screen): Result<void, ScreenError> {
	const applied = applyFrame(s.grid, s.styles, s.vt);
	if (!applied.ok) { return Result.err(ScreenError.FrameFailed); }
	s.cursor = applied.value;
	return Result.ok(null);
}

export function feed(this s: Screen, bytes: string): Result<void, ScreenError> {
	s.vt.writeText(bytes);
	return s.paint();
}

export function feedBytes(this s: Screen, bytes: uint8[]): Result<void, ScreenError> {
	s.vt.write(bytes);
	return s.paint();
}

export function feedsInStep(this s: Screen, bytes: string): boolean {
	return s.feed(bytes).ok && s.sameAsFreshRead();
}

export function feedChunks(this s: Screen, text: string, chunk: int32): Result<void, ScreenError> {
	const view = text.asBytes();
	const total = view.length as int32;
	const size = chunk > 0 ? chunk : total;
	for (let at = 0; at < total; at += size) {
		s.vt.write(view[at..at + Math.min(size, total - at)]);
		const _painted = try s.paint();
	}
	return Result.ok(null);
}

export function resize(this s: Screen, cols: int32, rows: int32): Result<void, ScreenError> {
	if (!s.vt.resize(cols, rows).ok) { return Result.err(ScreenError.ResizeFailed); }
	s.cols = cols;
	s.rows = rows;
	const have = s.grid.length() as int32;
	for (let i = have; i < rows; i++) { s.grid.push(RowSlot.blank()); }
	for (let i = have; i > rows; i--) { s.grid.remove(i - 1); }
	return s.paint();
}

export function close(this s: Screen): void {
	s.vt.free();
}

export function untrimmedText(this s: Screen, y: int32): string {
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

export function lines(this s: Screen): string {
	let texts: Vec<string> = [];
	for (let y = 0; y < s.rows; y++) { texts.push(s.text(y)); }
	return texts.join("\n");
}

function viewportOffset(this s: Screen): Result<int32, ScreenError> {
	const offset = s.vt.scrollOffset();
	if (!offset.ok) { return Result.err(ScreenError.ScrollFailed); }
	return Result.ok(offset.value);
}

export function history(this s: Screen): Result<Vec<string>, ScreenError> {
	let out: Vec<string> = [];
	s.vt.scrollTop();
	const _top = try s.paint();
	while (true) {
		const offset = try s.viewportOffset();
		for (let y = 0; y < s.rows; y++) {
			while ((out.length as int32) <= offset + y) { out.push(""); }
			out[offset + y] = s.text(y);
		}
		const bottom = s.vt.atBottom();
		if (!bottom.ok) { return Result.err(ScreenError.ScrollFailed); }
		if (bottom.value) { break; }
		s.vt.scrollLines(s.rows);
		const _page = try s.paint();
		const next = try s.viewportOffset();
		if (next <= offset) { return Result.err(ScreenError.ScrollFailed); }
	}
	s.vt.scrollBottom();
	const _bottom = try s.paint();
	return Result.ok(out);
}

function runText(r: LineRun): string {
	const fg = `${r.fg.r},${r.fg.g},${r.fg.b}`;
	const bg = `${r.bg.r},${r.bg.g},${r.bg.b}`;
	const look = `${r.bold ? "B" : ""}${r.italic ? "I" : ""}${r.strikethrough ? "S" : ""}`;
	return `${r.units}:${fg}/${bg}/u${r.underline as int32}${look}`;
}

export function runsText(runs: Vec<LineRun>): string {
	let out = "";
	for (const r of runs) { out += runText(r) + " "; }
	return out;
}

export function mismatch(this s: Screen): string {
	const fresh = s.vt.rows();
	if (!fresh.ok) { return "the fresh read failed"; }
	const colors = s.vt.palette();
	if (!colors.ok) { return "the palette read failed"; }
	const vtRows = fresh.value;
	if ((vtRows.length as int32) != s.rows) {
		return `the vt has ${vtRows.length} rows, the screen ${s.rows}`;
	}
	const at = s.vt.cursor();
	if (!at.ok) { return "the cursor read failed"; }
	const vtCursor = at.value;
	for (let y = 0; y < s.rows; y++) {
		const vtLine = vtRows[y].line(vtCursor.cellOnRow(y), colors.value.bg);
		if (!vtLine.ok) { return `row ${y}: no line`; }
		if (vtLine.value.text != s.untrimmedText(y)) {
			return `row ${y}: text [${s.untrimmedText(y)}] but the vt has [${vtLine.value.text}]`;
		}
		const have = runsText(s.runs(y));
		const want = runsText(vtLine.value.runs);
		if (have != want) { return `row ${y}: runs ${have} but the vt has ${want}`; }
		const spans = s.spans(y);
		let spanned = "";
		for (const sp of spans) { spanned += sp.text; }
		const oneSpanPerRun = (spans.length as int32) == (s.runs(y).length as int32);
		if (spanned != s.untrimmedText(y) || !oneSpanPerRun) {
			return `row ${y}: spans do not cover the line`;
		}
	}
	const shown = s.cursor;
	if ((vtCursor === null) != (shown === null)) { return "the cursor's presence differs"; }
	if (vtCursor !== null && shown !== null && (vtCursor.x != shown.x || vtCursor.y != shown.y)) {
		return `cursor ${shown.x},${shown.y} but the vt has ${vtCursor.x},${vtCursor.y}`;
	}
	return "";
}

export function sameAsFreshRead(this s: Screen): boolean {
	return s.mismatch() == "";
}

export function cursorAt(this s: Screen, x: int32, y: int32): boolean {
	const c = s.cursor;
	return c !== null && c.x == x && c.y == y;
}

export function blankScreen(cols: int32, rows: int32): Screen | null {
	const r = Screen.open(cols, rows);
	if (!r.ok) { return null; }
	return r.value;
}
