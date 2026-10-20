import { Accessor, Setter, createSignal } from "../../../../../../neon/src/core/signal";
import { NeonEvent } from "../../../../../../neon/src/render/event";
import { PixelRatio } from "../../../../../../neon/src/api/pixelRatio";
import { Clipboard } from "../../../../../../neon/src/api/clipboard";
import { ViewHandle } from "../../../../../../neon/src/components/primitives";
import { gridSize } from "../../../../grid/size";
import { MouseGeometry } from "../../../../vt/vt";
import { Config, fontPx } from "../../../../config/config";
import { hexOf } from "../../../frame";
import { stats } from "../../../stats";
import { CellMetrics } from "../../ui/cellText";
import {
	CursorModel,
	createCursor,
	paintCursor,
	showCursor,
	wakeCursor,
} from "../../content/cursor";
import { ShadesModel, createShades, paintShades } from "../../content/shades";
import { PreeditModel, createPreedit } from "../../content/preedit";
import { NoticeModel, noticeCols, showNotice } from "../notice/notice";
import { PasteDialogModel, showPending } from "../paste/pasteDialog";
import { Bridge, Controls } from "./controls";
import { clipboardAsked } from "./clipboard";
import { closeKey } from "./keyboard";
import { shades } from "./mouse";
import { Term, TermError, fit, pumpFrame, shellExitCode } from "./term";

const PROBE = "MMMMMMMMMM";
const HOLD_RECHECK_MS = 100;
const RESTART_NOTICE =
	"config.ms: fontFamily, fontSize, command and workingDirectory apply when Haro restarts";

export interface AppHost {
	onWake: (handler: () => void) => void;
	schedule: (run: () => void) => void;
	exited: (code: int32) => void;
	fail: (message: string) => void;
	openLink: (uri: string) => void;
	close: () => void;
	onCloseKey: (handler: () => void) => void;
	onConfig: (handler: (c: Config | null, error: string) => void) => void;
}

export interface PaneModel {
	term: Term;
	host: AppHost;
	started: Config;
	settings: Config;
	settingsApplied: boolean;
	controls: Controls;
	notice: NoticeModel;
	dialog: PasteDialogModel;
	metrics: CellMetrics;
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
	shades: ShadesModel;
	preedit: PreeditModel;
	grid: ViewHandle | null;
	holdTimer: number;
	scrollTimer: number;
	mouseGeometry: MouseGeometry;
}

export function createPane(
	t: Term,
	host: AppHost,
	started: Config,
	notice: NoticeModel,
	dialog: PasteDialogModel,
): PaneModel {
	const [cellWidth, setCellWidth] = createSignal<number>(0);
	const [rowHeight, setRowHeight] = createSignal<number>(0);
	const [background, setBackground] = createSignal<string>(hexOf(started.background));
	const [foreground, setForeground] = createSignal<string>(hexOf(started.foreground));
	const [padding, setPadding] = createSignal<number>(started.padding);
	const [viewWidth, setViewWidth] = createSignal<number>(0);
	const metrics: CellMetrics = {
		fontSize: started.fontPx(),
		cellWidth: cellWidth,
		rowHeight: rowHeight,
	};
	const controls = Controls.open();
	controls.keybinds = started.keybinds;
	return {
		term: t,
		host: host,
		started: started,
		settings: started,
		settingsApplied: false,
		controls: controls,
		notice: notice,
		dialog: dialog,
		metrics: metrics,
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
		cursor: createCursor(metrics),
		shades: createShades(),
		preedit: createPreedit(),
		grid: null,
		holdTimer: -1,
		scrollTimer: -1,
		mouseGeometry: { cellWidth: 1, cellHeight: 1, width: 1, height: 1 },
	};
}

export function failed(this m: PaneModel, what: string, error: string): void {
	m.host.fail(`${what}: ${error}`);
}

export function paintSelection(this m: PaneModel): void {
	const drawn = m.controls.shades(m.term);
	if (!drawn.ok) {
		m.failed("selection", drawn.error.toString());
		return;
	}
	m.shades.paintShades(drawn.value);
}

function copyToClipboard(text: string): void {
	try {
		Clipboard.setString(text);
	} catch (e) {
		console.log(`haro: copy failed: ${e}`);
	}
}

export function bridge(this m: PaneModel): Bridge {
	return {
		write: copyToClipboard,
		read: (done: (text: string) => void): void => {
			Clipboard.getString().then((text: string): void => {
				done(text);
				m.refresh();
			});
		},
		open: m.host.openLink,
		close: m.host.close,
	};
}

function watchHold(this m: PaneModel): void {
	if (m.holdTimer >= 0) { return; }
	m.holdTimer = setTimeout((): void => {
		m.holdTimer = -1;
		m.refresh();
	}, HOLD_RECHECK_MS);
}

export function scheduleRefresh(this m: PaneModel): void {
	m.host.schedule((): void => { m.refresh(); });
}

export function refresh(this m: PaneModel): void {
	stats.refreshes += 1;
	const frame = m.term.pumpFrame();
	if (!frame.ok) {
		m.failed("frame", frame.error.toString());
		return;
	}
	const f = frame.value;
	const copied = f.copied;
	if (copied !== null) { copyToClipboard(copied); }
	if (f.asked) { m.controls.clipboardAsked(m.term, m.bridge()); }
	if (f.held) {
		m.watchHold();
	} else {
		const colors = f.colors;
		if (colors !== null) {
			const bg = hexOf(colors.bg);
			const fg = hexOf(colors.fg);
			if (bg != m.background()) { m.setBackground(bg); }
			if (fg != m.foreground()) { m.setForeground(fg); }
		}
		m.cursor.showCursor(f.cursor, f.look);
		m.paintSelection();
	}
	m.dialog.showPending(
		m.controls.held,
		m.controls.reading,
		m.metrics.cellWidth(),
		m.viewWidth(),
	);
	if (f.more) {
		stats.more += 1;
		m.scheduleRefresh();
	}
	if (f.ended) { m.host.exited(m.term.shellExitCode()); }
}

function notify(this m: PaneModel, text: string): void {
	const cols = noticeCols(m.viewWidth(), m.padding(), m.metrics.cellWidth());
	m.notice.showNotice(text, cols);
}

function restartNeeded(now: Config, started: Config): boolean {
	return now.fontFamily.join("\n") != started.fontFamily.join("\n") ||
		now.fontSize != started.fontSize ||
		now.command != started.command ||
		now.workingDirectory != started.workingDirectory;
}

function applySettings(this m: PaneModel): boolean {
	const s = m.term.session;
	if (s === null) { return true; }
	const vt = s.vt;
	const settings = m.settings;
	if (!vt.setDefaultColors(settings.foreground, settings.background).ok ||
		!vt.setPalette(settings.palette).ok ||
		!vt.setScrollback(settings.scrollback).ok) {
		m.host.fail("the terminal refused the configured colours or scrollback");
		return false;
	}
	return true;
}

function reconfigure(this m: PaneModel, c: Config | null, error: string): void {
	if (c === null) {
		m.notify(`config.ms: ${error}`);
		return;
	}
	m.settings = c;
	m.controls.keybinds = c.keybinds;
	m.setPadding(c.padding);
	m.notify(restartNeeded(c, m.started) ? RESTART_NOTICE : "");
	if (m.settingsApplied && m.applySettings()) { m.refresh(); }
}

function closeKeyPressed(this m: PaneModel): void {
	const done = m.controls.closeKey(m.term, m.bridge());
	if (!done.ok) {
		m.failed("close key", done.error.toString());
		return;
	}
	m.refresh();
}

function woke(this m: PaneModel): void {
	m.cursor.wakeCursor(Date.now() as float64);
	m.refresh();
}

export function connectHost(this m: PaneModel): void {
	m.host.onConfig((c: Config | null, error: string): void => { m.reconfigure(c, error); });
	m.host.onCloseKey((): void => { m.closeKeyPressed(); });
	m.host.onWake((): void => { m.woke(); });
}

export function laidOut(this m: PaneModel, e: NeonEvent): void {
	if (e.width <= 0 || e.height <= 0) { return; }
	const handle = m.grid;
	if (handle === null) {
		m.host.fail("the grid laid out before its handle arrived");
		return;
	}
	const probe = handle.measureText(PROBE, { fontSize: m.metrics.fontSize });
	const advance = probe.width / PROBE.length;
	const lineHeight = probe.height;
	const ratio = PixelRatio.get();
	const cellPx = Math.ceil(advance * ratio) as int32;
	const rowPx = Math.ceil(lineHeight * ratio) as int32;
	const widthPx = PixelRatio.getPixelSizeForLayoutSize(e.width) as int32;
	const heightPx = PixelRatio.getPixelSizeForLayoutSize(e.height) as int32;
	const size = gridSize(widthPx, heightPx, cellPx, rowPx);
	if (!size.ok) {
		m.host.fail(`cell ${advance}x${lineHeight} is not a grid size`);
		return;
	}
	const cols = size.value[0];
	const rows = size.value[1];
	m.setViewWidth(e.width);
	m.notify(m.notice.text);
	m.dialog.shownFor = null;
	m.mouseGeometry = {
		cellWidth: cellPx,
		cellHeight: rowPx,
		width: cols * cellPx,
		height: rows * rowPx,
	};
	m.setCellWidth(cellPx / ratio);
	m.setRowHeight(rowPx / ratio);
	m.cursor.paintCursor();
	console.log(
		`haro: layout ${e.width}x${e.height} ratio ${ratio} ` +
			`cell ${advance}x${lineHeight} grid ${cols}x${rows}`
	);
	const fitted = m.term.fit(cols, rows);
	if (!fitted.ok) {
		if (fitted.error == TermError.PtyOpenFailed) {
			m.notify("the shell did not start: check command in config.ms, or --shell");
		} else {
			m.failed("fit", fitted.error.toString());
		}
		return;
	}
	if (!m.settingsApplied) {
		m.settingsApplied = true;
		if (!m.applySettings()) { return; }
	}
	if (fitted.value) { m.refresh(); }
}
