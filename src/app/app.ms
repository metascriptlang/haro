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
import { Cursor } from "../vt/vt";
import { Clip, ControlError, Controls } from "./controls";
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
const BACKGROUND = "#0c0c0c";
const FOREGROUND = "#cccccc";
const PROBE = "MMMMMMMMMM";
const SELECTION = "#cccccc";
const SHADES = 3;
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
	const [cursorShown, setCursorShown] = createSignal<boolean>(false);

	const controls = Controls.open();
	const dialog = PasteView.open();
	const [viewWidth, setViewWidth] = createSignal<number>(0);
	const shades = createList<Block>([NO_SHADE, NO_SHADE, NO_SHADE]);
	let lit: Vec<Block> = [NO_SHADE, NO_SHADE, NO_SHADE];

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

	const show = (cursor: Cursor | null): void => {
		if (cursor === null) {
			setCursorShown(false);
			return;
		}
		setCursorCol(cursor.x);
		setCursorRow(cursor.y);
		setCursorShown(true);
	};

	function refresh(): void {
		const frame = t.pumpFrame();
		if (!frame.ok) {
			fatal("frame", frame.error);
			return;
		}
		show(frame.value.cursor);
		repaint();
		dialog.show(controls.held, cellWidth(), viewWidth());
		if (frame.value.more) { setTimeout((): void => { refresh(); }, 0); }
		if (frame.value.ended) { entry.exited(t.shellExitCode()); }
	}

	entry.onWake((): void => { refresh(); });

	const clip: Clip = {
		write: (text: string): void => {
			try {
				Clipboard.setString(text);
			} catch (e) {
				console.log(`haro: copy failed: ${e}`);
			}
		},
		read: (done: (text: string) => void): void => {
			Clipboard.getString().then((text: string): void => {
				done(text);
				refresh();
			});
		},
	};

	const lineRow = (item: Accessor<RowSlot>): NeonNode => {
		return element(
			<Text
				style={{ fontSize: FONT_SIZE, color: FOREGROUND, height: rowHeight() }}
				cellWidth={cellWidth()}
				spans={item().spans}
			/>
		);
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
		setCellWidth(cellPx / ratio);
		setRowHeight(rowPx / ratio);
		console.log(
			`haro: layout ${e.width}x${e.height} ratio ${ratio} ` +
				`cell ${advance}x${lineHeight} grid ${size.value[0]}x${size.value[1]}`
		);
		const fitted = t.fit(size.value[0], size.value[1]);
		if (!fitted.ok) {
			fatal("fit", fitted.error);
			return;
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

	const pressed = (e: NeonEvent): void => {
		if (cellWidth() <= 0) { return; }
		const handled = controls.down(t, clip, e.button as int32, spot(e), e.locationX, e.locationY, Date.now(), cellWidth());
		if (!handled.ok) {
			fatalControl("press", handled.error);
			return;
		}
		repaint();
	};

	const dragged = (e: NeonEvent): void => {
		if (cellWidth() <= 0) { return; }
		const handled = controls.move(t, spot(e), e.pressed);
		if (!handled.ok) {
			fatalControl("move", handled.error);
			return;
		}
		if (handled.value) { repaint(); }
	};

	const released = (e: NeonEvent): void => {
		controls.up();
	};

	const wheeled = (e: NeonEvent): void => {
		const handled = controls.roll(t, e.deltaY);
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
			controls.cancel();
			refresh();
		},
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
					backgroundColor: SELECTION,
					opacity: item().rows > 0 ? 0.35 : 0,
					pointerEvents: "none",
				}}
			/>
		);
	};

	return element(
		<Void style={{ backgroundColor: BACKGROUND, padding: PADDING }}>
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
				onWheel={wheeled}>
				{ForList<RowSlot>({ each: t.grid, children: lineRow })}
				{ForList<Block>({ each: shades, children: shadeBox })}
				<View
					style={{
						position: "absolute",
						left: cursorCol() * cellWidth(),
						top: cursorRow() * rowHeight(),
						width: cellWidth(),
						height: rowHeight(),
						backgroundColor: FOREGROUND,
						opacity: cursorShown() ? 0.5 : 0,
					}}
				/>
			</View>
			{PasteDialog(dialog, look)}
		</Void>
	);
}
