import { Accessor, Setter, createSignal } from "../../../../../neon/src/core/signal";
import { List, createList } from "../../../../../neon/src/core/list";
import { ForList } from "../../../../../neon/src/macros/ui/flow";
import { NeonNode } from "../../../../../neon/src/render/node";
import { PixelRatio } from "../../../../../neon/src/api/pixelRatio";
import { View } from "../../../../../neon/src/components/primitives";
import { Cursor, CursorLook, CursorShape } from "../../../vt/vt";
import {
	BLINK_MS,
	BOX_SLOTS,
	Box,
	NO_BOX,
	blinks,
	boxes,
	drawn,
	resets,
	shapeOf,
} from "../../../term/cursor";
import { CellMetrics } from "../ui/cellText";

export interface CursorModel {
	metrics: CellMetrics;
	col: Accessor<number>;
	setCol: Setter<number>;
	row: Accessor<number>;
	setRow: Setter<number>;
	boxes: List<Box>;
	lit: Vec<Box>;
	at: Cursor | null;
	look: CursorLook;
	focused: boolean;
	blinkOn: boolean;
	blinkTimer: number;
	lastReset: float64;
}

export function createCursor(metrics: CellMetrics): CursorModel {
	const [col, setCol] = createSignal<number>(0);
	const [row, setRow] = createSignal<number>(0);
	return {
		metrics: metrics,
		col: col,
		setCol: setCol,
		row: row,
		setRow: setRow,
		boxes: createList<Box>([NO_BOX, NO_BOX, NO_BOX, NO_BOX]),
		lit: [NO_BOX, NO_BOX, NO_BOX, NO_BOX],
		at: null,
		look: { visible: false, shape: CursorShape.Block, blinking: false },
		focused: true,
		blinkOn: true,
		blinkTimer: -1,
		lastReset: 0.0,
	};
}

export function paintCursor(this c: CursorModel): void {
	let next: Vec<Box> = [];
	const at = c.at;
	if (at !== null && c.look.drawn(c.focused, c.blinkOn)) {
		const cellWidth = c.metrics.cellWidth();
		const width = at.wide ? 2 * cellWidth : cellWidth;
		const shape = c.look.shapeOf(c.focused);
		next = boxes(shape, at.x, at.y, width, c.metrics.rowHeight(), 1 / PixelRatio.get());
	}
	for (let i = 0; i < BOX_SLOTS; i++) {
		const box = i < next.length ? next[i] : NO_BOX;
		if (box == c.lit[i]) { continue; }
		c.lit[i] = box;
		c.boxes.set(i, box);
	}
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

export function CursorBoxes(props: { model: CursorModel; color: Accessor<string> }): NeonNode {
	const box = (item: Accessor<Box>): NeonNode => <View
		style={{
			position: "absolute",
			left: item().x,
			top: item().y,
			width: item().w,
			height: item().h,
			backgroundColor: props.color(),
			opacity: item().alpha,
			pointerEvents: "none",
		}}
	/>;
	return <ForList each={props.model.boxes}>{box}</ForList>;
}
