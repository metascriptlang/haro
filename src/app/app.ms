import { element } from "../../../neon/src/macros/ui/element";
import { NeonNode } from "../../../neon/src/render/node";
import { NeonEvent } from "../../../neon/src/render/event";
import { Accessor, createSignal } from "../../../neon/src/core/signal";
import { ForList } from "../../../neon/src/macros/ui/flow";
import { PixelRatio } from "../../../neon/src/api/pixelRatio";
import { Void, View, Text, ViewHandle } from "../../../neon/src/components/primitives";
import { addFont } from "../../../void/src/void2d/font";
import { Align, TextLayout } from "../../../void/src/void2d/textLayout";
import { RowSlot } from "./frame";
import { gridSize } from "../grid/size";
import { Cursor } from "../vt/vt";
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

	const fatal = (what: string, error: TermError): void => {
		entry.fail(`${what}: ${error.toString()}`);
	};

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
		if (frame.value.more) { setTimeout((): void => { refresh(); }, 0); }
		if (frame.value.ended) { entry.exited(t.shellExitCode()); }
	}

	entry.onWake((): void => { refresh(); });

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

	const typed = (e: NeonEvent): void => {
		const sent = t.sendKey(e);
		if (!sent.ok) { fatal("key", sent.error); }
	};

	const committed = (e: NeonEvent): void => {
		const sent = t.sendText(e.text);
		if (!sent.ok) { fatal("text", sent.error); }
	};

	return element(
		<Void style={{ backgroundColor: BACKGROUND, padding: PADDING }}>
			<View
				style={{ flexGrow: 1, flexShrink: 1, flexBasis: 0, pointerEvents: "box-only" }}
				focusable
				ref={(h: ViewHandle): void => { h.focus(); }}
				imeRect={{
					x: cursorCol() * cellWidth(),
					y: cursorRow() * rowHeight(),
					width: cellWidth(),
					height: rowHeight(),
				}}
				onLayout={layout}
				onKeyDown={typed}
				onTextInput={committed}>
				{ForList<RowSlot>({ each: t.grid, children: lineRow })}
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
		</Void>
	);
}
