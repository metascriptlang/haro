import { element } from "../../../neon/src/macros/ui/element";
import { NeonNode } from "../../../neon/src/render/node";
import { NeonEvent } from "../../../neon/src/render/event";
import { Accessor, createSignal } from "../../../neon/src/core/signal";
import { createList } from "../../../neon/src/core/list";
import { ForList } from "../../../neon/src/macros/ui/flow";
import { PixelRatio } from "../../../neon/src/api/pixelRatio";
import { Clipboard } from "../../../neon/src/api/clipboard";
import { Void, View, Text } from "../../../neon/src/components/primitives";
import { addFont } from "../../../void/src/void2d/font";
import { Align, TextLayout } from "../../../void/src/void2d/textLayout";
import { RowSlot } from "./frame";
import { gridSize } from "../grid/size";
import { Spot, spotAt } from "../input/pointer";
import { Block } from "../select/select";
import { Cursor, CursorLook, CursorShape, MouseGeometry } from "../vt/vt";
import { BLINK_MS, BOX_SLOTS, Box, NO_BOX, blinks, boxes, drawn, resets, shapeOf } from "../term/cursor";
import { applyTitle, ringBell } from "./chrome";
import { hexOf } from "./frame";
import { BACKGROUND, FOREGROUND, THEME_BG, THEME_FG } from "./theme";
import { Bridge, ControlError, Controls, Hit } from "./controls";
import { PasteDialog, PasteView, Look } from "./pasteDialog";
import {
	Term,
	TermError,
	shellExitCode,
	fit,
	pumpFrame,
	sendKey,
	sendText,
} from "./term";

const FONT_SIZE: number = 14;
const PADDING: number = 6;
const PROBE = "MMMMMMMMMM";
const SHADES = 3;
const HOLD_RECHECK_MS = 100;
const NO_SHADE: Block = { row: 0, col: 0, rows: 0, cols: 0 };

export interface Cell {
	advance: number;
	lineHeight: number;
}

export enum CellError {
	FontNotLoaded,
	ProbeNotLaidOut,
}

export interface Entry {
	onWake: (handler: () => void) => void;
	exited: (code: int32) => void;
	fail: (message: string) => void;
	openLink: (uri: string) => void;
}

export function measureCell(fontPath: string): Result<Cell, CellError> {
	const font = addFont(fontPath);
	if (!font.ok) { return Result.err(CellError.FontNotLoaded); }
	const laid = TextLayout.layout(PROBE, {
		font: font.value, size: FONT_SIZE as float32, letterSpacing: 0.0, lineSpacing: 0.0,
		maxWidth: 0.0, align: Align.Left,
	});
	if (!laid.ok) { return Result.err(CellError.ProbeNotLaidOut); }
	return Result.ok({
		advance: (laid.value.width as number) / PROBE.length,
		lineHeight: laid.value.lineHeight as number,
	});
}

export function App(t: Term, cell: Cell, entry: Entry): NeonNode {
	const [cellWidth, setCellWidth] = createSignal<number>(0);
	const [rowHeight, setRowHeight] = createSignal<number>(0);
	const [cursorCol, setCursorCol] = createSignal<number>(0);
	const [cursorRow, setCursorRow] = createSignal<number>(0);
	const [background, setBackground] = createSignal<string>(BACKGROUND);
	const [foreground, setForeground] = createSignal<string>(FOREGROUND);
	let themed = false;

	const controls = Controls.open();
	const dialog = PasteView.open();
	const [viewWidth, setViewWidth] = createSignal<number>(0);
	const shades = createList<Block>([NO_SHADE, NO_SHADE, NO_SHADE]);
	let lit: Vec<Block> = [NO_SHADE, NO_SHADE, NO_SHADE];
	const cursorBoxes = createList<Box>([NO_BOX, NO_BOX, NO_BOX, NO_BOX]);
	let litBoxes: Vec<Box> = [NO_BOX, NO_BOX, NO_BOX, NO_BOX];
	let cursorAt: Cursor | null = null;
	let cursorLook: CursorLook = { visible: false, shape: CursorShape.Block, blinking: false };
	let focused = true;
	let blinkOn = true;
	let blinkTimer = -1;
	let lastReset = 0.0;
	let heldTimer = -1;
	let geometry: MouseGeometry = { cellWidth: 1, cellHeight: 1, width: 1, height: 1 };

	const fatal = (what: string, error: TermError): void => {
		entry.fail(`${what}: ${error.toString()}`);
	};

	const fatalControl = (what: string, error: ControlError): void => {
		entry.fail(`${what}: ${error.toString()}`);
	};

	function repaint(): void {
		const drawn = controls.shades(t);
		if (!drawn.ok) {
			fatalControl("selection", drawn.error);
			return;
		}
		for (let i = 0; i < SHADES; i++) {
			const next = i < drawn.value.length ? drawn.value[i] : NO_SHADE;
			if (next == lit[i]) { continue; }
			lit[i] = next;
			shades.set(i, next);
		}
	}

	function paintCursor(): void {
		let next: Vec<Box> = [];
		const at = cursorAt;
		if (at !== null && drawn(cursorLook, focused, blinkOn)) {
			next = boxes(shapeOf(cursorLook, focused), at.x, at.y, cellWidth(), rowHeight(), 1 / PixelRatio.get());
		}
		for (let i = 0; i < BOX_SLOTS; i++) {
			const box = i < next.length ? next[i] : NO_BOX;
			if (box == litBoxes[i]) { continue; }
			litBoxes[i] = box;
			cursorBoxes.set(i, box);
		}
	}

	function stopBlink(): void {
		if (blinkTimer >= 0) { clearTimeout(blinkTimer); }
		blinkTimer = -1;
		blinkOn = true;
	}

	function armBlink(): void {
		blinkTimer = setTimeout((): void => {
			blinkTimer = -1;
			blinkOn = !blinkOn;
			paintCursor();
			if (blinks(cursorLook, focused)) { armBlink(); }
		}, BLINK_MS) as int32;
	}

	function syncBlink(): void {
		if (!blinks(cursorLook, focused)) {
			stopBlink();
		} else if (blinkTimer < 0) {
			armBlink();
		}
	}

	function restartBlink(): void {
		stopBlink();
		syncBlink();
		paintCursor();
	}

	function watchHold(): void {
		if (heldTimer >= 0) { return; }
		heldTimer = setTimeout((): void => {
			heldTimer = -1;
			refresh();
		}, HOLD_RECHECK_MS) as int32;
	}

	function clipWrite(text: string): void {
		try {
			Clipboard.setString(text);
		} catch (e) {
			console.log(`haro: copy failed: ${e}`);
		}
	}

	function clipRead(done: (text: string) => void): void {
		Clipboard.getString().then((text: string): void => {
			done(text);
			refresh();
		});
	}

	function bridge(): Bridge {
		return { write: clipWrite, read: clipRead, open: entry.openLink };
	}

	function refresh(): void {
		const frame = t.pumpFrame();
		if (!frame.ok) {
			fatal("frame", frame.error);
			return;
		}
		const f = frame.value;
		const copied = f.copied;
		if (copied !== null) { clipWrite(copied); }
		const title = f.title;
		if (title !== null) { applyTitle(title); }
		if (f.bells > 0) { ringBell(f.bells); }
		if (f.asked) { controls.asked(t, bridge()); }
		if (f.held) {
			watchHold();
		} else {
			const colors = f.colors;
			if (colors !== null) {
				const bg = hexOf(colors.bg);
				const fg = hexOf(colors.fg);
				if (bg != background()) { setBackground(bg); }
				if (fg != foreground()) { setForeground(fg); }
			}
			const cursor = f.cursor;
			if (cursor !== null) {
				setCursorCol(cursor.x);
				setCursorRow(cursor.y);
			}
			cursorAt = cursor;
			cursorLook = f.look;
			syncBlink();
			paintCursor();
			repaint();
		}
		dialog.show(controls.held, controls.reading, cellWidth(), viewWidth());
		if (frame.value.more) { setTimeout((): void => { refresh(); }, 0); }
		if (frame.value.ended) { entry.exited(t.shellExitCode()); }
	}

	const clip: Bridge = bridge();

	entry.onWake((): void => {
		const now = Date.now() as float64;
		if (resets(lastReset, now)) {
			lastReset = now;
			restartBlink();
		}
		refresh();
	});

	const lineRow = (item: Accessor<RowSlot>): NeonNode => {
		return element(
			<Text
				style={{ fontSize: FONT_SIZE, color: foreground(), height: rowHeight() }}
				cellWidth={cellWidth()}
				spans={item().spans}
			/>
		);
	};

	const focus = (gained: boolean): void => {
		focused = gained;
		restartBlink();
		const sent = t.sendFocus(gained);
		if (!sent.ok) { fatal("focus", sent.error); }
	};

	const layout = (e: NeonEvent): void => {
		if (e.width <= 0 || e.height <= 0) { return; }
		const advance = cell.advance;
		const lineHeight = cell.lineHeight;
		const ratio = PixelRatio.get();
		const cellPx = Math.ceil(advance * ratio) as int32;
		const rowPx = Math.ceil(lineHeight * ratio) as int32;
		const widthPx = PixelRatio.getPixelSizeForLayoutSize(e.width) as int32;
		const heightPx = PixelRatio.getPixelSizeForLayoutSize(e.height) as int32;
		const size = gridSize(widthPx, heightPx, cellPx, rowPx);
		if (!size.ok) {
			entry.fail(`cell ${advance}x${lineHeight} is not a grid size`);
			return;
		}
		setViewWidth(e.width);
		dialog.shownFor = null;
		geometry = {
			cellWidth: cellPx, cellHeight: rowPx, width: size.value[0] * cellPx, height: size.value[1] * rowPx,
		};
		setCellWidth(cellPx / ratio);
		setRowHeight(rowPx / ratio);
		paintCursor();
		console.log(
			`haro: layout ${e.width}x${e.height} ratio ${ratio} ` +
				`cell ${advance}x${lineHeight} grid ${size.value[0]}x${size.value[1]}`
		);
		const fitted = t.fit(size.value[0], size.value[1]);
		if (!fitted.ok) {
			fatal("fit", fitted.error);
			return;
		}
		if (!themed) {
			themed = true;
			const s = t.session;
			if (s !== null && !s.vt.setDefaultColors(THEME_FG, THEME_BG).ok) {
				entry.fail("the default colours were refused");
				return;
			}
		}
		if (fitted.value) { refresh(); }
	};

	const afterInput = (): void => {
		const moved = controls.typed(t);
		if (!moved.ok) {
			fatalControl("typed", moved.error);
			return;
		}
		if (moved.value) { refresh(); }
	};

	const typed = (e: NeonEvent): void => {
		const handled = controls.keyDown(t, e, clip);
		if (!handled.ok) {
			fatalControl("key", handled.error);
			return;
		}
		if (handled.value) {
			refresh();
			return;
		}
		const sent = t.sendKey(e);
		if (!sent.ok) {
			fatal("key", sent.error);
			return;
		}
		if (sent.value > 0) { afterInput(); }
	};

	const committed = (e: NeonEvent): void => {
		if (controls.holding()) { return; }
		const sent = t.sendText(e.text);
		if (!sent.ok) {
			fatal("text", sent.error);
			return;
		}
		if (sent.value > 0) { afterInput(); }
	};

	const spot = (e: NeonEvent): Spot => {
		return spotAt(e.locationX, e.locationY, cellWidth(), rowHeight(), t.cols, t.rows);
	};

	const hit = (e: NeonEvent): Hit => {
		return {
			at: spot(e), x: e.locationX, y: e.locationY, scale: PixelRatio.get(), mods: e.mods as int32, cell: geometry,
		};
	};

	const pressed = (e: NeonEvent): void => {
		if (cellWidth() <= 0) { return; }
		const handled = controls.down(t, clip, e.button as int32, hit(e), Date.now());
		if (!handled.ok) {
			fatalControl("press", handled.error);
			return;
		}
		repaint();
	};

	const dragged = (e: NeonEvent): void => {
		if (cellWidth() <= 0) { return; }
		const handled = controls.move(t, hit(e), e.pressed);
		if (!handled.ok) {
			fatalControl("move", handled.error);
			return;
		}
		if (handled.value) { repaint(); }
	};

	const released = (e: NeonEvent): void => {
		if (cellWidth() <= 0) { return; }
		const handled = controls.up(t, e.button as int32, hit(e));
		if (!handled.ok) { fatalControl("release", handled.error); }
	};

	const wheeled = (e: NeonEvent): void => {
		const handled = controls.roll(t, e.deltaY, hit(e));
		if (!handled.ok) {
			fatalControl("wheel", handled.error);
			return;
		}
		if (handled.value) { refresh(); }
	};

	const look: Look = {
		cellWidth: cellWidth,
		rowHeight: rowHeight,
		fontSize: FONT_SIZE,
		onConfirm: (): void => {
			const sent = controls.confirm(t);
			if (!sent.ok) { fatalControl("paste", sent.error); }
			refresh();
		},
		onCancel: (): void => {
			const dropped = controls.cancel(t);
			if (!dropped.ok) { fatalControl("clipboard", dropped.error); }
			refresh();
		},
	};

	const cursorBox = (item: Accessor<Box>): NeonNode => {
		return element(
			<View
				style={{
					position: "absolute",
					left: item().x,
					top: item().y,
					width: item().w,
					height: item().h,
					backgroundColor: foreground(),
					opacity: item().alpha,
					pointerEvents: "none",
				}}
			/>
		);
	};

	const shadeBox = (item: Accessor<Block>): NeonNode => {
		return element(
			<View
				style={{
					position: "absolute",
					left: item().col * cellWidth(),
					top: item().row * rowHeight(),
					width: item().cols * cellWidth(),
					height: item().rows * rowHeight(),
					backgroundColor: foreground(),
					opacity: item().rows > 0 ? 0.35 : 0,
					pointerEvents: "none",
				}}
			/>
		);
	};

	return element(
		<Void style={{ backgroundColor: background(), padding: PADDING }}>
			<View
				style={{ flexGrow: 1, flexShrink: 1, flexBasis: 0, pointerEvents: "box-only" }}
				focusable
				imeRect={{
					x: cursorCol() * cellWidth(),
					y: cursorRow() * rowHeight(),
					width: cellWidth(),
					height: rowHeight(),
				}}
				onLayout={layout}
				onKeyDown={typed}
				onTextInput={committed}
				onPointerDown={pressed}
				onPointerMove={dragged}
				onPointerUp={released}
				onFocus={(e: NeonEvent): void => { focus(true); }}
				onBlur={(e: NeonEvent): void => { focus(false); }}
				onWheel={wheeled}>
				{ForList<RowSlot>({ each: t.grid, children: lineRow })}
				{ForList<Block>({ each: shades, children: shadeBox })}
				{ForList<Box>({ each: cursorBoxes, children: cursorBox })}
			</View>
			{PasteDialog(dialog, look)}
		</Void>
	);
}
