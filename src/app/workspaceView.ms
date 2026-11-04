import { Accessor, Setter, createSignal } from "../../../neon/src/core/signal";
import { flush } from "../../../neon/src/core/runtime";
import { NeonEvent } from "../../../neon/src/render/event";
import { PixelRatio } from "../../../neon/src/api/pixelRatio";
import { homeDir } from "std/os";
import {
	Config,
	DividerStyle as ConfigDivider,
	PaneCwd,
	PaneTitle,
	SidebarSide,
} from "../config/config";
import { Action } from "../input/bindings";
import { Rgb } from "../vt/vt";
import { gridSize } from "../grid/size";
import { TermError } from "../controller/term";
import { closed } from "../controller/shell";
import { Axis, Pane, PaneId, TabId, panes } from "../workspace/tree";
import { Message, MessageKind } from "../server/protocol";
import { Attached, ServerLink } from "../client/link";
import { Layout, screenParts } from "../client/wire";
import {
	CommandKind,
	Direction,
	EventKind,
	Workspace,
	WorkspaceCommand,
	WorkspaceError,
	WorkspaceEvent,
	activeTab,
	apply,
	create,
	focusedPane,
	layout,
} from "../workspace/workspace";
import { hexOf } from "./frame";
import { Stats } from "./stats";
import { CellFont, measured, open, reconfigured, stepped } from "./cellFont";
import {
	NewPaneCwd,
	PaneHost,
	PaneLaunch,
	Panes,
	RunningPane,
	apply as applyEvent,
	foregroundIsShell,
	open,
	paneOf,
	refit,
	reportedCwd,
} from "./panes";
import {
	ConfigChange,
	ConfigOutcome,
	Desktop,
	HostEvents,
	KeyHook,
	PaneModel,
	Report,
	ShellHook,
	Timing,
	notify,
	placeAt,
} from "./components/features/terminal/paneModel";
import {
	DividerStyle,
	FrameLayout,
	frameOf,
	paneBox,
} from "./components/features/workspace/frameLayout";
import {
	DEFAULT_FRAME_LOOK,
	FrameLook,
} from "./components/features/workspace/paneFrame";
import { SidebarPane, SidebarTab } from "./components/features/sidebar/sidebar";
import {
	CloseAsk,
	Closing,
	ConfirmModel,
	ask,
	closeNeedsConfirm,
	dismiss,
	open,
} from "./components/features/confirm/confirmClose";

const START_COLS: int32 = 80;
const START_ROWS: int32 = 24;
const DIVIDER_GREY = 239;
const FOCUS_BLUE = 74;
const BRIGHT_BLACK = 8;
const DIM_FALLBACK = "#7a7a7a";

export interface WindowHost {
	setTitle: (title: string, belled: boolean) => void;
	notify: (title: string, body: string) => void;
	openLink: (uri: string) => void;
	attention: () => void;
	setHand: (on: boolean) => void;
	openConfig: () => void;
	reloadConfig: () => void;
	quit: () => void;
	report: Report;
	timing: Timing;
	keyHook: KeyHook;
	shellHook: ShellHook;
	events: HostEvents;
	stats: Stats;
	fontFamily: string;
}

export struct Chrome {
	background: string;
	foreground: string;
	accent: string;
	dim: string;
	sidebarCols: int32;
	sidebarLeft: boolean;
}

interface PaneHooks {
	id: PaneId;
	wake: (() => void) | null;
	menu: ((id: string) => void) | null;
	closeRequest: (() => void) | null;
	config: ((change: ConfigChange) => void) | null;
}

struct KnownCwd {
	id: PaneId;
	cwd: string;
}

export interface WorkspaceView {
	host: WindowHost;
	config: Config;
	w: Workspace;
	panes: Panes;
	font: CellFont;
	confirm: ConfirmModel;
	layout: Accessor<FrameLayout>;
	setLayout: Setter<FrameLayout>;
	tabs: Accessor<SidebarTab[]>;
	setTabs: Setter<SidebarTab[]>;
	sidebarShown: Accessor<boolean>;
	setSidebarShown: Setter<boolean>;
	look: Accessor<FrameLook>;
	setLook: Setter<FrameLook>;
	chrome: Accessor<Chrome>;
	setChrome: Setter<Chrome>;
	inset: Accessor<number>;
	setInset: Setter<number>;
	areaWidth: number;
	areaHeight: number;
	cols: int32;
	rows: int32;
	queue: WorkspaceCommand[];
	draining: boolean;
	refitAll: boolean;
	hooks: PaneHooks[];
	cwds: KnownCwd[];
	closing: WorkspaceCommand | null;
	keepsEnded: boolean;
	quitting: boolean;
	started: (first: RunningPane) => void;
	link: ServerLink | null;
	attached: Attached | null;
	inbox: Message[];
	receiving: boolean;
}

function paletteHex(c: Config, index: int32, fallback: string): string {
	return index < c.palette.length ? c.palette[index].hexOf() : fallback;
}

function colourOr(
	given: Rgb | null,
	c: Config,
	index: int32,
	fallback: string,
): string {
	return given !== null ? given.hexOf() : paletteHex(c, index, fallback);
}

export function lookOf(c: Config): FrameLook {
	return {
		style: match (c.dividerStyle) {
			ConfigDivider.Cell => DividerStyle.Cell,
			ConfigDivider.Line => DividerStyle.Line,
		},
		gapPixels: c.paneGap,
		divider: colourOr(
			c.dividerColor,
			c,
			DIVIDER_GREY,
			DEFAULT_FRAME_LOOK.divider,
		),
		focusedDivider: colourOr(
			c.focusedDividerColor,
			c,
			FOCUS_BLUE,
			DEFAULT_FRAME_LOOK.focusedDivider,
		),
	};
}

export function dividerCellsOf(c: Config): int32 {
	return match (c.dividerStyle) {
		ConfigDivider.Cell => 1,
		ConfigDivider.Line => 0,
	};
}

function chromeOf(c: Config): Chrome {
	const look = lookOf(c);
	return {
		background: c.background.hexOf(),
		foreground: c.foreground.hexOf(),
		accent: look.focusedDivider,
		dim: paletteHex(c, BRIGHT_BLACK, DIM_FALLBACK),
		sidebarCols: c.sidebarWidth as int32,
		sidebarLeft: c.sidebarPosition == SidebarSide.Left,
	};
}

function newPaneCwdOf(c: Config): NewPaneCwd {
	return match (c.newPaneCwd) {
		PaneCwd.Focused => NewPaneCwd.Origin,
		PaneCwd.Start => NewPaneCwd.Start,
	};
}

function emptyFrame(divider: int32): FrameLayout {
	return {
		cols: START_COLS,
		rows: START_ROWS,
		divider: divider,
		focused: 0 as PaneId,
		panes: [],
		lines: [],
		segments: [],
		titles: [],
	};
}

export function open(
	this typeof WorkspaceView,
	host: WindowHost,
	started: Config,
	command: string,
	shellScripts: string | null,
	startIn: string | null,
	recording: string | null,
	link: ServerLink | null = null,
	attached: Attached | null = null,
): WorkspaceView {
	const divider = dividerCellsOf(started);
	const created = Workspace.create(divider);
	if (!created.ok) {
		throw new Error(`workspace: ${created.error.toString()}`);
	}
	const font = CellFont.open(started, host.fontFamily);
	const [layout, setLayout] = createSignal<FrameLayout>(emptyFrame(divider));
	const [tabs, setTabs] = createSignal<SidebarTab[]>([]);
	const [shown, setShown] = createSignal<boolean>(started.sidebarVisible);
	const [look, setLook] = createSignal<FrameLook>(lookOf(started));
	const [chrome, setChrome] = createSignal<Chrome>(chromeOf(started));
	const [inset, setInset] = createSignal<number>(started.padding);
	const launch: PaneLaunch = {
		command: command,
		shellScripts: shellScripts,
		startIn: startIn,
		cwd: newPaneCwdOf(started),
		recording: recording,
	};
	const paneHost: PaneHost = {
		desktopFor: unwiredDesktop,
		eventsFor: unwiredEvents,
		report: host.report,
		timing: host.timing,
		keyHook: host.keyHook,
		shellHook: host.shellHook,
		metrics: font.metrics,
		started: started,
		stats: host.stats,
	};
	const v: WorkspaceView = {
		host: host,
		config: started,
		w: created.value,
		panes: Panes.open(launch, paneHost, 0, 0),
		font: font,
		confirm: ConfirmModel.open(),
		layout: layout,
		setLayout: setLayout,
		tabs: tabs,
		setTabs: setTabs,
		sidebarShown: shown,
		setSidebarShown: setShown,
		look: look,
		setLook: setLook,
		chrome: chrome,
		setChrome: setChrome,
		inset: inset,
		setInset: setInset,
		areaWidth: 0,
		areaHeight: 0,
		cols: START_COLS,
		rows: START_ROWS,
		queue: [],
		draining: false,
		refitAll: false,
		hooks: [],
		cwds: [],
		closing: null,
		keepsEnded: recording !== null,
		quitting: false,
		started: (first: RunningPane): void => {},
		link: link,
		attached: attached,
		inbox: [],
		receiving: false,
	};
	paneHost.desktopFor = (id: PaneId): Desktop => v.desktopFor(id);
	paneHost.eventsFor = (id: PaneId): HostEvents => v.eventsFor(id);
	return v;
}

function unwiredDesktop(id: PaneId): Desktop {
	throw new Error(`pane ${id as int32} opened before its window was wired`);
}

function unwiredEvents(id: PaneId): HostEvents {
	throw new Error(`pane ${id as int32} opened before its window was wired`);
}

function hooksOf(this v: WorkspaceView, id: PaneId): PaneHooks {
	for (const h of v.hooks) {
		if (h.id == id) { return h; }
	}
	const made: PaneHooks = {
		id: id,
		wake: null,
		menu: null,
		closeRequest: null,
		config: null,
	};
	v.hooks.push(made);
	return made;
}

function eventsFor(this v: WorkspaceView, id: PaneId): HostEvents {
	return {
		onWake: (handler: () => void): void => { v.hooksOf(id).wake = handler; },
		onMenu: (handler: (item: string) => void): void => {
			v.hooksOf(id).menu = handler;
		},
		onCloseRequest: (handler: () => void): void => {
			v.hooksOf(id).closeRequest = handler;
		},
		onConfig: (handler: (change: ConfigChange) => void): void => {
			v.hooksOf(id).config = handler;
		},
	};
}

function desktopFor(this v: WorkspaceView, id: PaneId): Desktop {
	const h = v.host;
	return {
		setTitle: (title: string, belled: boolean): void => { v.titled(id); },
		notify: h.notify,
		openLink: h.openLink,
		attention: h.attention,
		setHand: h.setHand,
		openConfig: h.openConfig,
		reloadConfig: h.reloadConfig,
		close: (): void => { v.closeWindow(); },
		exited: (code: int32): void => { v.exited(id, code); },
		windowAction: (action: Action): void => { v.windowAction(action); },
	};
}

export function focusedModel(this v: WorkspaceView): PaneModel | null {
	const id = v.w.focusedPane();
	if (id === null) { return null; }
	return v.panes.paneOf(id)?.model ?? null;
}

function focusedHooks(this v: WorkspaceView): PaneHooks | null {
	const id = v.w.focusedPane();
	if (id === null) { return null; }
	return v.hooksOf(id);
}

export function connect(this v: WorkspaceView): void {
	const events = v.host.events;
	events.onWake((): void => {
		for (const h of v.hooks) {
			const wake = h.wake;
			if (wake !== null) { wake(); }
		}
	});
	events.onMenu((item: string): void => {
		const menu = v.focusedHooks()?.menu ?? null;
		if (menu !== null) { menu(item); }
	});
	events.onCloseRequest((): void => {
		const request = v.focusedHooks()?.closeRequest ?? null;
		if (request !== null) {
			request();
		} else {
			v.closeWindow();
		}
	});
	events.onConfig((change: ConfigChange): void => {
		v.reconfigure(change);
		for (const h of v.hooks) {
			const config = h.config;
			if (config !== null) { config(change); }
		}
	});
}

function reconfigure(this v: WorkspaceView, change: ConfigChange): void {
	if (change.outcome === ConfigOutcome.Refused) { return; }
	const c = change.config;
	v.config = c;
	v.panes.launch.cwd = newPaneCwdOf(c);
	v.setLook(lookOf(c));
	v.setChrome(chromeOf(c));
	v.setInset(c.padding);
	v.setSidebarShown(c.sidebarVisible);
	v.w.dividerCells = dividerCellsOf(c);
	flush();
	v.font.reconfigured(c, change.family);
	v.relayout();
}

export function laidOut(this v: WorkspaceView, e: NeonEvent): void {
	if (e.width <= 0 || e.height <= 0) { return; }
	if (e.width == v.areaWidth && e.height == v.areaHeight) { return; }
	v.areaWidth = e.width;
	v.areaHeight = e.height;
	v.relayout();
}

export function relayout(this v: WorkspaceView): void {
	const measured = v.font.measured();
	if (!measured.ok) {
		v.host.report.note(`font: ${measured.error}`);
		const text = `Haro could not measure the font: ${measured.error}`;
		v.focusedModel()?.notify(text);
		return;
	}
	if (v.areaWidth <= 0) { return; }
	const inset = v.inset();
	const across = Math.max(v.areaWidth - 2 * inset, 0) as float32;
	const down = Math.max(v.areaHeight - 2 * inset, 0) as float32;
	const size = gridSize(
		PixelRatio.getPixelSizeForLayoutSize(across) as int32,
		PixelRatio.getPixelSizeForLayoutSize(down) as int32,
		v.font.cellPx,
		v.font.rowPx,
	);
	if (!size.ok) { return; }
	const p = v.panes;
	if (p.cellWidth != v.font.cellPx || p.cellHeight != v.font.rowPx) {
		p.cellWidth = v.font.cellPx;
		p.cellHeight = v.font.rowPx;
		v.refitAll = true;
	}
	v.cols = size.value[0];
	v.rows = size.value[1];
	v.send({ kind: CommandKind.Fit });
}

export function send(this v: WorkspaceView, c: WorkspaceCommand): void {
	const link = v.link;
	if (link !== null) {
		v.sendTo(link, c);
		return;
	}
	v.queue.push(c);
	if (v.draining) { return; }
	const _drained = v.drain();
}

async function drain(this v: WorkspaceView): Promise<void> {
	v.draining = true;
	while (v.queue.length > 0 && !v.quitting) {
		const next = v.queue.shift();
		if (next !== undefined) { await v.run(next); }
	}
	v.draining = false;
}

function sendTo(this v: WorkspaceView, link: ServerLink, c: WorkspaceCommand): void {
	if (c.kind != CommandKind.Fit) {
		link.command(c);
		return;
	}
	link.fit(v.cols, v.rows);
	if (v.refitAll) {
		v.refitPanes();
		v.redraw();
	}
}

function refused(
	this v: WorkspaceView,
	c: WorkspaceCommand,
	e: WorkspaceError,
): void {
	match (e) {
		WorkspaceError.NoTabAtIndex => {},
		WorkspaceError.NoRoomToSplit => {
			v.focusedModel()?.notify("This pane has no room to split.");
		},
		_ => {
			const kind = c.kind.toString();
			v.host.report.note(`workspace: ${kind} refused: ${e.toString()}`);
		},
	}
}

function notStarted(this v: WorkspaceView, id: PaneId, error: TermError): void {
	if (v.link !== null) {
		v.host.report.note(`pane ${id as int32}: the window could not show it: ${error.toString()}`);
		v.focusedModel()?.notify(`Pane ${id as int32} could not be shown (${error.toString()})`);
		return;
	}
	if (v.panes.running.length == 0) {
		v.host.report.fail(`open: ${error.toString()}`);
		return;
	}
	v.shellFailed(error.toString());
	v.queue.push({ kind: CommandKind.ClosePane, pane: id });
}

function shellFailed(this v: WorkspaceView, why: string): void {
	v.focusedModel()?.notify(
		`The shell did not start (${why}): check command in config.ms, or --shell`,
	);
}

async function run(this v: WorkspaceView, c: WorkspaceCommand): Promise<void> {
	const applied = v.w.apply(c, v.cols, v.rows);
	if (!applied.ok) {
		v.refused(c, applied.error);
		return;
	}
	await v.applyEvents(applied.value);
}

function refitPanes(this v: WorkspaceView): void {
	v.refitAll = false;
	for (const tab of v.w.tabs) {
		for (const p of tab.layout(v.cols, v.rows, v.w.dividerCells)) {
			v.panes.refit(p.pane.id, p.rect);
		}
	}
}

async function applyEvents(this v: WorkspaceView, events: WorkspaceEvent[]): Promise<void> {
	const firstStart = v.panes.running.length == 0 && v.hooks.length == 0;
	for (const e of events) {
		if (e.kind == EventKind.WorkspaceEmpty) {
			v.host.report.note("the last pane closed");
			await v.quit();
			return;
		}
		if (e.kind == EventKind.PaneClosed) { v.forget(e.pane); }
		const failed = await v.panes.applyEvent(e);
		if (failed !== null && e.kind == EventKind.PaneOpened) {
			v.notStarted(e.pane, failed);
		}
	}
	if (v.refitAll) { v.refitPanes(); }
	v.redraw();
	const first = v.panes.running.length > 0 ? v.panes.running[0] : null;
	if (firstStart && first !== null) {
		const started = v.started;
		v.started = (later: RunningPane): void => {};
		started(first);
	}
}

function forget(this v: WorkspaceView, id: PaneId): void {
	v.hooks = v.hooks.filter((h: PaneHooks): boolean => !(h.id == id));
	v.cwds = v.cwds.filter((k: KnownCwd): boolean => !(k.id == id));
}

function titleOf(this v: WorkspaceView, id: PaneId): string {
	return v.panes.paneOf(id)?.model.title ?? "";
}

function cwdOf(this v: WorkspaceView, id: PaneId): string {
	for (const k of v.cwds) {
		if (k.id == id) { return k.cwd; }
	}
	return "";
}

function shortened(path: string): string {
	const home = homeDir();
	if (home != "" && (path == home || path.startsWith(`${home}/`))) {
		return `~${path.substring(home.length)}`;
	}
	return path;
}

async function learnCwd(this v: WorkspaceView, id: PaneId): Promise<void> {
	const pane = v.panes.paneOf(id);
	if (pane === null) { return; }
	const cwd = await pane.reportedCwd();
	const shown = cwd === null ? "" : shortened(cwd);
	if (shown == v.cwdOf(id)) { return; }
	v.cwds = v.cwds.filter((k: KnownCwd): boolean => !(k.id == id));
	if (shown != "") { v.cwds.push({ id: id, cwd: shown }); }
	v.setTabs(v.sidebarTabs());
}

function titled(this v: WorkspaceView, id: PaneId): void {
	v.redraw();
	const _cwd = v.learnCwd(id);
}

function belled(this v: WorkspaceView, ids: PaneId[]): boolean {
	for (const id of ids) {
		if (v.panes.paneOf(id)?.model.belled ?? false) { return true; }
	}
	return false;
}

export function sidebarTabs(this v: WorkspaceView): SidebarTab[] {
	const out: SidebarTab[] = [];
	for (const tab of v.w.tabs) {
		const ids = tab.root.panes().map((p: Pane): PaneId => p.id);
		const rows: SidebarPane[] = ids.map((id: PaneId): SidebarPane => {
			return {
				id: id as int32,
				title: v.titleOf(id),
				cwd: v.cwdOf(id),
				focused: id == tab.focused,
				badge: "",
			};
		});
		const active = v.w.active;
		out.push({
			id: tab.id as int32,
			title: tab.title ?? v.titleOf(tab.focused),
			active: active !== null && active == tab.id,
			attention: v.belled(ids),
			panes: rows,
		});
	}
	return out;
}

function paneTitle(this v: WorkspaceView, id: PaneId): string {
	return v.config.paneTitle == PaneTitle.None ? "" : v.titleOf(id);
}

export function redraw(this v: WorkspaceView): void {
	const tab = v.w.activeTab();
	if (tab === null) { return; }
	const f = frameOf(
		tab,
		v.cols,
		v.rows,
		v.w.dividerCells,
		(id: PaneId): string => v.paneTitle(id),
	);
	v.setLayout(f);
	v.setTabs(v.sidebarTabs());
	flush();
	const m = v.font.metrics;
	const chrome = v.chrome();
	const left = v.sidebarShown() && chrome.sidebarLeft
		? (chrome.sidebarCols as float64) * m.cellWidth()
		: 0;
	const inset = v.inset();
	for (const p of f.panes) {
		const box = paneBox(
			p.rect,
			f.cols,
			f.rows,
			m.cellWidth(),
			m.rowHeight(),
			v.look().gapPixels,
		);
		const model = v.panes.paneOf(p.pane.id)?.model ?? null;
		model?.placeAt(left + inset + box.left, inset + box.top);
	}
	const focused = v.focusedModel();
	if (focused === null) { return; }
	const all = v.panes.running.map((r: RunningPane): PaneId => r.id);
	v.host.setTitle(focused.title, v.belled(all));
	if (!v.confirm.visible()) { focused.grid?.focus(); }
}

function exited(this v: WorkspaceView, id: PaneId, code: int32): void {
	v.host.report.note(`pane ${id as int32}: the shell exited with code ${code}`);
	if (v.keepsEnded || v.link !== null) { return; }
	v.send({ kind: CommandKind.ClosePane, pane: id });
}

export async function closeShells(this v: WorkspaceView): Promise<void> {
	const shells = v.panes.running.map((r: RunningPane): RunningPane => r);
	for (const r of shells) { await closed(r.shell); }
}

export async function quit(this v: WorkspaceView): Promise<void> {
	if (v.quitting) { return; }
	v.quitting = true;
	v.link?.detach();
	await v.closeShells();
	v.host.quit();
}

async function busyCount(this v: WorkspaceView, ids: PaneId[]): Promise<int32> {
	let busy: int32 = 0;
	const link = v.link;
	for (const id of ids) {
		const pane = v.panes.paneOf(id);
		if (pane === null) { continue; }
		const running = link === null ? !(await pane.foregroundIsShell()) : await link.busy(id);
		if (running) { busy += 1; }
	}
	return busy;
}

async function askClose(
	this v: WorkspaceView,
	what: Closing,
	ids: PaneId[],
	then: WorkspaceCommand | null,
): Promise<void> {
	if (v.confirm.visible()) { return; }
	const confirming = v.config.confirmClose;
	const busy = confirming ? await v.busyCount(ids) : 0;
	if (!closeNeedsConfirm(busy == 0, confirming)) {
		v.closeNow(then);
		return;
	}
	v.closing = then;
	const asked: CloseAsk = {
		what: what,
		program: "",
		count: ids.length as int32,
	};
	v.confirm.ask(asked, v.font.metrics.cellWidth(), v.areaWidth);
	flush();
}

function closeNow(this v: WorkspaceView, then: WorkspaceCommand | null): void {
	if (then === null) {
		const _quit = v.quit();
		return;
	}
	v.send(then);
}

export function confirmed(this v: WorkspaceView): void {
	v.confirm.dismiss();
	const then = v.closing;
	v.closing = null;
	v.closeNow(then);
}

export function cancelled(this v: WorkspaceView): void {
	v.confirm.dismiss();
	v.closing = null;
	v.focusedModel()?.grid?.focus();
}

export function askClosePane(this v: WorkspaceView, id: PaneId): void {
	const close: WorkspaceCommand = { kind: CommandKind.ClosePane, pane: id };
	const _asked = v.askClose(Closing.Pane, [id], close);
}

function askCloseTab(this v: WorkspaceView): void {
	const tab = v.w.activeTab();
	if (tab === null) { return; }
	const ids = tab.root.panes().map((p: Pane): PaneId => p.id);
	const close: WorkspaceCommand = { kind: CommandKind.CloseTab, tab: tab.id };
	const _asked = v.askClose(Closing.Tab, ids, close);
}

export function closeWindow(this v: WorkspaceView): void {
	v.host.report.note("Close Window, Quit or a keybind asked to close");
	if (v.link !== null) {
		const _detached = v.quit();
		return;
	}
	const ids = v.panes.running.map((r: RunningPane): PaneId => r.id);
	const _asked = v.askClose(Closing.Window, ids, null);
}

export function selectTab(this v: WorkspaceView, id: TabId): void {
	for (let i: int32 = 0; i < v.w.tabs.length; i++) {
		if (v.w.tabs[i].id == id) {
			v.send({ kind: CommandKind.GotoTab, index: i });
			return;
		}
	}
}

function split(this v: WorkspaceView, axis: Axis): void {
	const id = v.w.focusedPane();
	if (id === null) { return; }
	v.send({ kind: CommandKind.Split, pane: id, axis: axis });
}

function resized(this v: WorkspaceView, direction: Direction): void {
	const cells = v.config.paneResizeStep as int32;
	v.send({ kind: CommandKind.Resize, direction: direction, cells: cells });
}

function gotoTab(this v: WorkspaceView, index: int32): void {
	v.send({ kind: CommandKind.GotoTab, index: index });
}

export function toggleSidebar(this v: WorkspaceView): void {
	v.setSidebarShown(!v.sidebarShown());
	flush();
}

export function windowAction(this v: WorkspaceView, action: Action): void {
	match (action) {
		Action.IncreaseFontSize |
		Action.DecreaseFontSize |
		Action.ResetFontSize => {
			if (v.font.stepped(action)) { v.relayout(); }
		},
		Action.SplitRight => { v.split(Axis.SideBySide); },
		Action.SplitDown => { v.split(Axis.Stacked); },
		Action.ClosePane => {
			const id = v.w.focusedPane();
			if (id !== null) { v.askClosePane(id); }
		},
		Action.FocusPaneLeft => {
			v.send({ kind: CommandKind.FocusDirection, direction: Direction.Left });
		},
		Action.FocusPaneRight => {
			v.send({ kind: CommandKind.FocusDirection, direction: Direction.Right });
		},
		Action.FocusPaneUp => {
			v.send({ kind: CommandKind.FocusDirection, direction: Direction.Up });
		},
		Action.FocusPaneDown => {
			v.send({ kind: CommandKind.FocusDirection, direction: Direction.Down });
		},
		Action.FocusPanePrevious => {
			v.send({ kind: CommandKind.CyclePane, by: -1 });
		},
		Action.FocusPaneNext => { v.send({ kind: CommandKind.CyclePane, by: 1 }); },
		Action.ResizePaneLeft => { v.resized(Direction.Left); },
		Action.ResizePaneRight => { v.resized(Direction.Right); },
		Action.ResizePaneUp => { v.resized(Direction.Up); },
		Action.ResizePaneDown => { v.resized(Direction.Down); },
		Action.TogglePaneZoom => { v.send({ kind: CommandKind.ToggleZoom }); },
		Action.NewTab => { v.send({ kind: CommandKind.NewTab }); },
		Action.CloseTab => { v.askCloseTab(); },
		Action.PreviousTab => { v.send({ kind: CommandKind.CycleTab, by: -1 }); },
		Action.NextTab => { v.send({ kind: CommandKind.CycleTab, by: 1 }); },
		Action.GotoTab1 => { v.gotoTab(0); },
		Action.GotoTab2 => { v.gotoTab(1); },
		Action.GotoTab3 => { v.gotoTab(2); },
		Action.GotoTab4 => { v.gotoTab(3); },
		Action.GotoTab5 => { v.gotoTab(4); },
		Action.GotoTab6 => { v.gotoTab(5); },
		Action.GotoTab7 => { v.gotoTab(6); },
		Action.GotoTab8 => { v.gotoTab(7); },
		Action.GotoTab9 => { v.gotoTab(8); },
		Action.MoveTabLeft => { v.send({ kind: CommandKind.MoveTab, by: -1 }); },
		Action.MoveTabRight => { v.send({ kind: CommandKind.MoveTab, by: 1 }); },
		Action.RenameTab => {
			v.focusedModel()?.notify("Renaming a tab is not available yet.");
		},
		Action.ToggleSidebar => { v.toggleSidebar(); },
		_ => {
			v.host.report.note(`the window does not run ${action.toString()}`);
		},
	}
}

export function begin(this v: WorkspaceView): void {
	const link = v.link;
	const attached = v.attached;
	v.attached = null;
	if (link === null || attached === null) {
		v.send({ kind: CommandKind.NewTab });
		return;
	}
	const _attached = v.attachTo(link, attached);
}

function adopt(this v: WorkspaceView, layout: Layout): void {
	v.w.tabs = layout.tabs;
	v.w.active = layout.active;
}

function opening(this v: WorkspaceView): WorkspaceEvent[] {
	const events: WorkspaceEvent[] = [];
	for (const tab of v.w.tabs) {
		for (const p of tab.layout(v.cols, v.rows, v.w.dividerCells)) {
			events.push({
				kind: EventKind.PaneOpened,
				pane: p.pane.id,
				tab: tab.id,
				origin: p.pane.origin,
				rect: p.rect,
			});
		}
	}
	const focused = v.w.focusedPane();
	if (focused !== null) { events.push({ kind: EventKind.FocusChanged, pane: focused }); }
	return events;
}

export async function attachTo(
	this v: WorkspaceView,
	link: ServerLink,
	attached: Attached,
): Promise<void> {
	v.link = link;
	v.panes.remote = {
		screens: attached.screens,
		input: (pane: PaneId, bytes: Vec<uint8>): void => { link.input(pane, bytes); },
	};
	v.adopt(attached.layout);
	await v.applyEvents(v.opening());
	if (v.w.tabs.length == 0) { link.command({ kind: CommandKind.NewTab }); }
	link.fit(v.cols, v.rows);
	link.listen(
		(m: Message): void => { v.received(m); },
		(why: string): void => { v.lost(why); },
	);
}

export async function detachPanes(this v: WorkspaceView): Promise<void> {
	v.link?.detach();
	v.link = null;
	v.inbox = [];
	await v.closeShells();
	v.panes.running = [];
	v.hooks = [];
	v.cwds = [];
	v.w.tabs = [];
	v.w.active = null;
	v.setLayout(emptyFrame(v.w.dividerCells));
	v.setTabs([]);
	flush();
}

function lost(this v: WorkspaceView, why: string): void {
	v.host.report.note(`server: ${why}`);
	v.focusedModel()?.notify(`Haro lost its server: ${why}. Close this window and open Haro again.`);
}

function received(this v: WorkspaceView, m: Message): void {
	v.inbox.push(m);
	if (v.receiving) { return; }
	const _drained = v.drainInbox();
}

async function drainInbox(this v: WorkspaceView): Promise<void> {
	v.receiving = true;
	while (v.inbox.length > 0 && !v.quitting) {
		const next = v.inbox.shift();
		if (next !== undefined) { await v.receive(next); }
	}
	v.receiving = false;
}

function output(this v: WorkspaceView, id: PaneId, seq: uint64, bytes: uint8[]): void {
	const pane = v.panes.paneOf(id);
	if (pane === null) {
		v.host.report.note(`server: output for pane ${id as int32}, which this window does not show`);
		return;
	}
	pane.shell.feed(seq, [...bytes]);
	const wake = v.hooksOf(id).wake;
	if (wake !== null) { wake(); }
}

async function receive(this v: WorkspaceView, m: Message): Promise<void> {
	const parts = screenParts(m);
	if (parts !== null) {
		const layout = parts.layout;
		if (layout !== null) { v.adopt(layout); }
		const remote = v.panes.remote;
		if (remote !== null) {
			for (const s of parts.screens) { remote.screens.push(s); }
		}
		v.redraw();
		return;
	}
	if (m.kind == MessageKind.Event) {
		await v.applyEvents([m.event]);
	} else if (m.kind == MessageKind.Output) {
		v.output(m.pane, m.seq, m.bytes);
	} else if (m.kind == MessageKind.Exited) {
		v.exited(m.pane, m.code);
	} else if (m.kind == MessageKind.Failed) {
		v.host.report.note(`pane ${m.pane as int32}: ${m.reason}`);
		v.shellFailed(m.reason);
	} else if (m.kind == MessageKind.Refused) {
		v.lost(`the server refused: ${m.reason}`);
	} else if (m.kind == MessageKind.Bye) {
		v.lost("the server said goodbye");
	} else {
		v.host.report.note(`server: a window does not take ${m.kind.toString()}`);
	}
}
