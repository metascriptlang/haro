import { Accessor, Setter, createSignal } from "../../../../../neon/src/core/signal";
import { NeonNode } from "../../../../../neon/src/render/node";
import { frameNow, requestFrame } from "../../../../../neon/src/animation/frame";
import { Graphics, Scene2D, TileGroup } from "../../../../../neon/src/components/scene2d";
import { GraphicsOp } from "../../../../../neon/src/render/graphics";
import { Color, Vec2, rgba, vec2, whiteTile } from "../../../../../void/src/void2d/types";
import { TileCell } from "../../../../../void/src/void2d/node";
import { CellInk } from "../../../grid/lines";
import { Cursor, CursorLook, CursorShape, Rgb } from "../../../vt/vt";
import { BLINK_MS, blinks, drawn, resets, shapeOf } from "../../../term/cursor";
import { Trail, particleAlpha } from "../../../term/trail";
import { CURSOR_TEXT } from "../../theme";
import { CellMetrics } from "../ui/cellText";

const BLOCK_ALPHA = 0.8;
const PARTICLE_SIDE = 0.2;
const OUTLINE_PER_EM = 1.0 / 8;

export interface CursorModel {
	metrics: CellMetrics;
	padding: Accessor<number>;
	col: Accessor<number>;
	setCol: Setter<number>;
	row: Accessor<number>;
	setRow: Setter<number>;
	drawing: Accessor<GraphicsOp[]>;
	setDrawing: Setter<GraphicsOp[]>;
	dust: Accessor<TileCell[]>;
	setDust: Setter<TileCell[]>;
	trail: Trail;
	tint: Rgb;
	shownTint: Rgb;
	ink: CellInk | null;
	inked: (ink: CellInk | null) => void;
	frame: int32;
	last: number;
	at: Cursor | null;
	look: CursorLook;
	focused: boolean;
	blinkOn: boolean;
	blinkTimer: number;
	lastReset: float64;
}

export function open(
	this typeof CursorModel,
	metrics: CellMetrics,
	padding: Accessor<number>,
	tint: Rgb,
	inked: (ink: CellInk | null) => void,
): CursorModel {
	const [col, setCol] = createSignal<number>(0);
	const [row, setRow] = createSignal<number>(0);
	const [drawing, setDrawing] = createSignal<GraphicsOp[]>([]);
	const [dust, setDust] = createSignal<TileCell[]>([]);
	return {
		metrics: metrics,
		padding: padding,
		col: col,
		setCol: setCol,
		row: row,
		setRow: setRow,
		drawing: drawing,
		setDrawing: setDrawing,
		dust: dust,
		setDust: setDust,
		trail: Trail.start(),
		tint: tint,
		shownTint: tint,
		ink: null,
		inked: inked,
		frame: 0,
		last: 0,
		at: null,
		look: { visible: false, shape: CursorShape.Block, blinking: false },
		focused: true,
		blinkOn: true,
		blinkTimer: -1,
		lastReset: 0.0,
	};
}

function colorOf(c: Rgb, alpha: float64): Color {
	const r = (c.r as float32) / 255;
	const g = (c.g as float32) / 255;
	const b = (c.b as float32) / 255;
	return rgba(r, g, b, alpha as float32);
}

function cursorWidth(this c: CursorModel): float64 {
	const cellWidth = c.metrics.cellWidth();
	const at = c.at;
	if (at === null || !at.wide) { return cellWidth; }
	const shape = c.look.shapeOf(c.focused);
	return shape == CursorShape.Block || shape == CursorShape.BlockHollow ? 2 * cellWidth : cellWidth;
}

function operations(this c: CursorModel): GraphicsOp[] {
	let ops: GraphicsOp[] = [];
	if (c.at !== null && c.look.drawn(c.focused, c.blinkOn)) {
		let points: Vec2[] = [];
		for (const p of c.trail.shownCorners()) {
			points.push(vec2(p.x as float32, p.y as float32));
		}
		const shape = c.look.shapeOf(c.focused);
		if (shape == CursorShape.BlockHollow) {
			const width = (c.metrics.fontSize() * OUTLINE_PER_EM) as float32;
			const color = colorOf(c.tint, 1);
			ops.push({ kind: "strokePoly", points: points, width: width, closed: true, color: color });
		} else if (shape != CursorShape.Block || !c.trail.resting()) {
			const alpha = shape == CursorShape.Block ? BLOCK_ALPHA : 1;
			ops.push({ kind: "fillConvex", points: points, color: colorOf(c.tint, alpha) });
		}
	}
	return ops;
}

function dustCells(this c: CursorModel): TileCell[] {
	const side = c.metrics.cellWidth() * PARTICLE_SIDE;
	const tile = whiteTile(side as float32, side as float32);
	let cells: TileCell[] = [];
	for (const p of c.trail.particles) {
		cells.push({
			x: (p.pos.x - side / 2) as float32,
			y: (p.pos.y - side / 2) as float32,
			tile: tile,
			color: colorOf(c.tint, particleAlpha(p)),
			scaleX: 1,
			scaleY: 1,
			rotation: 0,
		});
	}
	return cells;
}

function step(this c: CursorModel, now: number): void {
	const dt = Math.max(0, (now - c.last) / 1000);
	c.last = now;
	const shape = c.look.shapeOf(c.focused);
	const moving = c.trail.animate(dt, shape, c.cursorWidth(), c.metrics.rowHeight(), false);
	const ops = c.operations();
	if (ops.length > 0 || c.drawing().length > 0) { c.setDrawing(ops); }
	const cells = c.dustCells();
	if (cells.length > 0 || c.dust().length > 0) { c.setDust(cells); }
	c.frame = moving ? requestFrame((next: number): void => { c.step(next); }) : 0;
}

function blockInk(this c: CursorModel): CellInk | null {
	const lit = c.at !== null && c.look.drawn(c.focused, c.blinkOn) &&
		c.look.shapeOf(c.focused) == CursorShape.Block;
	return lit ? { fg: CURSOR_TEXT, bg: c.tint } : null;
}

export function paintCursor(this c: CursorModel): void {
	const ink = c.blockInk();
	if (ink != c.ink) {
		c.ink = ink;
		c.inked(ink);
	}
	const at = c.at;
	if (at !== null && c.look.visible) {
		const pad = c.padding();
		c.trail.moveTo(pad + at.x * c.metrics.cellWidth(), pad + at.y * c.metrics.rowHeight());
	}
	if (c.frame != 0) { return; }
	c.last = frameNow();
	c.frame = requestFrame((now: number): void => { c.step(now); });
}

function stopBlink(this c: CursorModel): void {
	if (c.blinkTimer >= 0) { clearTimeout(c.blinkTimer); }
	c.blinkTimer = -1;
	c.blinkOn = true;
}

function armBlink(this c: CursorModel): void {
	c.blinkTimer = setTimeout((): void => {
		c.blinkTimer = -1;
		c.blinkOn = !c.blinkOn;
		c.paintCursor();
		if (c.look.blinks(c.focused)) { c.armBlink(); }
	}, BLINK_MS);
}

function syncBlink(this c: CursorModel): void {
	if (!c.look.blinks(c.focused)) {
		c.stopBlink();
	} else if (c.blinkTimer < 0) {
		c.armBlink();
	}
}

function restartBlink(this c: CursorModel): void {
	c.stopBlink();
	c.syncBlink();
	c.paintCursor();
}

export function showCursor(this c: CursorModel, at: Cursor | null, look: CursorLook): void {
	const unchanged = at == c.at && look == c.look && c.tint == c.shownTint;
	if (unchanged && c.frame == 0 && c.trail.resting()) { return; }
	c.shownTint = c.tint;
	if (at !== null) {
		c.setCol(at.x);
		c.setRow(at.y);
	}
	c.at = at;
	c.look = look;
	c.syncBlink();
	c.paintCursor();
}

export function focusCursor(this c: CursorModel, focused: boolean): void {
	c.focused = focused;
	c.restartBlink();
}

export function wakeCursor(this c: CursorModel, now: float64): void {
	if (!resets(c.lastReset, now)) { return; }
	c.lastReset = now;
	c.restartBlink();
}

export function CursorTrail(props: { model: CursorModel }): NeonNode {
	return <Scene2D>
		<Graphics operations={props.model.drawing()} />
		<TileGroup cells={props.model.dust()} />
	</Scene2D>;
}

const RED: Rgb = { r: 255, g: 0, b: 0 };

interface InksSeen {
	count: int32;
	last: CellInk | null;
}

function cursorFor(look: CursorLook): CursorModel {
	const [fontSize, _setFontSize] = createSignal<number>(16);
	const [fontFamily, _setFontFamily] = createSignal<string>("");
	const [cellWidth, _setCellWidth] = createSignal<number>(10);
	const [rowHeight, _setRowHeight] = createSignal<number>(20);
	const [padding, _setPadding] = createSignal<number>(4);
	const metrics: CellMetrics = {
		fontSize: fontSize,
		fontFamily: fontFamily,
		cellWidth: cellWidth,
		rowHeight: rowHeight,
	};
	const c = CursorModel.open(metrics, padding, RED, (ink: CellInk | null): void => {});
	c.at = { x: 3, y: 2, wide: false };
	c.look = look;
	return c;
}

test "a focused block is a translucent quad only while it moves; at rest its cell is lit" {
	const c = cursorFor({ visible: true, shape: CursorShape.Block, blinking: false });
	c.trail.moveTo(34, 44);
	while (c.trail.animate(1.0 / 60, CursorShape.Block, 10, 20, false)) {}
	assert c.operations().length == 0;
	c.trail.moveTo(54, 44);
	assert c.trail.animate(1.0 / 60, CursorShape.Block, 10, 20, false);
	const ops = c.operations();
	assert ops.length == 1;
	const quad = ops[0];
	if (quad.kind == "fillConvex") {
		assert quad.points[0].x != 54;
		assert quad.color.a == (BLOCK_ALPHA as float32);
	} else {
		assert false;
	}
	c.look = { visible: true, shape: CursorShape.Bar, blinking: false };
	assert c.operations().length == 1;
}

test "the cursor hands over its cell's ink while a focused block is drawn, and none otherwise" {
	const c = cursorFor({ visible: true, shape: CursorShape.Block, blinking: true });
	const seen: InksSeen = { count: 0, last: null };
	c.inked = (ink: CellInk | null): void => {
		seen.count += 1;
		seen.last = ink;
	};
	c.paintCursor();
	c.paintCursor();
	assert seen.count == 1;
	const lit: CellInk = { fg: CURSOR_TEXT, bg: RED };
	assert seen.last == lit;
	c.blinkOn = false;
	c.paintCursor();
	assert seen.count == 2 && seen.last === null;
	c.blinkOn = true;
	c.focused = false;
	c.paintCursor();
	assert seen.count == 2;
	c.focused = true;
	c.tint = { r: 0, g: 0, b: 255 };
	c.paintCursor();
	assert seen.count == 3;
	const last = seen.last;
	assert last !== null && last.bg == c.tint;
	c.look = { visible: true, shape: CursorShape.Underline, blinking: false };
	c.paintCursor();
	assert seen.count == 4 && seen.last === null;
}

test "an unfocused cursor is an outline an eighth of an em wide, and a hidden one draws nothing" {
	const c = cursorFor({ visible: true, shape: CursorShape.Bar, blinking: false });
	c.focused = false;
	const outline = c.operations()[0];
	if (outline.kind == "strokePoly") {
		assert outline.width == 2;
		assert outline.closed;
	} else {
		assert false;
	}
	c.look = { visible: false, shape: CursorShape.Bar, blinking: false };
	assert c.operations().length == 0;
}

test "each particle is a square a fifth of a cell wide that fades with its lifetime" {
	const c = cursorFor({ visible: false, shape: CursorShape.Block, blinking: false });
	c.trail.moveTo(34, 44);
	while (c.trail.animate(1.0 / 60, CursorShape.Block, 10, 20, false)) {}
	c.trail.moveTo(34, 244);
	while (c.trail.particles.length == 0) {
		const _moving = c.trail.animate(1.0 / 60, CursorShape.Block, 10, 20, false);
	}
	const cells = c.dustCells();
	assert cells.length == c.trail.particles.length;
	assert cells.length > 0;
	assert cells[0].tile.w == 2;
	assert cells[0].color.a <= 1;
}

function settle(this c: CursorModel): void {
	let now = c.last;
	while (c.frame != 0) {
		now += 16;
		c.step(now);
	}
}

test "showing a cursor that has not moved, changed look or tint arms no frame once it has settled" {
	const c = cursorFor({ visible: true, shape: CursorShape.Bar, blinking: false });
	const at: Cursor = { x: 3, y: 2, wide: false };
	const look: CursorLook = { visible: true, shape: CursorShape.Block, blinking: false };
	c.showCursor(at, look);
	assert c.frame != 0;
	c.settle();
	c.showCursor(at, look);
	assert c.frame == 0;
	c.showCursor({ x: 4, y: 2, wide: false }, look);
	assert c.frame != 0;
	c.settle();
	c.tint = { r: 0, g: 0, b: 255 };
	c.showCursor({ x: 4, y: 2, wide: false }, look);
	assert c.frame != 0;
}

test "a step at rest leaves the drawing and the dust alone, and clears them once when they empty" {
	const c = cursorFor({ visible: true, shape: CursorShape.Block, blinking: false });
	c.trail.moveTo(34, 44);
	while (c.trail.animate(1.0 / 60, CursorShape.Block, 10, 20, false)) {}
	const sets = { drawing: 0, dust: 0 };
	const setDrawing = c.setDrawing;
	const setDust = c.setDust;
	c.setDrawing = (v: GraphicsOp[] | ((prev: GraphicsOp[]) => GraphicsOp[])): void => {
		sets.drawing += 1;
		setDrawing(v);
	};
	c.setDust = (v: TileCell[] | ((prev: TileCell[]) => TileCell[])): void => {
		sets.dust += 1;
		setDust(v);
	};
	c.step(100);
	assert sets.drawing == 0 && sets.dust == 0;
}
