import { Accessor, Setter, createSignal } from "../../../../../neon/src/core/signal";
import { NeonNode } from "../../../../../neon/src/render/node";
import { frameNow, requestFrame } from "../../../../../neon/src/animation/frame";
import { Graphics, Scene2D } from "../../../../../neon/src/components/scene2d";
import { GraphicsOp } from "../../../../../neon/src/render/graphics";
import { Color, Vec2, rgba, vec2 } from "../../../../../void/src/void2d/types";
import { Cursor, CursorLook, CursorShape, Rgb } from "../../../vt/vt";
import { BLINK_MS, blinks, drawn, resets, shapeOf } from "../../../term/cursor";
import { Trail, particleAlpha } from "../../../term/trail";
import { CellMetrics } from "../ui/cellText";

const BLOCK_ALPHA = 0.5;
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
	trail: Trail;
	tint: Rgb;
	frame: int32;
	last: number;
	at: Cursor | null;
	look: CursorLook;
	focused: boolean;
	blinkOn: boolean;
	blinkTimer: number;
	lastReset: float64;
}

export function createCursor(metrics: CellMetrics, padding: Accessor<number>, tint: Rgb): CursorModel {
	const [col, setCol] = createSignal<number>(0);
	const [row, setRow] = createSignal<number>(0);
	const [drawing, setDrawing] = createSignal<GraphicsOp[]>([]);
	return {
		metrics: metrics,
		padding: padding,
		col: col,
		setCol: setCol,
		row: row,
		setRow: setRow,
		drawing: drawing,
		setDrawing: setDrawing,
		trail: Trail.start(),
		tint: tint,
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
		for (let i = 0; i < 4; i++) {
			const p = c.trail.cornerAt(i);
			points.push(vec2(p.x as float32, p.y as float32));
		}
		const shape = c.look.shapeOf(c.focused);
		if (shape == CursorShape.BlockHollow) {
			const width = (c.metrics.fontSize() * OUTLINE_PER_EM) as float32;
			const color = colorOf(c.tint, 1);
			ops.push({ kind: "strokePoly", points: points, width: width, closed: true, color: color });
		} else {
			const alpha = shape == CursorShape.Block ? BLOCK_ALPHA : 1;
			ops.push({ kind: "fillConvex", points: points, color: colorOf(c.tint, alpha) });
		}
	}
	const side = c.metrics.cellWidth() * PARTICLE_SIDE;
	for (const p of c.trail.particles) {
		ops.push({
			kind: "fillRect",
			x: (p.pos.x - side / 2) as float32,
			y: (p.pos.y - side / 2) as float32,
			w: side as float32,
			h: side as float32,
			color: colorOf(c.tint, particleAlpha(p)),
		});
	}
	return ops;
}

function step(this c: CursorModel, now: number): void {
	const dt = Math.max(0, (now - c.last) / 1000);
	c.last = now;
	const shape = c.look.shapeOf(c.focused);
	const moving = c.trail.animate(dt, shape, c.cursorWidth(), c.metrics.rowHeight(), false);
	c.setDrawing(c.operations());
	c.frame = moving ? requestFrame((next: number): void => { c.step(next); }) : 0;
}

export function paintCursor(this c: CursorModel): void {
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
	</Scene2D>;
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
	const c = createCursor(metrics, padding, { r: 255, g: 0, b: 0 });
	c.at = { x: 3, y: 2, wide: false };
	c.look = look;
	return c;
}

test "a focused block is a translucent quad over its cell, offset by the padding" {
	const c = cursorFor({ visible: true, shape: CursorShape.Block, blinking: false });
	c.trail.moveTo(34, 44);
	while (c.trail.animate(1.0 / 60, CursorShape.Block, 10, 20, false)) {}
	const ops = c.operations();
	assert ops.length == 1;
	const quad = ops[0];
	if (quad.kind == "fillConvex") {
		assert quad.points[0] == vec2(34, 44);
		assert quad.points[2] == vec2(44, 64);
		assert quad.color.a == (BLOCK_ALPHA as float32);
	} else {
		assert false;
	}
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
	const _moving = c.trail.animate(1.0 / 60, CursorShape.Block, 10, 20, false);
	const ops = c.operations();
	assert ops.length == c.trail.particles.length;
	assert ops.length > 0;
	const dust = ops[0];
	if (dust.kind == "fillRect") {
		assert dust.w == 2;
		assert dust.color.a <= 1;
	} else {
		assert false;
	}
}
