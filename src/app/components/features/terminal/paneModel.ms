import { Accessor, Setter, createSignal } from "../../../../../../neon/src/core/signal";
import { flush } from "../../../../../../neon/src/core/runtime";
import { createEffect } from "../../../../../../neon/src/core/effect";
import { Cleanup } from "../../../../../../neon/src/core/types";
import { NeonEvent } from "../../../../../../neon/src/render/event";
import { PixelRatio } from "../../../../../../neon/src/api/pixelRatio";
import { Clipboard } from "../../../../../../neon/src/api/clipboard";
import { ViewHandle } from "../../../../../../neon/src/components/primitives";
import { familyFont } from "../../../../../../neon/src/platform/void/host";
import { spriteCellFor } from "../../../../../../void/src/void2d/font";
import { gridSize } from "../../../../grid/size";
import { CellInk } from "../../../../grid/lines";
import { MouseGeometry } from "../../../../vt/vt";
import { Config, fontPx } from "../../../../config/config";
import { FrameRows, View, fitRows, hexOf, paint, repaintCursor } from "../../../frame";
import { mark, noteKey, stats } from "../../../stats";
import { CellMetrics } from "../../ui/cellText";
import {
	CursorModel,
	createCursor,
	paintCursor,
	showCursor,
	wakeCursor,
} from "../../content/cursor";
import { PreeditModel, createPreedit } from "../../content/preedit";
import { NoticeModel, noticeCols, showNotice } from "../notice/notice";
import { PasteDialogModel, showPending } from "../paste/pasteDialog";
import { Asks } from "./controls";
import { Exit, Failure, IoFrame, IoPort, settingsOf } from "./io";
import { TermError, exitCodeText } from "./term";

const HOLD_RECHECK_MS = 100;
const AUTOSCROLL_MS = 15;
const RESTART_NOTICE = "config.ms: command and workingDirectory apply when Haro restarts";

export interface AppHost {
	onWake: (handler: () => void) => void;
	schedule: (run: () => void) => void;
	exited: (code: int32) => void;
	fail: (message: string) => void;
	note: (message: string) => void;
	setTitle: (title: string) => void;
	notify: (title: string, body: string) => void;
	openLink: (uri: string) => void;
	close: () => void;
	onCloseKey: (handler: () => void) => void;
	onConfig: (handler: (c: Config | null, fontFamily: string, error: string) => void) => void;
	fontFamily: string;
}

export interface PaneModel {
	io: IoPort;
	view: View;
	host: AppHost;
	started: Config;
	shellStarted: boolean;
	ended: Exit | null;
	autoscrolling: boolean;
	cols: int32;
	rows: int32;
	notice: NoticeModel;
	dialog: PasteDialogModel;
	metrics: CellMetrics;
	setFontSize: Setter<number>;
	setFontFamily: Setter<string>;
	setCellWidth: Setter<number>;
	setRowHeight: Setter<number>;
	background: Accessor<string>;
	setBackground: Setter<string>;
	foreground: Accessor<string>;
	setForeground: Setter<string>;
	padding: Accessor<number>;
	setPadding: Setter<number>;
	viewWidth: Accessor<number>;
	setViewWidth: Setter<number>;
	cursor: CursorModel;
	preedit: PreeditModel;
	grid: ViewHandle | null;
	holdTimer: number;
	scrollTimer: number;
	mouseGeometry: MouseGeometry;
	layoutWidth: number;
	layoutHeight: number;
}

export function createPane(
	io: IoPort,
	view: View,
	host: AppHost,
	started: Config,
	notice: NoticeModel,
	dialog: PasteDialogModel,
): PaneModel {
	const [fontSize, setFontSize] = createSignal<number>(started.fontPx());
	const [fontFamily, setFontFamily] = createSignal<string>(host.fontFamily);
	const [cellWidth, setCellWidth] = createSignal<number>(0);
	const [rowHeight, setRowHeight] = createSignal<number>(0);
	const [background, setBackground] = createSignal<string>(hexOf(started.background));
	const [foreground, setForeground] = createSignal<string>(hexOf(started.foreground));
	const [padding, setPadding] = createSignal<number>(started.padding);
	const [viewWidth, setViewWidth] = createSignal<number>(0);
	const metrics: CellMetrics = {
		fontSize: fontSize,
		fontFamily: fontFamily,
		cellWidth: cellWidth,
		rowHeight: rowHeight,
	};
	io.configure(settingsOf(started));
	return {
		io: io,
		view: view,
		host: host,
		started: started,
		shellStarted: false,
		ended: null,
		autoscrolling: false,
		cols: 0,
		rows: 0,
		notice: notice,
		dialog: dialog,
		metrics: metrics,
		setFontSize: setFontSize,
		setFontFamily: setFontFamily,
		setCellWidth: setCellWidth,
		setRowHeight: setRowHeight,
		background: background,
		setBackground: setBackground,
		foreground: foreground,
		setForeground: setForeground,
		padding: padding,
		setPadding: setPadding,
		viewWidth: viewWidth,
		setViewWidth: setViewWidth,
		cursor: createCursor(metrics, padding, started.foreground, (ink: CellInk | null): void => {
			io.relight(ink, (rows: FrameRows): void => { view.repaintCursor(rows); });
		}),
		preedit: createPreedit(),
		grid: null,
		holdTimer: -1,
		scrollTimer: -1,
		mouseGeometry: {
			cellWidth: 1,
			cellHeight: 1,
			width: 1,
			height: 1,
			padLeft: 0,
			padTop: 0,
			padRight: 0,
			padBottom: 0,
		},
		layoutWidth: 0,
		layoutHeight: 0,
	};
}

export function failed(this m: PaneModel, what: string, error: string): void {
	m.failedAs(m.shellStarted, what, error);
}

function failureText(error: TermError): string {
	return match (error) {
		TermError.SettingsRefused => "the terminal refused the configured colours or scrollback",
		_ => error.toString(),
	};
}

function reported(this m: PaneModel, f: Failure): void {
	if (f.what == "fit" && f.error == TermError.PtyOpenFailed) {
		m.notify("the shell did not start: check command in config.ms, or --shell");
		return;
	}
	m.failedAs(f.started, f.what, failureText(f.error));
}

function failedAs(this m: PaneModel, started: boolean, what: string, error: string): void {
	const message = `${what}: ${error}`;
	if (!started) {
		m.host.fail(message);
		return;
	}
	const text = `Haro hit an internal error and kept the shell running. ${message}`;
	if (m.notice.text == text) { return; }
	m.host.note(message);
	m.notify(text);
}

function copyToClipboard(text: string): void {
	try {
		Clipboard.setString(text);
	} catch (e) {
		console.log(`haro: copy failed: ${e}`);
	}
}

function answerAsks(this m: PaneModel, asks: Asks): void {
	const copy = asks.copy;
	if (copy !== null) { copyToClipboard(copy); }
	for (const uri of asks.opens) { m.host.openLink(uri); }
	for (let i = 0; i < asks.reads; i++) {
		Clipboard.getString().then((text: string): void => {
			m.io.pasted(text);
			m.refresh();
		});
	}
	if (asks.close) { m.host.close(); }
}

function watchHold(this m: PaneModel): void {
	if (m.holdTimer >= 0) { return; }
	m.holdTimer = setTimeout((): void => {
		m.holdTimer = -1;
		m.refresh();
	}, HOLD_RECHECK_MS);
}

function autoscrollSoon(this m: PaneModel): void {
	if (m.scrollTimer >= 0 || !m.autoscrolling) { return; }
	m.scrollTimer = setTimeout((): void => {
		m.scrollTimer = -1;
		m.io.autoscroll();
		m.refresh();
	}, AUTOSCROLL_MS);
}

export function scheduleRefresh(this m: PaneModel): void {
	m.host.schedule((): void => { m.refresh(); });
}

export function refresh(this m: PaneModel): void {
	stats.tally.refreshes += 1;
	m.io.frame((got: IoFrame): void => { m.applied(got); });
}

function applied(this m: PaneModel, got: IoFrame): void {
	m.shellStarted = got.started;
	for (const failure of got.failures) { m.reported(failure); }
	for (const launch of got.marks) { stats.mark(launch.name, launch.at); }
	if (got.keyAt >= 0) { stats.noteKey(got.keyAt); }
	const f = got.frame;
	if (f !== null) {
		const copied = f.copied;
		if (copied !== null) { copyToClipboard(copied); }
		const title = f.title;
		if (title !== null) { m.host.setTitle(title); }
		const notification = f.notification;
		if (notification !== null && !m.cursor.focused) {
			m.host.notify(notification.title, notification.body);
		}
		if (f.held) {
			stats.tally.held += 1;
			m.watchHold();
		} else {
			if (f.rows !== null) { m.view.paint(f.rows!); }
			const colors = f.colors;
			if (colors !== null) {
				m.setBackground(hexOf(colors.bg));
				m.setForeground(hexOf(colors.fg));
				m.cursor.tint = colors.cursor ?? colors.fg;
			}
			m.cursor.showCursor(f.cursor, f.look);
		}
	}
	const pending = got.pending;
	m.dialog.showPending(
		pending.held,
		pending.reading,
		pending.closing,
		m.metrics.cellWidth(),
		m.viewWidth(),
	);
	m.answerAsks(got.asks);
	m.autoscrolling = got.autoscroll;
	m.autoscrollSoon();
	if (got.again) { m.scheduleRefresh(); }
	if (f !== null && f.more) {
		stats.tally.more += 1;
		m.scheduleRefresh();
	}
	const exit = got.exit;
	if (exit !== null) { m.shellEnded(exit); }
}

function shellEnded(this m: PaneModel, exit: Exit): void {
	if (exit.abnormal) {
		m.ended = exit;
		m.notify(`the shell exited with code ${exitCodeText(exit.code)} as it started: check command in config.ms, or --shell; press any key to close`);
		return;
	}
	if (exit.signal != 0) {
		m.ended = exit;
		m.notify(`the shell was killed by signal ${exit.signal}, press any key to close`);
		return;
	}
	m.host.exited(exit.code);
}

function notify(this m: PaneModel, text: string): void {
	const cols = noticeCols(m.viewWidth(), m.padding(), m.metrics.cellWidth());
	m.notice.showNotice(text, cols);
}

function restartNeeded(now: Config, started: Config): boolean {
	return now.command != started.command ||
		now.workingDirectory != started.workingDirectory;
}

function reconfigure(this m: PaneModel, c: Config | null, family: string, error: string): void {
	if (c === null) {
		m.notify(`config.ms: ${error}`);
		return;
	}
	m.io.configure(settingsOf(c));
	const resized = c.fontPx() != m.metrics.fontSize() || family != m.metrics.fontFamily();
	m.setPadding(c.padding);
	m.setFontSize(c.fontPx());
	m.setFontFamily(family);
	flush();
	const restart = restartNeeded(c, m.started) ? RESTART_NOTICE : "";
	m.notify(error != "" ? `config.ms: ${error}` : restart);
	if (resized && m.layoutWidth > 0) { m.fitLayout(); }
	m.refresh();
}

function closeKeyPressed(this m: PaneModel): void {
	m.io.closeKey();
	m.refresh();
}

function woke(this m: PaneModel): void {
	m.cursor.wakeCursor(Date.now() as float64);
	m.refresh();
}

export function connectHost(this m: PaneModel): void {
	m.host.onConfig((c: Config | null, family: string, error: string): void => {
		m.reconfigure(c, family, error);
	});
	m.host.onCloseKey((): void => { m.closeKeyPressed(); });
	m.host.onWake((): void => {
		m.io.drain();
		m.host.schedule((): void => { m.woke(); });
	});
	createEffect((): number => PixelRatio.get(), (ratio: number, was: number | null): Cleanup | null => {
		if (was !== null && m.layoutWidth > 0) { m.fitLayout(); }
		return null;
	});
}

export function laidOut(this m: PaneModel, e: NeonEvent): void {
	if (e.width <= 0 || e.height <= 0) { return; }
	m.layoutWidth = e.width;
	m.layoutHeight = e.height;
	m.fitLayout();
}

function fitLayout(this m: PaneModel): void {
	const font = familyFont(m.metrics.fontFamily(), 400, false);
	if (!font.ok) {
		m.failed("font", `family "${m.metrics.fontFamily()}" has no face: ${font.error.toString()}`);
		return;
	}
	const ratio = PixelRatio.get();
	const cell = spriteCellFor(font.value, (m.metrics.fontSize() * ratio) as float32);
	const cellPx = cell.width;
	const rowPx = cell.height;
	const widthPx = PixelRatio.getPixelSizeForLayoutSize(m.layoutWidth) as int32;
	const heightPx = PixelRatio.getPixelSizeForLayoutSize(m.layoutHeight) as int32;
	const size = gridSize(widthPx, heightPx, cellPx, rowPx);
	if (!size.ok) {
		m.failed("fit", `cell ${cellPx}x${rowPx} px is not a grid size`);
		return;
	}
	const cols = size.value[0];
	const rows = size.value[1];
	m.setViewWidth(m.layoutWidth);
	m.setCellWidth(cellPx / ratio);
	m.setRowHeight(rowPx / ratio);
	flush();
	m.notify(m.notice.text);
	m.dialog.shownFor = null;
	m.dialog.shownClose = false;
	const padPx = PixelRatio.getPixelSizeForLayoutSize(m.padding()) as int32;
	m.mouseGeometry = {
		cellWidth: cellPx,
		cellHeight: rowPx,
		width: widthPx + 2 * padPx,
		height: heightPx + 2 * padPx,
		padLeft: padPx,
		padTop: padPx,
		padRight: widthPx - cols * cellPx + padPx,
		padBottom: heightPx - rows * rowPx + padPx,
	};
	m.cursor.paintCursor();
	console.log(
		`haro: layout ${m.layoutWidth}x${m.layoutHeight} ratio ${ratio} ` +
			`cell ${cellPx}x${rowPx} px grid ${cols}x${rows}`
	);
	m.cols = cols;
	m.rows = rows;
	m.io.fit(cols, rows, cellPx, rowPx);
	m.view.fitRows(rows);
	m.refresh();
}
