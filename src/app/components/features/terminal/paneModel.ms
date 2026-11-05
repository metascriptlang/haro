import { Accessor, Setter, createSignal } from "../../../../../../neon/src/core/signal";
import { flush } from "../../../../../../neon/src/core/runtime";
import { NeonEvent } from "../../../../../../neon/src/render/event";
import { Clipboard } from "../../../../../../neon/src/api/clipboard";
import { ViewHandle } from "../../../../../../neon/src/components/primitives";
import { CellInk, RowNote, RowTint } from "../../../../grid/lines";
import { CommandDone, MouseGeometry, ShellMark, ShellStep, geometryOf } from "../../../../vt/vt";
import { Config } from "../../../../config/config";
import { HookPane, KeyAnswer } from "../../../../config/hooks";
import { KeyEvent } from "../../../../keys/keys";
import { Action, actionNamed } from "../../../../input/bindings";
import { View, fitRows, hexOf, paint, repaintCursor } from "../../../frame";
import { FrameRows } from "../../../../controller/rows";
import { Stats, mark, noteApplied, noteKey } from "../../../stats";
import { CellMetrics } from "../../ui/cellText";
import {
	CursorModel,
	open,
	paintCursor,
	showCursor,
	wakeCursor,
} from "../../content/cursor";
import { PreeditModel, open } from "../../content/preedit";
import { NoticeModel, noticeCols, showNotice } from "../notice/notice";
import { PasteDialogModel, invalidate, showPending } from "../paste/pasteDialog";
import { Asks } from "../../../../controller/controls";
import {
	Exit,
	Failure,
	IoFrame,
	IoPort,
	Where,
	label,
	settingsOf,
} from "../../../../controller/io";
import { TermError, exitCodeText } from "../../../../controller/term";

const HOLD_RECHECK_MS = 100;
const AUTOSCROLL_MS = 15;
const RESIZE_SETTLE_MS = 25;
const RESTART_NOTICE = "config.ms: command, workingDirectory and shellIntegration apply when Haro restarts";

export interface Desktop {
	setTitle: (title: string, belled: boolean) => void;
	notify: (title: string, body: string) => void;
	openLink: (uri: string) => void;
	attention: () => void;
	setHand: (on: boolean) => void;
	openConfig: () => void;
	reloadConfig: () => void;
	close: () => void;
	exited: (code: int32) => void;
	windowAction: (action: Action) => void;
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

export interface KeyHook {
	answer: (pane: HookPane, k: KeyEvent) => Result<KeyAnswer, string>;
}

export interface ShellHook {
	prompted: (pane: HookPane, at: int32) => Result<void, string>;
	commandDone: (pane: HookPane, done: CommandDone) => Result<void, string>;
}

export interface HostEvents {
	onWake: (handler: () => void) => void;
	onMenu: (handler: (id: string) => void) => void;
	onCloseRequest: (handler: () => void) => void;
	onConfig: (handler: (change: ConfigChange) => void) => void;
}

export interface PaneModel {
	io: IoPort;
	view: View;
	desktop: Desktop;
	report: Report;
	timing: Timing;
	keyHook: KeyHook;
	shellHook: ShellHook;
	stats: Stats;
	started: Config;
	title: string;
	belled: boolean;
	shellStarted: boolean;
	ended: Exit | null;
	autoscrolling: boolean;
	cols: int32;
	rows: int32;
	notice: NoticeModel;
	dialog: PasteDialogModel;
	metrics: CellMetrics;
	left: Accessor<number>;
	setLeft: Setter<number>;
	top: Accessor<number>;
	setTop: Setter<number>;
	background: Accessor<string>;
	setBackground: Setter<string>;
	foreground: Accessor<string>;
	setForeground: Setter<string>;
	cursor: CursorModel;
	preedit: PreeditModel;
	grid: ViewHandle | null;
	holdTimer: number | null;
	scrollTimer: number | null;
	compressTimer: number | null;
	sizeTimer: number | null;
	decorations: int32;
	mouseGeometry: MouseGeometry;
	layoutWidth: number;
	layoutHeight: number;
}

export function open(
	this typeof PaneModel,
	io: IoPort,
	view: View,
	desktop: Desktop,
	report: Report,
	timing: Timing,
	keyHook: KeyHook,
	shellHook: ShellHook,
	metrics: CellMetrics,
	started: Config,
	notice: NoticeModel,
	dialog: PasteDialogModel,
	stats: Stats,
): PaneModel {
	const [left, setLeft] = createSignal<number>(0);
	const [top, setTop] = createSignal<number>(0);
	const [background, setBackground] = createSignal<string>(started.background.hexOf());
	const [foreground, setForeground] = createSignal<string>(started.foreground.hexOf());
	io.configure(started.settingsOf());
	const pane: PaneModel = {
		io: io,
		view: view,
		desktop: desktop,
		report: report,
		timing: timing,
		keyHook: keyHook,
		shellHook: shellHook,
		stats: stats,
		started: started,
		title: "",
		belled: false,
		shellStarted: false,
		ended: null,
		autoscrolling: false,
		cols: 0,
		rows: 0,
		notice: notice,
		dialog: dialog,
		metrics: metrics,
		left: left,
		setLeft: setLeft,
		top: top,
		setTop: setTop,
		background: background,
		setBackground: setBackground,
		foreground: foreground,
		setForeground: setForeground,
		cursor: CursorModel.open(
			metrics,
			left,
			top,
			started.foreground,
			(ink: CellInk | null): void => {
				io.relight(
					ink,
					(rows: FrameRows): void => { view.repaintCursor(rows); },
					(error: string): void => { report.note(`cursor: ${error}`); },
				);
			},
		),
		preedit: PreeditModel.open(),
		grid: null,
		holdTimer: null,
		scrollTimer: null,
		compressTimer: null,
		sizeTimer: null,
		decorations: 0,
		mouseGeometry: geometryOf(1, 1, 1, 1),
		layoutWidth: 0,
		layoutHeight: 0,
	};
	pane.cursor.useEffects(started.cursor);
	return pane;
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

function ptyRefusal(error: TermError): string | null {
	return match (error) {
		TermError.PtyOpenFailed => "the terminal could not be opened",
		TermError.PtyOpenTableFull => "too many terminals are open",
		TermError.PtyOpenBlankCommand => "the command is blank",
		TermError.PtyOpenBadEnv => "the environment is malformed",
		TermError.PtyOpenForkFailed => "the process could not be forked",
		TermError.PtyOpenExecFailed => "the command could not be run",
		TermError.PtyOpenThreadFailed => "the terminal's reader thread could not start",
		_ => null,
	};
}

function reported(this m: PaneModel, f: Failure): void {
	const error = f.error;
	const refusal = f.where == Where.Fit ? ptyRefusal(error) : null;
	if (refusal !== null) {
		m.notify(`the shell did not start (${refusal}): check command in config.ms, or --shell`);
		return;
	}
	match (error) {
		TermError.InputBacklogged => {
			m.notify("the program has not read the last 16 MB sent to it, so this input was dropped");
		},
		_ => { m.failedAs(f.started, f.where, failureText(error)); },
	}
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

function copyToClipboard(this m: PaneModel, text: string): void {
	try {
		Clipboard.setString(text);
	} catch (e) {
		m.report.note(`copy failed: ${e}`);
		m.notify(`Haro could not copy to the clipboard: ${e}`);
	}
}

function answerAsks(this m: PaneModel, asks: Asks): void {
	const copy = asks.copy;
	if (copy !== null) { m.copyToClipboard(copy); }
	for (const uri of asks.opens) { m.desktop.openLink(uri); }
	for (let i = 0; i < asks.reads; i++) {
		Clipboard.getString().then((text: string): void => {
			m.io.pasted(text);
			m.refresh();
		}).catch((e: Error): void => {
			m.report.note(`paste failed: ${e}`);
			m.notify(`Haro could not read the clipboard: ${e}`);
		});
	}
	for (const action of asks.actions) { m.hosted(action); }
	if (asks.close) { m.desktop.close(); }
}

export function hosted(this m: PaneModel, action: Action): void {
	match (action) {
		Action.OpenConfig => { m.desktop.openConfig(); },
		Action.ReloadConfig => { m.desktop.reloadConfig(); },
		Action.IncreaseFontSize |
		Action.DecreaseFontSize |
		Action.ResetFontSize |
		Action.SplitRight |
		Action.SplitDown |
		Action.ClosePane |
		Action.FocusPaneLeft |
		Action.FocusPaneRight |
		Action.FocusPaneUp |
		Action.FocusPaneDown |
		Action.FocusPanePrevious |
		Action.FocusPaneNext |
		Action.ResizePaneLeft |
		Action.ResizePaneRight |
		Action.ResizePaneUp |
		Action.ResizePaneDown |
		Action.TogglePaneZoom |
		Action.NewTab |
		Action.CloseTab |
		Action.PreviousTab |
		Action.NextTab |
		Action.GotoTab1 |
		Action.GotoTab2 |
		Action.GotoTab3 |
		Action.GotoTab4 |
		Action.GotoTab5 |
		Action.GotoTab6 |
		Action.GotoTab7 |
		Action.GotoTab8 |
		Action.GotoTab9 |
		Action.MoveTabLeft |
		Action.MoveTabRight |
		Action.RenameTab |
		Action.ToggleSidebar |
		Action.NewTabOnHost |
		Action.AddRemoteHost |
		Action.RemoveRemoteHost => { m.desktop.windowAction(action); },
		_ => { m.failed(Where.Key, `the window does not run ${action.toString()}`); },
	}
}

function watchHold(this m: PaneModel): void {
	if (m.holdTimer !== null) { return; }
	m.holdTimer = setTimeout((): void => {
		m.holdTimer = null;
		m.refresh();
	}, HOLD_RECHECK_MS);
}

function autoscrollSoon(this m: PaneModel): void {
	if (m.scrollTimer !== null || !m.autoscrolling) { return; }
	m.scrollTimer = setTimeout((): void => {
		m.scrollTimer = null;
		m.io.autoscroll();
		m.refresh();
	}, AUTOSCROLL_MS);
}

function compressAfter(this m: PaneModel, delayMs: number): void {
	const pending = m.compressTimer;
	if (pending !== null) { clearTimeout(pending); }
	m.compressTimer = setTimeout((): void => {
		m.compressTimer = null;
		m.io.compress(
			(nextMs: number | null): void => {
				if (nextMs !== null) { m.compressAfter(nextMs); }
			},
			(error: string): void => { m.failed(Where.Output, error); },
		);
	}, delayMs);
}

function settleSizeSoon(this m: PaneModel): void {
	if (m.sizeTimer !== null) { return; }
	m.sizeTimer = setTimeout((): void => {
		m.sizeTimer = null;
		m.io.settleSize();
	}, RESIZE_SETTLE_MS);
}

export function scheduleRefresh(this m: PaneModel): void {
	m.timing.schedule((): void => { m.refresh(); });
}

export function refresh(this m: PaneModel): void {
	m.stats.tally.refreshes += 1;
	m.io.frame(
		(got: IoFrame): void => { m.applied(got); },
		(error: string): void => { m.failed(Where.Output, error); },
	);
}

function applied(this m: PaneModel, got: IoFrame): void {
	m.shellStarted = got.started;
	for (const failure of got.failures) { m.reported(failure); }
	for (const launch of got.marks) { m.stats.mark(launch.name, launch.at); }
	if (got.keyAt >= 0) { m.stats.noteKey(got.keyAt); }
	const f = got.frame;
	if (f !== null) {
		const copied = f.copied;
		if (copied !== null) { m.copyToClipboard(copied); }
		if (m.belled && m.cursor.focused) {
			m.belled = false;
			m.retitle();
		}
		const title = f.title;
		if (title !== null) {
			m.title = title;
			m.retitle();
		}
		if (!m.cursor.focused) {
			for (const n of f.notifications) { m.desktop.notify(n.title, n.body); }
		}
		if (f.bells > 0 && !m.cursor.focused) {
			m.belled = true;
			m.retitle();
			m.desktop.attention();
		}
		for (const mark of f.shell) { m.marked(mark); }
		if (f.held) {
			m.stats.tally.held += 1;
			m.watchHold();
		} else {
			if (f.rows !== null) { m.painted(f.rows!); }
			const colors = f.colors;
			if (colors !== null) {
				m.setBackground(colors.bg.hexOf());
				m.setForeground(colors.fg.hexOf());
				m.cursor.tint = colors.cursor ?? colors.fg;
			}
			m.cursor.showCursor(f.cursor, f.look);
		}
	}
	if (got.hoverChanged) {
		m.view.showHover(got.hover);
		m.desktop.setHand(got.hover !== null);
	}
	m.dialog.showPending(got.pending, m.metrics.cellWidth(), m.layoutWidth);
	m.answerAsks(got.asks);
	m.autoscrolling = got.autoscroll;
	m.autoscrollSoon();
	const compressAfterMs = got.compressAfterMs;
	if (compressAfterMs !== null) { m.compressAfter(compressAfterMs); }
	if (got.again) { m.scheduleRefresh(); }
	if (f?.more ?? false) {
		m.stats.tally.more += 1;
		m.scheduleRefresh();
	}
	const exit = got.exit;
	if (exit !== null) { m.shellEnded(exit); }
}

function retitle(this m: PaneModel): void {
	m.desktop.setTitle(m.title, m.belled);
}

function marked(this m: PaneModel, mark: ShellMark): void {
	const ran = mark.step === ShellStep.CommandDone
		? m.shellHook.commandDone(m.hookPane(), mark.done)
		: m.shellHook.prompted(m.hookPane(), mark.at);
	if (!ran.ok) { m.notify(ran.error); }
}

export function hookPane(this m: PaneModel): HookPane {
	return {
		send: (text: string): void => { m.io.text(text, m.timing.clock()); },
		notify: (title: string, body: string): void => { m.desktop.notify(title, body); },
		decorate: (from: int32, to: int32, tint: RowTint): int32 => {
			m.decorations += 1;
			const id = m.decorations;
			m.io.decorate({ id: id, from: from, to: to, tint: tint });
			m.scheduleRefresh();
			return id;
		},
		undecorate: (id: int32): void => {
			m.io.undecorate(id);
			m.scheduleRefresh();
		},
		annotate: (at: int32, note: RowNote): int32 => {
			m.decorations += 1;
			const id = m.decorations;
			m.io.annotate({ id: id, at: at, note: note });
			m.scheduleRefresh();
			return id;
		},
		unannotate: (id: int32): void => {
			m.io.unannotate(id);
			m.scheduleRefresh();
		},
	};
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

export function notify(this m: PaneModel, text: string): void {
	const cols = noticeCols(m.layoutWidth, 0, m.metrics.cellWidth());
	m.notice.showNotice(text, cols);
}

function restartNeeded(now: Config, started: Config): boolean {
	return now.command != started.command ||
		now.workingDirectory != started.workingDirectory ||
		now.shellIntegration != started.shellIntegration;
}

function reconfigure(this m: PaneModel, change: ConfigChange): void {
	if (change.outcome === ConfigOutcome.Refused) {
		m.notify(`config.ms: ${change.error}`);
		return;
	}
	const c = change.config;
	const error = change.error;
	m.io.configure(c.settingsOf());
	m.cursor.useEffects(c.cursor);
	const restart = restartNeeded(c, m.started) ? RESTART_NOTICE : "";
	m.notify(error != "" ? `config.ms: ${error}` : restart);
	m.refresh();
}

function closeKeyPressed(this m: PaneModel): void {
	m.io.closeKey();
	m.refresh();
}

function menuClicked(this m: PaneModel, id: string): void {
	const action = actionNamed(id);
	if (action === null) {
		m.failed(Where.Key, `the menu item "${id}" names no action`);
		return;
	}
	if (action == Action.ClosePane) {
		m.closeKeyPressed();
		return;
	}
	if (action == Action.CloseWindow) {
		m.desktop.close();
		return;
	}
	match (action) {
		Action.IncreaseFontSize |
		Action.DecreaseFontSize |
		Action.ResetFontSize |
		Action.OpenConfig |
		Action.ReloadConfig => { m.hosted(action); },
		_ => { m.io.act(action); },
	}
	m.refresh();
}

export function closeRequested(this m: PaneModel): void {
	m.io.closeWindow();
	m.refresh();
}

function woke(this m: PaneModel): void {
	m.cursor.wakeCursor(Date.now() as float64);
	m.refresh();
}

export function connectHost(this m: PaneModel, events: HostEvents): void {
	events.onConfig((change: ConfigChange): void => { m.reconfigure(change); });
	events.onMenu((id: string): void => { m.menuClicked(id); });
	events.onCloseRequest((): void => { m.closeRequested(); });
	events.onWake((): void => {
		m.io.drain();
		m.timing.schedule((): void => { m.woke(); });
	});
}

export function laidOut(this m: PaneModel, e: NeonEvent): void {
	if (e.width <= 0 || e.height <= 0) { return; }
	m.layoutWidth = e.width;
	m.layoutHeight = e.height;
	m.notify(m.notice.text);
	m.dialog.invalidate();
	m.refresh();
}

export function placeAt(this m: PaneModel, left: number, top: number): void {
	if (left == m.left() && top == m.top()) { return; }
	m.setLeft(left);
	m.setTop(top);
	flush();
	m.cursor.paintCursor();
}

export function fitGrid(
	this m: PaneModel,
	cols: int32,
	rows: int32,
	cellPx: int32,
	rowPx: int32,
): void {
	m.mouseGeometry = {
		cellWidth: cellPx,
		cellHeight: rowPx,
		width: cols * cellPx,
		height: rows * rowPx,
		padLeft: 0,
		padTop: 0,
		padRight: 0,
		padBottom: 0,
	};
	m.cursor.paintCursor();
	m.cols = cols;
	m.rows = rows;
	m.io.fit(cols, rows, cellPx, rowPx);
	m.settleSizeSoon();
	m.view.fitRows(rows);
	m.refresh();
}
