@include("./wake.h");
@compile("./wake.c");

import { element } from "../../../neon/src/macros/ui/element";
import { NeonNode } from "../../../neon/src/render/node";
import { NeonEvent } from "../../../neon/src/render/event";
import { Accessor, createSignal } from "../../../neon/src/core/signal";
import { ForList } from "../../../neon/src/macros/ui/flow";
import { PixelRatio } from "../../../neon/src/api/pixelRatio";
import { Void, View, Text } from "../../../neon/src/components/primitives";
import {
	runWindow,
	DesktopOptions,
	desktopOptions,
} from "../../../neon/src/platform/ion/window";
import { addFont } from "../../../void/src/void2d/font";
import { Align, TextLayout, layout } from "../../../void/src/void2d/textLayout";
import { onWake } from "../../../ion/src/index";
import { argv, exit } from "std/process";
import { RowSlot } from "./frame";
import { gridSize } from "../grid/size";
import { Cursor } from "../vt/vt";
import { smoke } from "./smoke";
import {
	Term,
	TermError,
	shellExitCode,
	fit,
	openTerm,
	pumpFrame,
	sendKey,
	sendText,
	shutdown,
} from "./term";

extern function appWireWake(): void;

const SHELL = "pwsh.exe -NoLogo";
const FONT_PATH = "assets/JetBrainsMonoNL-Regular.ttf";
const FONT_SIZE: number = 14;
const PADDING: number = 6;
const BACKGROUND = "#0c0c0c";
const FOREGROUND = "#cccccc";
const PROBE = "MMMMMMMMMM";

interface Cell {
	advance: number;
	lineHeight: number;
}

function measureCell(): Cell {
	const font = addFont(FONT_PATH);
	if (!font.ok) {
		console.log(`terminator: the font ${FONT_PATH} did not load`);
		exit(1);
	}
	const laid = TextLayout.layout(PROBE, {
		font: font.value, size: FONT_SIZE as float32, letterSpacing: 0.0, lineSpacing: 0.0,
		maxWidth: 0.0, align: Align.Left,
	});
	if (!laid.ok) {
		console.log("terminator: the cell probe did not lay out");
		exit(1);
	}
	return {
		advance: (laid.value.width as number) / PROBE.length,
		lineHeight: laid.value.lineHeight as number,
	};
}

function fatal(what: string, error: TermError): void {
	console.log(`terminator: ${what}: ${error.toString()}`);
	exit(1);
}

function App(t: Term, cell: Cell): NeonNode {
	const [cellWidth, setCellWidth] = createSignal<number>(0);
	const [rowHeight, setRowHeight] = createSignal<number>(0);
	const [cursorCol, setCursorCol] = createSignal<number>(0);
	const [cursorRow, setCursorRow] = createSignal<number>(0);
	const [cursorShown, setCursorShown] = createSignal<boolean>(false);

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
		if (!t.alive) {
			console.log(`terminator: the shell exited with code ${t.shellExitCode()}`);
			t.shutdown();
			exit(0);
		}
	}

	onWake((): void => { refresh(); });

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
			console.log(`terminator: cell ${advance}x${lineHeight} is not a grid size`);
			exit(1);
			return;
		}
		setCellWidth(cellPx / ratio);
		setRowHeight(rowPx / ratio);
		console.log(
			`terminator: layout ${e.width}x${e.height} ratio ${ratio} ` +
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

function shellOf(): string {
	for (let i = 1; i + 1 < argv.length; i++) {
		if (argv[i] == "--shell") { return argv[i + 1]; }
	}
	return SHELL;
}

function main(): int32 {
	const opened = openTerm(shellOf());
	if (!opened.ok) {
		fatal("open", opened.error);
		return 1;
	}
	const t = opened.value;
	appWireWake();
	for (const arg of argv) {
		if (arg == "--smoke") { smoke(t); }
	}
	const opts: DesktopOptions = { ...desktopOptions("Terminator", 960, 600), font: FONT_PATH };
	const cell = measureCell();
	const code = runWindow(opts, (): NeonNode => App(t, cell));
	t.shutdown();
	return code;
}

exit(main());
