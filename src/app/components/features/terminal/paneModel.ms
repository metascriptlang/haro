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
import { View, fitRows, hexOf, paint, repaintCursor } from "../../../frame";
import { FrameRows } from "../../../../controller/rows";
import { Stats, mark, noteApplied, noteKey } from "../../../stats";
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
import { PasteDialogModel, invalidate, showPending } from "../paste/pasteDialog";
import { Asks } from "../../../../controller/controls";
import { Exit, Failure, IoFrame, IoPort, Where, label, settingsOf } from "../../../../controller/io";
import { TermError, exitCodeText } from "../../../../controller/term";

const HOLD_RECHECK_MS = 100;
const AUTOSCROLL_MS = 15;
const RESTART_NOTICE = "config.ms: command and workingDirectory apply when Haro restarts";

export interface Desktop {
	setTitle: (title: string) => void;
	notify: (title: string, body: string) => void;
	openLink: (uri: string) => void;
	close: () => void;
	exited: (code: int32) => void;
}

export interface Report {
	note: (message: string) => void;
	fail: (message: string) => void;
}

export interface Timing {
	clock: () => float64;
	schedule: (run: () => void) => void;
}

export enum ConfigOutcome {
	Loaded,
	Refused,
}

export struct ConfigChange = match (outcome: ConfigOutcome) {
	ConfigOutcome.Loaded => { config: Config, family: string, error: string },
	ConfigOutcome.Refused => { error: string },
};

export interface HostEvents {
	onWake: (handler: () => void) => void;
	onCloseKey: (handler: () => void) => void;
	onConfig: (handler: (change: ConfigChange) => void) => void;
}

export interface AppHost {
	desktop: Desktop;
	report: Report;
	timing: Timing;
	events: HostEvents;
	fontFamily: string;
}

export interface PaneModel {
	io: IoPort;
	view: View;
	desktop: Desktop;
	report: Report;
	timing: Timing;
	stats: Stats;
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
	desktop: Desktop,
	report: Report,
	timing: Timing,
	fontFamily: string,
	started: Config,
	notice: NoticeModel,
	dialog: PasteDialogModel,
	stats: Stats,
): PaneModel {
	const [fontSize, setFontSize] = createSignal<number>(started.fontPx());
	const [fontFamily, setFontFamily] = createSignal<string>(fontFamily);
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
		desktop: desktop,
		report: report,
		timing: timing,
		stats: stats,
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

export function failed(this m: PaneModel, where: Where, error: string): void {
	m.failedAs(m.shellStarted, where, error);
}

function failureText(error: TermError): string {
	return match (error) {
		TermError.SettingsRefused => "the terminal refused the configured colours or scrollback",
		_ => error.toString(),
	};
}

function reported(this m: PaneModel, f: Failure): void {
	if (f.where == Where.Fit && f.error == TermError.PtyOpenFailed) {
		m.notify("the shell did not start: check command in config.ms, or --shell");
		return;
	}
	m.failedAs(f.started, f.where, failureText(f.error));
}

function failedAs(this m: PaneModel, started: boolean, where: Where, error: string): void {
	const message = `${where.label()}: ${error}`;
	if (!started) {
		m.report.fail(message);
		return;
	}
	const text = `Haro hit an internal error and kept the shell running. ${message}`;
	if (m.notice.text == text) { return; }
	m.report.note(message);
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
	for (const uri of asks.opens) { m.desktop.openLink(uri); }
	for (let i = 0; i < asks.reads; i++) {
		Clipboard.getString().then((text: string): void => {
			m.io.pasted(text);
			m.refresh();
		});
	}
	if (asks.close) { m.desktop.close(); }
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
	m.timing.schedule((): void => { m.refresh(); });
}

export function refresh(this m: PaneModel): void {
	m.stats.tally.refreshes += 1;
	m.io.frame((got: IoFrame): void => { m.applied(got); });
}

function applied(this m: PaneModel, got: IoFrame): void {
	m.shellStarted = got.started;
	for (const failure of got.failures) { m.reported(failure); }
	for (const launch of got.marks) { m.stats.mark(launch.name, launch.at); }
	if (got.keyAt >= 0) { m.stats.noteKey(got.keyAt); }
	const f = got.frame;
	if (f !== null) {
		const copied = f.copied;
		if (copied !== null) { copyToClipboard(copied); }
		const title = f.title;
		if (title !== null) { m.desktop.setTitle(title); }
		const notification = f.notification;
		if (notification !== null && !m.cursor.focused) {
			m.desktop.notify(notification.title, notification.body);
		}
		if (f.held) {
			m.stats.tally.held += 1;
			m.watchHold();
		} else {
			if (f.rows !== null) { m.painted(f.rows!); }
			const colors = f.colors;
			if (colors !== null) {
				m.setBackground(hexOf(colors.bg));
				m.setForeground(hexOf(colors.fg));
				m.cursor.tint = colors.cursor ?? colors.fg;
			}
			m.cursor.showCursor(f.cursor, f.look);
		}
	}
	m.dialog.showPending(got.pending, m.metrics.cellWidth(), m.viewWidth());
	m.answerAsks(got.asks);
	m.autoscrolling = got.autoscroll;
	m.autoscrollSoon();
	if (got.again) { m.scheduleRefresh(); }
	if (f !== null && f.more) {
		m.stats.tally.more += 1;
		m.scheduleRefresh();
	}
	const exit = got.exit;
	if (exit !== null) { m.shellEnded(exit); }
}

function painted(this m: PaneModel, rows: FrameRows): void {
	const chars = m.view.paint(rows);
	m.stats.noteApplied(rows.rows.length as int32, rows.scrolled, chars, m.timing.clock());
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
	m.desktop.exited(exit.code);
}

function notify(this m: PaneModel, text: string): void {
	const cols = noticeCols(m.viewWidth(), m.padding(), m.metrics.cellWidth());
	m.notice.showNotice(text, cols);
}

function restartNeeded(now: Config, started: Config): boolean {
	return now.command != started.command ||
		now.workingDirectory != started.workingDirectory;
}

function reconfigure(this m: PaneModel, change: ConfigChange): void {
	if (change.outcome === ConfigOutcome.Refused) {
		m.notify(`config.ms: ${change.error}`);
		return;
	}
	const c = change.config;
	const family = change.family;
	const error = change.error;
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

export function connectHost(this m: PaneModel, events: HostEvents): void {
	events.onConfig((change: ConfigChange): void => { m.reconfigure(change); });
	events.onCloseKey((): void => { m.closeKeyPressed(); });
	events.onWake((): void => {
		m.io.drain();
		m.timing.schedule((): void => { m.woke(); });
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
		m.failed(Where.Font, `family "${m.metrics.fontFamily()}" has no face: ${font.error.toString()}`);
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
		m.failed(Where.Fit, `cell ${cellPx}x${rowPx} px is not a grid size`);
		return;
	}
	const cols = size.value[0];
	const rows = size.value[1];
	m.setViewWidth(m.layoutWidth);
	m.setCellWidth(cellPx / ratio);
	m.setRowHeight(rowPx / ratio);
	flush();
	m.notify(m.notice.text);
	m.dialog.invalidate();
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
