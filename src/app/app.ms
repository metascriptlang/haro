import { element } from "../../../neon/src/macros/ui/element";
import { NeonNode } from "../../../neon/src/render/node";
import { NeonEvent } from "../../../neon/src/render/event";
import { Accessor, createSignal } from "../../../neon/src/core/signal";
import { createList } from "../../../neon/src/core/list";
import { ForList, Show } from "../../../neon/src/macros/ui/flow";
import { PixelRatio } from "../../../neon/src/api/pixelRatio";
import { Clipboard } from "../../../neon/src/api/clipboard";
import { Void, View, Text, ViewHandle } from "../../../neon/src/components/primitives";
import { RowSlot } from "./frame";
import { stats, noteKey } from "./stats";
import { gridSize } from "../grid/size";
import { Spot, spotAt } from "../input/pointer";
import { Block } from "../select/select";
import { Cursor, CursorLook, CursorShape, MouseGeometry } from "../vt/vt";
import { BLINK_MS, BOX_SLOTS, Box, NO_BOX, blinks, boxes, drawn, resets, shapeOf } from "../term/cursor";
import { applyTitle, ringBell } from "./chrome";
import { hexOf } from "./frame";
import { Config, fontPx } from "../config/config";
import { noticeLines } from "./notice";
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

const NOTICE_BACKGROUND = "#5c1f24";
const NOTICE_TEXT = "#ffffff";
const NOTICE_PADDING: number = 8;
const NOTICE_FALLBACK_COLS: int32 = 80;
const PROBE = "MMMMMMMMMM";
const SHADES = 3;
const HOLD_RECHECK_MS = 100;
const AUTOSCROLL_MS = 15;
const NO_SHADE: Block = { row: 0, col: 0, rows: 0, cols: 0 };

export interface Entry {
	onWake: (handler: () => void) => void;
	schedule: (run: () => void) => void;
	exited: (code: int32) => void;
	fail: (message: string) => void;
	openLink: (uri: string) => void;
	close: () => void;
	onConfig: (handler: (c: Config | null, error: string) => void) => void;
}

function restartNeeded(now: Config, started: Config): boolean {
	return now.fontFamily.join("\n") != started.fontFamily.join("\n") || now.fontSize != started.fontSize || now.command != started.command ||
		now.workingDirectory != started.workingDirectory;
}

export function App(t: Term, entry: Entry, started: Config): NeonNode {
	const fontSize = started.fontPx();
	let settings = started;
	let grid: ViewHandle | null = null;
	const [cellWidth, setCellWidth] = createSignal<number>(0);
	const [rowHeight, setRowHeight] = createSignal<number>(0);
	const [cursorCol, setCursorCol] = createSignal<number>(0);
	const [cursorRow, setCursorRow] = createSignal<number>(0);
	const [background, setBackground] = createSignal<string>(hexOf(started.background));
	const [foreground, setForeground] = createSignal<string>(hexOf(started.foreground));
	const [padding, setPadding] = createSignal<number>(started.padding);
	let notice = "";
	const [noticed, setNoticed] = createSignal<boolean>(false);
	const [preedit, setPreedit] = createSignal<string>("");
	const [composing, setComposing] = createSignal<boolean>(false);
	const noticeRows = createList<string>([]);
	let themed = false;

	const controls = Controls.open();
	controls.keybinds = started.keybinds;
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
	let blinkTimer: number = -1;
	let lastReset = 0.0;
	let heldTimer: number = -1;
	let scrollTimer: number = -1;
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
			const width = at.wide ? 2 * cellWidth() : cellWidth();
			next = boxes(shapeOf(cursorLook, focused), at.x, at.y, width, rowHeight(), 1 / PixelRatio.get());
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
		}, BLINK_MS);
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
		}, HOLD_RECHECK_MS);
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
		return { write: clipWrite, read: clipRead, open: entry.openLink, close: entry.close };
	}

	function refresh(): void {
		stats.refreshes += 1;
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
		if (frame.value.more) {
			stats.more += 1;
			entry.schedule(refresh);
		}
		if (frame.value.ended) { entry.exited(t.shellExitCode()); }
	}

	const clip: Bridge = bridge();

	function showNotice(text: string): void {
		notice = text;
		const room = viewWidth() - 2 * padding() - 2 * NOTICE_PADDING;
		const cols = cellWidth() > 0 ? Math.max(1, Math.floor(room / cellWidth())) as int32 : NOTICE_FALLBACK_COLS;
		noticeRows.replaceAll(noticeLines(text, cols));
		setNoticed(text != "");
	}

	function applySettings(): boolean {
		const s = t.session;
		if (s === null) { return true; }
		const vt = s.vt;
		if (!vt.setDefaultColors(settings.foreground, settings.background).ok || !vt.setPalette(settings.palette).ok
			|| !vt.setScrollback(settings.scrollback).ok) {
			entry.fail("the terminal refused the configured colours or scrollback");
			return false;
		}
		return true;
	}

	entry.onConfig((c: Config | null, error: string): void => {
		if (c === null) {
			showNotice(`config.ms: ${error}`);
			return;
		}
		settings = c;
		controls.keybinds = c.keybinds;
		setPadding(c.padding);
		showNotice(restartNeeded(c, started) ? "config.ms: fontFamily, fontSize, command and workingDirectory apply when Haro restarts" : "");
		if (themed && applySettings()) { refresh(); }
	});

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
				style={{ fontSize: fontSize, height: rowHeight() }}
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
		const handle = grid;
		if (handle === null) {
			entry.fail("the grid laid out before its handle arrived");
			return;
		}
		const probe = handle.measureText(PROBE, { fontSize: fontSize });
		const advance = probe.width / PROBE.length;
		const lineHeight = probe.height;
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
		showNotice(notice);
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
		if (!fitted.ok && fitted.error == TermError.PtyOpenFailed) {
			showNotice("the shell did not start: check command in config.ms, or --shell");
			return;
		}
		if (!fitted.ok) {
			fatal("fit", fitted.error);
			return;
		}
		if (!themed) {
			themed = true;
			if (!applySettings()) { return; }
		}
		if (fitted.value) { refresh(); }
	};

	const afterInput = (): void => {
		const moved = controls.typed(t);
		if (!moved.ok) {
			fatalControl("typed", moved.error);
			return;
		}
		if (moved.value) { entry.schedule(refresh); }
	};

	const typed = (e: NeonEvent): void => {
		const handled = controls.keyDown(t, e, clip);
		if (!handled.ok) {
			fatalControl("key", handled.error);
			return;
		}
		if (handled.value) {
			entry.schedule(refresh);
			return;
		}
		const sent = t.sendKey(e);
		if (!sent.ok) {
			fatal("key", sent.error);
			return;
		}
		if (sent.value > 0) {
			stats.noteKey(performance.now());
			afterInput();
		}
	};

	const compose = (text: string): void => {
		setPreedit(text);
		setComposing(text != "");
	};

	const committed = (e: NeonEvent): void => {
		compose("");
		if (controls.holding()) { return; }
		const sent = t.sendText(e.text);
		if (!sent.ok) {
			fatal("text", sent.error);
			return;
		}
		if (sent.value > 0) {
			stats.noteKey(performance.now());
			afterInput();
		}
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

	const autoscroll = (): void => {
		if (scrollTimer >= 0 || controls.autoscroll == 0) { return; }
		scrollTimer = setTimeout((): void => {
			scrollTimer = -1;
			const ticked = controls.autoscrollTick(t);
			if (!ticked.ok) {
				fatalControl("autoscroll", ticked.error);
				return;
			}
			if (!ticked.value) { return; }
			entry.schedule(refresh);
			autoscroll();
		}, AUTOSCROLL_MS);
	};

	const dragged = (e: NeonEvent): void => {
		if (cellWidth() <= 0) { return; }
		const handled = controls.move(t, hit(e), e.pressed);
		if (!handled.ok) {
			fatalControl("move", handled.error);
			return;
		}
		if (handled.value) { repaint(); }
		autoscroll();
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
		if (handled.value) { entry.schedule(refresh); }
	};

	const look: Look = {
		cellWidth: cellWidth,
		rowHeight: rowHeight,
		fontSize: fontSize,
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

	const noticeRow = (item: Accessor<string>): NeonNode => {
		return element(
			<Text
				style={{ fontSize: fontSize, color: NOTICE_TEXT, height: rowHeight() }}
				cellWidth={cellWidth()}
				spans={[{ text: item(), style: {} }]}
			/>
		);
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
		<Void style={{ backgroundColor: background(), padding: padding() }}>
			<View
				style={{ flexGrow: 1, flexShrink: 1, flexBasis: 0, pointerEvents: "box-only" }}
				focusable
				ref={(h: ViewHandle): void => {
					grid = h;
					h.focus();
				}}
				imeRect={{
					x: cursorCol() * cellWidth(),
					y: cursorRow() * rowHeight(),
					width: cellWidth(),
					height: rowHeight(),
				}}
				onLayout={layout}
				onKeyDown={typed}
				onTextInput={committed}
				onPreedit={(e: NeonEvent): void => { compose(e.text); }}
				onPointerDown={pressed}
				onPointerMove={dragged}
				onPointerUp={released}
				onFocus={(e: NeonEvent): void => { focus(true); }}
				onBlur={(e: NeonEvent): void => { focus(false); }}
				onWheel={wheeled}>
				{ForList<RowSlot>({ each: t.grid, children: lineRow })}
				{ForList<Block>({ each: shades, children: shadeBox })}
				{ForList<Box>({ each: cursorBoxes, children: cursorBox })}
				{Show({
					when: composing,
					children: element(
						<View
							style={{
								position: "absolute", left: cursorCol() * cellWidth(), top: cursorRow() * rowHeight(),
								backgroundColor: background(), pointerEvents: "none",
							}}>
							<Text
								style={{ fontSize: fontSize, color: foreground(), height: rowHeight(), textDecorationLine: "underline" }}
								cellWidth={cellWidth()}>
								{preedit()}
							</Text>
						</View>
					),
				})}
			</View>
			{PasteDialog(dialog, look)}
			{Show({
				when: noticed,
				children: element(
					<View
						style={{
							position: "absolute", left: padding(), right: padding(), top: padding(), padding: NOTICE_PADDING,
							backgroundColor: NOTICE_BACKGROUND, borderRadius: 4,
						}}
						onPointerDown={(e: NeonEvent): void => { showNotice(""); }}>
						{ForList<string>({ each: noticeRows, children: noticeRow })}
					</View>
				),
			})}
		</Void>
	);
}
