import { visible } from "../../../../input/paste";
import {
	Axis,
	CellRect,
	Node,
	PaneId,
	Placed,
	Split,
	along,
	ancestors,
	cellRect,
	firstCells,
	panes,
} from "../../../../workspace/tree";
import { Tab, layout } from "../../../../workspace/workspace";

export enum DividerStyle {
	Cell,
	Line,
}

export struct DividerLine {
	split: Split;
	rect: CellRect;
	at: int32;
	before: PaneId;
}

export struct Segment {
	axis: Axis;
	x: int32;
	y: int32;
	length: int32;
	glyphs: string;
	focused: boolean;
	line: int32;
	joinsBefore: boolean;
	joinsAfter: boolean;
}

export struct TitleSpot {
	pane: PaneId;
	x: int32;
	y: int32;
	text: string;
	focused: boolean;
}

export struct FrameLayout {
	cols: int32;
	rows: int32;
	divider: int32;
	focused: PaneId;
	panes: Placed[];
	lines: DividerLine[];
	segments: Segment[];
	titles: TitleSpot[];
}

export struct Box {
	left: float64;
	top: float64;
	width: float64;
	height: float64;
}

const UP: int32 = 1;
const DOWN: int32 = 2;
const LEFT: int32 = 4;
const RIGHT: int32 = 8;
const JOINS = " │││─┘┐┤─└┌├─┴┬┼";

function start(r: CellRect, axis: Axis): int32 {
	return axis == Axis.SideBySide ? r.x : r.y;
}

function crossStart(r: CellRect, axis: Axis): int32 {
	return axis == Axis.SideBySide ? r.y : r.x;
}

function crossLength(r: CellRect, axis: Axis): int32 {
	return axis == Axis.SideBySide ? r.rows : r.cols;
}

export function currentAt(this l: DividerLine, divider: int32): int32 {
	const size = l.rect.along(l.split.axis);
	return start(l.rect, l.split.axis) + l.split.firstCells(size, divider);
}

function holds(this l: DividerLine, x: int32, y: int32, divider: int32): boolean {
	const axis = l.split.axis;
	const onAxis = axis == Axis.SideBySide ? x : y;
	const cross = axis == Axis.SideBySide ? y : x;
	const from = crossStart(l.rect, axis);
	return onAxis >= l.at && onAxis < l.at + divider &&
		cross >= from && cross < from + crossLength(l.rect, axis);
}

function ownerAt(
	lines: DividerLine[],
	x: int32,
	y: int32,
	divider: int32,
): int32 {
	for (let i: int32 = 0; i < lines.length; i++) {
		if (lines[i].holds(x, y, divider)) { return i; }
	}
	return -1;
}

function glyphAt(
	lines: DividerLine[],
	x: int32,
	y: int32,
	divider: int32,
	axis: Axis,
): string {
	let joins: int32 = 0;
	if (ownerAt(lines, x, y - 1, divider) >= 0) { joins |= UP; }
	if (ownerAt(lines, x, y + 1, divider) >= 0) { joins |= DOWN; }
	if (ownerAt(lines, x - 1, y, divider) >= 0) { joins |= LEFT; }
	if (ownerAt(lines, x + 1, y, divider) >= 0) { joins |= RIGHT; }
	if (joins == 0) { return axis == Axis.SideBySide ? "│" : "─"; }
	return JOINS.charAt(joins);
}

function borders(
	focus: CellRect,
	axis: Axis,
	at: int32,
	cross: int32,
	divider: int32,
): boolean {
	const near = start(focus, axis);
	const touches = near + focus.along(axis) == at || near == at + divider;
	const from = crossStart(focus, axis) - divider;
	const to = crossStart(focus, axis) + crossLength(focus, axis) + divider;
	return touches && cross >= from && cross < to;
}

export function titleText(title: string, cols: int32): string {
	if (title == "" || cols < 1) { return ""; }
	return visible(` ${title} `, cols);
}

function cellsOf(text: string): int32 {
	let cells: int32 = 0;
	for (let i: int32 = 0; i < text.length; i++) {
		const unit = text.charCodeAt(i);
		if (unit < 0xdc00 || unit > 0xdfff) { cells += 1; }
	}
	return cells;
}

function titled(titles: TitleSpot[], x: int32, y: int32): boolean {
	for (const t of titles) {
		if (y == t.y && x >= t.x && x < t.x + cellsOf(t.text)) { return true; }
	}
	return false;
}

function lastPane(n: Node): PaneId {
	const order = n.panes();
	return order[order.length - 1].id;
}

function linesOf(
	tab: Tab,
	placed: Placed[],
	whole: CellRect,
	divider: int32,
): DividerLine[] {
	const lines: DividerLine[] = [];
	const ids: PaneId[] = [tab.focused];
	for (const p of placed) {
		if (!(p.pane.id == tab.focused)) { ids.push(p.pane.id); }
	}
	for (const id of ids) {
		const frames = tab.root.ancestors(id, whole, divider) ?? [];
		for (let i = frames.length - 1; i >= 0; i--) {
			const f = frames[i];
			let known = false;
			for (const l of lines) {
				if (l.split === f.split) { known = true; }
			}
			if (known) { continue; }
			const size = f.rect.along(f.split.axis);
			lines.push({
				split: f.split,
				rect: f.rect,
				at: start(f.rect, f.split.axis) + f.split.firstCells(size, divider),
				before: lastPane(f.split.first),
			});
		}
	}
	return lines;
}

function titlesOf(
	placed: Placed[],
	focused: PaneId,
	divider: int32,
	title: (id: PaneId) => string,
): TitleSpot[] {
	const spots: TitleSpot[] = [];
	if (divider < 1) { return spots; }
	for (const p of placed) {
		if (p.rect.y < divider) { continue; }
		const text = titleText(title(p.pane.id), p.rect.cols);
		if (text == "") { continue; }
		spots.push({
			pane: p.pane.id,
			x: p.rect.x,
			y: p.rect.y - 1,
			text: text,
			focused: p.pane.id == focused,
		});
	}
	return spots;
}

function cellAt(axis: Axis, along: int32, cross: int32): [int32, int32] {
	return axis == Axis.SideBySide ? [along, cross] : [cross, along];
}

function segmentsOf(
	lines: DividerLine[],
	titles: TitleSpot[],
	focus: CellRect,
	divider: int32,
): Segment[] {
	const out: Segment[] = [];
	for (let li: int32 = 0; li < lines.length; li++) {
		const l = lines[li];
		const axis = l.split.axis;
		const from = crossStart(l.rect, axis);
		const to = from + crossLength(l.rect, axis);
		const bands = Math.max(divider, 1);
		for (let band = l.at; band < l.at + bands; band++) {
			let first: int32 = -1;
			let focusedRun = false;
			let glyphs = "";
			for (let cross = from; cross <= to; cross++) {
				const [x, y] = cellAt(axis, band, cross);
				const inside = cross < to && !titled(titles, x, y);
				const focused = inside && borders(focus, axis, l.at, cross, divider);
				if (first >= 0 && (!inside || focusedRun != focused)) {
					const [sx, sy] = cellAt(axis, band, first);
					const [px, py] = cellAt(axis, band, first - 1);
					out.push({
						axis: axis,
						x: sx,
						y: sy,
						length: cross - first,
						glyphs: glyphs,
						focused: focusedRun,
						line: li,
						joinsBefore: first == from && ownerAt(lines, px, py, divider) >= 0,
						joinsAfter: cross == to && ownerAt(lines, x, y, divider) >= 0,
					});
					first = -1;
					glyphs = "";
				}
				if (!inside) { continue; }
				if (first < 0) {
					first = cross;
					focusedRun = focused;
				}
				if (divider > 0) { glyphs += glyphAt(lines, x, y, divider, axis); }
			}
		}
	}
	return out;
}

export function frameOf(
	tab: Tab,
	cols: int32,
	rows: int32,
	divider: int32,
	title: (id: PaneId) => string,
): FrameLayout {
	const whole = cellRect(0, 0, cols, rows);
	const zoomed = tab.zoomed;
	if (zoomed !== null) {
		const only = tab.layout(cols, rows, divider)
			.filter((p: Placed): boolean => p.pane.id == zoomed);
		return {
			cols: cols,
			rows: rows,
			divider: divider,
			focused: tab.focused,
			panes: only,
			lines: [],
			segments: [],
			titles: [],
		};
	}
	const placed = tab.layout(cols, rows, divider);
	let focus = whole;
	for (const p of placed) {
		if (p.pane.id == tab.focused) { focus = p.rect; }
	}
	const lines = linesOf(tab, placed, whole, divider);
	const titles = titlesOf(placed, tab.focused, divider, title);
	return {
		cols: cols,
		rows: rows,
		divider: divider,
		focused: tab.focused,
		panes: placed,
		lines: lines,
		segments: segmentsOf(lines, titles, focus, divider),
		titles: titles,
	};
}

export function dragStep(
	this l: DividerLine,
	pointerCells: float64,
	divider: int32,
): int32 {
	const target = divider > 0
		? Math.floor(pointerCells) as int32
		: Math.floor(pointerCells + 0.5) as int32;
	return target - l.currentAt(divider);
}

export function paneBox(
	rect: CellRect,
	cols: int32,
	rows: int32,
	cellWidth: float64,
	rowHeight: float64,
	gapPixels: float64,
): Box {
	const half = gapPixels / 2;
	const left = rect.x > 0 ? half : 0;
	const right = rect.x + rect.cols < cols ? half : 0;
	const top = rect.y > 0 ? half : 0;
	const bottom = rect.y + rect.rows < rows ? half : 0;
	return {
		left: rect.x * cellWidth + left,
		top: rect.y * rowHeight + top,
		width: Math.max(rect.cols * cellWidth - left - right, 0),
		height: Math.max(rect.rows * rowHeight - top - bottom, 0),
	};
}

export function lineBox(
	s: Segment,
	divider: int32,
	cellWidth: float64,
	rowHeight: float64,
	thickness: float64,
): Box {
	const vertical = s.axis == Axis.SideBySide;
	const cell = vertical ? cellWidth : rowHeight;
	const run = vertical ? rowHeight : cellWidth;
	const across = (vertical ? s.x : s.y) * cell + divider * cell / 2 -
		thickness / 2;
	const before = s.joinsBefore ? run / 2 : 0;
	const after = s.joinsAfter ? run / 2 : 0;
	const from = (vertical ? s.y : s.x) * run - before;
	const length = s.length * run + before + after;
	if (vertical) {
		return { left: across, top: from, width: thickness, height: length };
	}
	return { left: from, top: across, width: length, height: thickness };
}
