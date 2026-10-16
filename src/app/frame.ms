import { List } from "../../../neon/src/core/list";
import { TextSpan } from "../../../neon/src/render/hostTypes";
import { Style } from "../../../neon/src/render/style";
import { GridLine, LineRun, line } from "../grid/lines";
import { PlanKind, plan } from "../screen/plan";
import { Cursor, Rgb, Row, Underline, Vt, palette } from "../vt/vt";

export struct RowSlot {
	line: GridLine;
	spans: TextSpan[];
}

export enum FrameError {
	PlanFailed,
	CursorFailed,
	PaletteFailed,
	LineFailed,
}

const HEX = "0123456789abcdef";

function hexByte(v: uint8): string {
	const n = v as int32;
	return HEX[n >> 4] + HEX[n & 15];
}

export function hexOf(c: Rgb): string {
	return "#" + hexByte(c.r) + hexByte(c.g) + hexByte(c.b);
}

type Decoration = "none" | "underline" | "line-through" | "underline line-through";

function decorationOf(run: LineRun): Decoration {
	const under = run.underline != Underline.None;
	if (under && run.strikethrough) { return "underline line-through"; }
	if (under) { return "underline"; }
	if (run.strikethrough) { return "line-through"; }
	return "none";
}

function styleOf(styles: Map<string, Style>, run: LineRun, background: Rgb): Style {
	const fg = hexOf(run.fg);
	const bg = run.bg == background ? "" : hexOf(run.bg);
	const decoration = decorationOf(run);
	const weight: "bold" | "normal" = run.bold ? "bold" : "normal";
	const slant: "italic" | "normal" = run.italic ? "italic" : "normal";
	const line: "wavy" | "solid" = run.underline == Underline.Curly ? "wavy" : "solid";
	const key = fg + bg + decoration + weight + slant + line;
	const known = styles.get(key);
	if (known !== undefined) { return known; }
	const style: Style = bg == ""
		? { color: fg, textDecorationLine: decoration, textDecorationStyle: line, fontWeight: weight, fontStyle: slant }
		: {
			color: fg, backgroundColor: bg, textDecorationLine: decoration, textDecorationStyle: line,
			fontWeight: weight, fontStyle: slant,
		};
	styles.set(key, style);
	return style;
}

export function spansOf(styles: Map<string, Style>, l: GridLine, background: Rgb): TextSpan[] {
	let spans: TextSpan[] = [];
	let at = 0;
	for (const run of l.runs) {
		spans.push({ text: l.text.slice(at, at + run.units), style: styleOf(styles, run, background) });
		at += run.units;
	}
	return spans;
}

function slotOf(
	styles: Map<string, Style>, row: Row, cursor: Cursor | null, background: Rgb,
): Result<RowSlot, FrameError> {
	const cursorCell = cursor !== null && cursor.y == row.y ? cursor.x : -1;
	const built = row.line(cursorCell);
	if (!built.ok) { return Result.err(FrameError.LineFailed); }
	return Result.ok({ line: built.value, spans: spansOf(styles, built.value, background) });
}

export function applyFrame(
	grid: List<RowSlot>, styles: Map<string, Style>, vt: Vt,
): Result<Cursor | null, FrameError> {
	const planned = vt.plan();
	if (!planned.ok) { return Result.err(FrameError.PlanFailed); }
	const at = vt.cursor();
	if (!at.ok) { return Result.err(FrameError.CursorFailed); }
	const colors = vt.palette();
	if (!colors.ok) { return Result.err(FrameError.PaletteFailed); }
	const cursor = at.value;
	const p = planned.value;
	const kept = (grid.length() as int32) - p.scrolled;
	for (let i = 0; i < p.scrolled; i++) { grid.remove(0); }
	for (const row of p.rows) {
		const slot = try slotOf(styles, row, cursor, colors.value.bg);
		if (p.kind == PlanKind.Scroll && row.y >= kept) {
			grid.push(slot);
		} else {
			grid.set(row.y, slot);
		}
	}
	return Result.ok(cursor);
}

const BLACK: Rgb = { r: 0, g: 0, b: 0 };
const WHITE: Rgb = { r: 255, g: 255, b: 255 };
const RED: Rgb = { r: 255, g: 0, b: 0 };

function run(units: int32, fg: Rgb, bg: Rgb, underline: Underline): LineRun {
	return {
		units: units, fg: fg, bg: bg, underline: underline,
		bold: false, italic: false, strikethrough: false,
	};
}

test "each run becomes a span over its own text, sharing one style per look" {
	const styles = new Map<string, Style>();
	const l: GridLine = {
		text: "ab cd",
		runs: [run(2, RED, BLACK, Underline.None), run(1, WHITE, BLACK, Underline.None), run(2, RED, BLACK, Underline.None)],
		cursorCell: -1,
	};
	const spans = spansOf(styles, l, BLACK);
	assert spans.length == 3;
	assert spans[0].text == "ab" && spans[1].text == " " && spans[2].text == "cd";
	assert spans[0].style === spans[2].style;
	assert styles.size == 2;
}

test "a background differs from the terminal's only where a run says so" {
	const styles = new Map<string, Style>();
	const l: GridLine = {
		text: "xy",
		runs: [run(1, WHITE, BLACK, Underline.Curly), run(1, WHITE, RED, Underline.None)],
		cursorCell: -1,
	};
	const spans = spansOf(styles, l, BLACK);
	assert spans[0].style!.backgroundColor === undefined;
	assert spans[0].style!.textDecorationLine == "underline";
	assert spans[1].style!.backgroundColor == "#ff0000";
	assert spans[1].style!.color == "#ffffff";
}
