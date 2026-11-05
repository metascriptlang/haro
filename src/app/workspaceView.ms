import { Accessor, Setter, createSignal } from "../../../neon/src/core/signal";
import { flush } from "../../../neon/src/core/runtime";
import { NeonEvent } from "../../../neon/src/render/event";
import { PixelRatio } from "../../../neon/src/api/pixelRatio";
import { homeDir } from "std/os";
import {
	Config,
	DividerStyle as ConfigDivider,
	PaneCwd,
	dividerCellsOf,
	PaneTitle,
	RemoteHost,
	SidebarSide,
} from "../config/config";
import { Action } from "../input/bindings";
import { Rgb } from "../vt/vt";
import { vtBuild } from "../vt/snapshot";
import { gridSize } from "../grid/size";
import { TermError } from "../controller/term";
import { closed } from "../controller/shell";
import { Axis, Pane, PaneId, panes } from "../workspace/tree";
import { HostId, HostPane, HostTab } from "../workspace/hosted";
import { Message, MessageKind } from "../server/protocol";
import { Attached, Dial, DialError, Failure, ServerLink, linkTo } from "../client/link";
import { destinationOf } from "../client/destination";
import { Feed, add } from "../client/feeds";
import { HostBook, readKept, writeKept } from "../client/hostBook";
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
import { Stats, noteWake } from "./stats";
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
import { SidebarHost, SidebarPane, SidebarTab } from "./components/features/sidebar/sidebar";
import {
	CloseAsk,
	Closing,
	ConfirmModel,
	ask,
	closeNeedsConfirm,
	dismiss,
	open,
} from "./components/features/confirm/confirmClose";
import {
	HostAsk,
	HostChoice,
	HostDialogModel,
	askAdd,
	askForget,
	askPick,
	open,
	shut,
	visible,
} from "./components/features/hosts/hostDialog";

const START_COLS: int32 = 80;
const START_ROWS: int32 = 24;
const DIVIDER_GREY = 239;
const FOCUS_BLUE = 74;
const BRIGHT_BLACK = 8;
const DIM_FALLBACK = "#7a7a7a";
const ATTACH_TIMEOUT_MS: int32 = 5000;
const FIRST_RETRY_MS: int32 = 1000;
const LAST_RETRY_MS: int32 = 30000;
const LOCAL_LABEL = "local";

export interface WindowHost {
	setTitle: (title: string, belled: boolean) => void;
	notify: (title: string, body: string) => void;
	openLink: (uri: string) => void;
	attention: () => void;
	setHand: (on: boolean) => void;
	openConfig: () => void;
	reloadConfig: () => void;
	quit: () => void;
	wake: () => void;
	report: Report;
	timing: Timing;
	keyHook: KeyHook;
	shellHook: ShellHook;
	events: HostEvents;
	stats: Stats;
	fontFamily: string;
	hostBook: HostBook;
}

export struct Chrome {
	background: string;
	foreground: string;
	accent: string;
	dim: string;
	sidebarCols: int32;
	sidebarLeft: boolean;
}

export enum LinkState {
	InProcess,
	Connecting,
	Uploading,
	Connected,
	Unkept,
	Offline,
	Refused,
}

export interface LinkedHost {
	id: HostId;
	label: string;
	dial: Dial | null;
	inProcess: boolean;
	link: ServerLink | null;
	w: Workspace;
	panes: Panes;
	state: LinkState;
	reason: string;
	failures: int32;
	retry: number | null;
	dialing: boolean;
	queue: WorkspaceCommand[];
	draining: boolean;
	inbox: Message[];
	receiving: boolean;
}

struct HostCommand {
	host: HostId;
	command: WorkspaceCommand;
}

interface PaneHooks {
	id: HostPane;
	wake: (() => void) | null;
	menu: ((id: string) => void) | null;
	closeRequest: (() => void) | null;
	config: ((change: ConfigChange) => void) | null;
}

struct KnownCwd {
	id: HostPane;
	cwd: string;
}

export interface WorkspaceView {
	host: WindowHost;
	config: Config;
	launch: PaneLaunch;
	hosts: LinkedHost[];
	issuedHosts: int32;
	shown: Accessor<HostId>;
	setShown: Setter<HostId>;
	pendingShow: HostId | null;
	begun: boolean;
	font: CellFont;
	confirm: ConfirmModel;
	hostDialog: HostDialogModel;
	kept: RemoteHost[];
	layout: Accessor<FrameLayout>;
	setLayout: Setter<FrameLayout>;
	tabs: Accessor<SidebarHost[]>;
	setTabs: Setter<SidebarHost[]>;
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
	refitAll: boolean;
	hooks: PaneHooks[];
	cwds: KnownCwd[];
	closing: HostCommand | null;
	keepsEnded: boolean;
	quitting: boolean;
	started: (first: RunningPane) => void;
	attached: Attached | null;
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

export function retryDelayMs(failures: int32): int32 {
	let delay = FIRST_RETRY_MS;
	for (let i: int32 = 0; i < failures && delay < LAST_RETRY_MS; i++) { delay *= 2; }
	return Math.min(delay, LAST_RETRY_MS);
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
	dial: Dial | null = null,
	label: string = "",
): WorkspaceView {
	const divider = dividerCellsOf(started);
	const font = CellFont.open(started, host.fontFamily);
	const [layout, setLayout] = createSignal<FrameLayout>(emptyFrame(divider));
	const [tabs, setTabs] = createSignal<SidebarHost[]>([]);
	const [shown, setShown] = createSignal<HostId>(0 as HostId);
	const [sidebar, setSidebar] = createSignal<boolean>(started.sidebarVisible);
	const [look, setLook] = createSignal<FrameLook>(lookOf(started));
	const [chrome, setChrome] = createSignal<Chrome>(chromeOf(started));
	const [inset, setInset] = createSignal<number>(started.padding);
	const v: WorkspaceView = {
		host: host,
		config: started,
		launch: {
			command: command,
			shellScripts: shellScripts,
			startIn: startIn,
			cwd: newPaneCwdOf(started),
			recording: recording,
		},
		hosts: [],
		issuedHosts: 0,
		shown: shown,
		setShown: setShown,
		pendingShow: null,
		begun: false,
		font: font,
		confirm: ConfirmModel.open(),
		hostDialog: HostDialogModel.open(),
		kept: [],
		layout: layout,
		setLayout: setLayout,
		tabs: tabs,
		setTabs: setTabs,
		sidebarShown: sidebar,
		setSidebarShown: setSidebar,
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
		refitAll: false,
		hooks: [],
		cwds: [],
		closing: null,
		keepsEnded: recording !== null,
		quitting: false,
		started: (first: RunningPane): void => {},
		attached: attached,
	};
	const primary = v.made(label, dial, link === null && dial === null);
	primary.link = link;
	v.hosts.push(primary);
	return v;
}

function made(
	this v: WorkspaceView,
	label: string,
	dial: Dial | null,
	inProcess: boolean,
): LinkedHost {
	const id = v.issuedHosts as HostId;
	v.issuedHosts += 1;
	const created = Workspace.create(dividerCellsOf(v.config));
	if (!created.ok) {
		throw new Error(`workspace: ${created.error.toString()}`);
	}
	const h = v.host;
	const paneHost: PaneHost = {
		desktopFor: (pane: PaneId): Desktop => v.desktopFor({ host: id, pane: pane }),
		eventsFor: (pane: PaneId): HostEvents => v.eventsFor({ host: id, pane: pane }),
		report: h.report,
		timing: h.timing,
		keyHook: h.keyHook,
		shellHook: h.shellHook,
		metrics: v.font.metrics,
		started: v.config,
		stats: h.stats,
	};
	const panes = Panes.open(v.launch, paneHost, 0, 0);
	if (v.hosts.length > 0) {
		panes.cellWidth = v.hosts[0].panes.cellWidth;
		panes.cellHeight = v.hosts[0].panes.cellHeight;
	}
	return {
		id: id,
		label: label,
		dial: dial,
		inProcess: inProcess,
		link: null,
		w: created.value,
		panes: panes,
		state: inProcess ? LinkState.InProcess : LinkState.Connecting,
		reason: "",
		failures: 0,
		retry: null,
		dialing: false,
		queue: [],
		draining: false,
		inbox: [],
		receiving: false,
	};
}

export function primary(this v: WorkspaceView): LinkedHost {
	return v.hosts[0];
}

export function hostOf(this v: WorkspaceView, id: HostId): LinkedHost | null {
	for (const h of v.hosts) {
		if (h.id == id) { return h; }
	}
	return null;
}

export function shownHost(this v: WorkspaceView): LinkedHost {
	return v.hostOf(v.shown()) ?? v.primary();
}

function labelOf(this v: WorkspaceView, h: LinkedHost): string {
	return h.label == "" ? LOCAL_LABEL : h.label;
}

function hooksOf(this v: WorkspaceView, id: HostPane): PaneHooks {
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

function eventsFor(this v: WorkspaceView, id: HostPane): HostEvents {
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

function desktopFor(this v: WorkspaceView, id: HostPane): Desktop {
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

export function paneAt(this v: WorkspaceView, id: HostPane): RunningPane | null {
	return v.hostOf(id.host)?.panes.paneOf(id.pane) ?? null;
}

function focusedAt(this v: WorkspaceView): HostPane | null {
	const h = v.shownHost();
	const id = h.w.focusedPane();
	if (id === null) { return null; }
	return { host: h.id, pane: id };
}

export function focusedModel(this v: WorkspaceView): PaneModel | null {
	const id = v.focusedAt();
	if (id === null) { return null; }
	return v.paneAt(id)?.model ?? null;
}

function focusedHooks(this v: WorkspaceView): PaneHooks | null {
	const id = v.focusedAt();
	if (id === null) { return null; }
	return v.hooksOf(id);
}

export function connect(this v: WorkspaceView): void {
	const events = v.host.events;
	events.onWake((): void => {
		for (const h of v.hooks) {
			const wake = h.wake;
			const host = v.hostOf(h.id.host);
			if (wake !== null && (host === null || host.inProcess)) { wake(); }
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
	v.launch.cwd = newPaneCwdOf(c);
	v.setLook(lookOf(c));
	v.setChrome(chromeOf(c));
	v.setInset(c.padding);
	v.setSidebarShown(c.sidebarVisible);
	for (const h of v.hosts) { h.w.dividerCells = dividerCellsOf(c); }
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
	for (const h of v.hosts) {
		const p = h.panes;
		if (p.cellWidth != v.font.cellPx || p.cellHeight != v.font.rowPx) {
			p.cellWidth = v.font.cellPx;
			p.cellHeight = v.font.rowPx;
			v.refitAll = true;
		}
	}
	v.cols = size.value[0];
	v.rows = size.value[1];
	v.fitAll();
}

function fitAll(this v: WorkspaceView): void {
	let served = false;
	for (const h of v.hosts) {
		if (h.inProcess) {
			v.sendTo(h, { kind: CommandKind.Fit });
		} else {
			served = true;
			h.link?.fit(v.cols, v.rows);
		}
	}
	if (served && v.refitAll) {
		v.refitPanes();
		v.redraw();
	}
}

export function send(this v: WorkspaceView, c: WorkspaceCommand): void {
	v.sendTo(v.shownHost(), c);
}

export function sendTo(this v: WorkspaceView, h: LinkedHost, c: WorkspaceCommand): void {
	if (h.inProcess) {
		h.queue.push(c);
		if (h.draining) { return; }
		const _drained = v.drain(h);
		return;
	}
	const link = h.link;
	if (link === null) {
		v.focusedModel()?.notify(`${v.labelOf(h)} is ${stateText(h)}${reasonText(h)}`);
		return;
	}
	if (c.kind == CommandKind.Fit) {
		link.fit(v.cols, v.rows);
	} else {
		link.command(c);
	}
}

async function drain(this v: WorkspaceView, h: LinkedHost): Promise<void> {
	h.draining = true;
	while (h.queue.length > 0 && !v.quitting) {
		const next = h.queue.shift();
		if (next !== undefined) { await v.run(h, next); }
	}
	h.draining = false;
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

function notStarted(this v: WorkspaceView, h: LinkedHost, id: PaneId, error: TermError): void {
	if (!h.inProcess) {
		v.host.report.note(`pane ${id as int32}: the window could not show it: ${error.toString()}`);
		v.focusedModel()?.notify(`Pane ${id as int32} could not be shown (${error.toString()})`);
		return;
	}
	if (h.panes.running.length == 0) {
		v.host.report.fail(`open: ${error.toString()}`);
		return;
	}
	v.shellFailed(error.toString());
	h.queue.push({ kind: CommandKind.ClosePane, pane: id });
}

function shellFailed(this v: WorkspaceView, why: string): void {
	v.focusedModel()?.notify(
		`The shell did not start (${why}): check command in config.ms, or --shell`,
	);
}

async function run(this v: WorkspaceView, h: LinkedHost, c: WorkspaceCommand): Promise<void> {
	const applied = h.w.apply(c, v.cols, v.rows);
	if (!applied.ok) {
		v.refused(c, applied.error);
		return;
	}
	await v.applyEvents(h, applied.value);
}

function refitPanes(this v: WorkspaceView): void {
	v.refitAll = false;
	for (const h of v.hosts) {
		for (const tab of h.w.tabs) {
			for (const p of tab.layout(v.cols, v.rows, h.w.dividerCells)) {
				h.panes.refit(p.pane.id, p.rect);
			}
		}
	}
}

async function applyEvents(
	this v: WorkspaceView,
	h: LinkedHost,
	events: WorkspaceEvent[],
): Promise<void> {
	const firstStart = h.panes.running.length == 0 && v.hooks.length == 0;
	for (const e of events) {
		if (e.kind == EventKind.WorkspaceEmpty) {
			if (await v.emptied(h)) { return; }
			continue;
		}
		if (e.kind == EventKind.PaneClosed) { v.forget({ host: h.id, pane: e.pane }); }
		const failed = await h.panes.applyEvent(e);
		if (failed !== null && e.kind == EventKind.PaneOpened) {
			v.notStarted(h, e.pane, failed);
		}
	}
	if (v.refitAll) { v.refitPanes(); }
	v.follow(h);
	v.redraw();
	const first = h.panes.running.length > 0 ? h.panes.running[0] : null;
	if (firstStart && first !== null) {
		const started = v.started;
		v.started = (later: RunningPane): void => {};
		started(first);
	}
}

async function emptied(this v: WorkspaceView, h: LinkedHost): Promise<boolean> {
	if (v.hosts.some((other: LinkedHost): boolean => other.w.tabs.length > 0)) {
		v.host.report.note(`the last pane on ${v.labelOf(h)} closed`);
		return false;
	}
	v.host.report.note("the last pane closed");
	await v.quit();
	return true;
}

function follow(this v: WorkspaceView, h: LinkedHost): void {
	const pending = v.pendingShow;
	if (pending === null || !(pending == h.id) || h.w.tabs.length == 0) { return; }
	v.pendingShow = null;
	v.setShown(h.id);
}

function forget(this v: WorkspaceView, id: HostPane): void {
	v.hooks = v.hooks.filter((h: PaneHooks): boolean => !(h.id == id));
	v.cwds = v.cwds.filter((k: KnownCwd): boolean => !(k.id == id));
}

function forgetHost(this v: WorkspaceView, host: HostId): void {
	v.hooks = v.hooks.filter((h: PaneHooks): boolean => !(h.id.host == host));
	v.cwds = v.cwds.filter((k: KnownCwd): boolean => !(k.id.host == host));
}

function titleOf(this v: WorkspaceView, id: HostPane): string {
	return v.paneAt(id)?.model.title ?? "";
}

function cwdOf(this v: WorkspaceView, id: HostPane): string {
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

async function learnCwd(this v: WorkspaceView, id: HostPane): Promise<void> {
	const pane = v.paneAt(id);
	if (pane === null) { return; }
	const cwd = await pane.reportedCwd();
	const shown = cwd === null ? "" : shortened(cwd);
	if (shown == v.cwdOf(id)) { return; }
	v.cwds = v.cwds.filter((k: KnownCwd): boolean => !(k.id == id));
	if (shown != "") { v.cwds.push({ id: id, cwd: shown }); }
	v.setTabs(v.sidebarHosts());
}

function titled(this v: WorkspaceView, id: HostPane): void {
	v.redraw();
	const _cwd = v.learnCwd(id);
}

function belled(this v: WorkspaceView, h: LinkedHost, ids: PaneId[]): boolean {
	for (const id of ids) {
		if (h.panes.paneOf(id)?.model.belled ?? false) { return true; }
	}
	return false;
}

function stateText(h: LinkedHost): string {
	return match (h.state) {
		LinkState.InProcess | LinkState.Connected => "",
		LinkState.Connecting => "connecting",
		LinkState.Uploading => "uploading",
		LinkState.Unkept => "no session keeping",
		LinkState.Offline => "offline",
		LinkState.Refused => "refused",
	};
}

function reasonText(h: LinkedHost): string {
	return h.reason == "" ? "" : ` (${h.reason})`;
}

function live(h: LinkedHost): boolean {
	return h.state == LinkState.InProcess ||
		h.state == LinkState.Connected ||
		h.state == LinkState.Unkept;
}

function sidebarTabs(this v: WorkspaceView, h: LinkedHost): SidebarTab[] {
	const out: SidebarTab[] = [];
	const shown = h.id == v.shown();
	for (const tab of h.w.tabs) {
		const ids = tab.root.panes().map((p: Pane): PaneId => p.id);
		const rows: SidebarPane[] = ids.map((id: PaneId): SidebarPane => {
			const at: HostPane = { host: h.id, pane: id };
			return {
				id: id as int32,
				title: v.titleOf(at),
				cwd: v.cwdOf(at),
				focused: id == tab.focused,
				badge: "",
			};
		});
		const active = h.w.active;
		out.push({
			id: tab.id as int32,
			title: tab.title ?? v.titleOf({ host: h.id, pane: tab.focused }),
			active: shown && active !== null && active == tab.id,
			attention: v.belled(h, ids),
			panes: rows,
		});
	}
	return out;
}

export function sidebarHosts(this v: WorkspaceView): SidebarHost[] {
	const headed = v.hosts.length > 1 || v.primary().label != "";
	return v.hosts.map((h: LinkedHost): SidebarHost => {
		return {
			id: h.id as int32,
			label: v.labelOf(h),
			state: stateText(h),
			reason: h.reason,
			header: headed,
			live: live(h),
			tabs: v.sidebarTabs(h),
		};
	});
}

function showHosts(this v: WorkspaceView): void {
	v.setTabs(v.sidebarHosts());
	flush();
}

function paneTitle(this v: WorkspaceView, h: LinkedHost, id: PaneId): string {
	return v.config.paneTitle == PaneTitle.None ? "" : v.titleOf({ host: h.id, pane: id });
}

function withTabs(this v: WorkspaceView): LinkedHost | null {
	if (v.shownHost().w.tabs.length > 0) { return v.shownHost(); }
	for (const h of v.hosts) {
		if (h.w.tabs.length > 0) { return h; }
	}
	return null;
}

export function redraw(this v: WorkspaceView): void {
	const h = v.withTabs();
	if (h !== null && !(h.id == v.shown())) { v.setShown(h.id); }
	const tab = h?.w.activeTab() ?? null;
	if (h === null || tab === null) {
		v.showHosts();
		return;
	}
	const f = frameOf(
		tab,
		v.cols,
		v.rows,
		h.w.dividerCells,
		(id: PaneId): string => v.paneTitle(h, id),
	);
	v.setLayout(f);
	v.setTabs(v.sidebarHosts());
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
		const model = h.panes.paneOf(p.pane.id)?.model ?? null;
		model?.placeAt(left + inset + box.left, inset + box.top);
	}
	const focused = v.focusedModel();
	if (focused === null) { return; }
	const all = h.panes.running.map((r: RunningPane): PaneId => r.id);
	v.host.setTitle(focused.title, v.belled(h, all));
	if (!v.confirm.visible() && !v.hostDialog.visible()) { focused.grid?.focus(); }
}

function exited(this v: WorkspaceView, id: HostPane, code: int32): void {
	v.host.report.note(`pane ${id.pane as int32}: the shell exited with code ${code}`);
	const h = v.hostOf(id.host);
	if (v.keepsEnded || h === null || !h.inProcess) { return; }
	v.sendTo(h, { kind: CommandKind.ClosePane, pane: id.pane });
}

async function closeHostShells(h: LinkedHost): Promise<void> {
	const shells = h.panes.running.map((r: RunningPane): RunningPane => r);
	for (const r of shells) { await closed(r.shell); }
}

export async function closeShells(this v: WorkspaceView): Promise<void> {
	for (const h of v.hosts) { await closeHostShells(h); }
}

export async function quit(this v: WorkspaceView): Promise<void> {
	if (v.quitting) { return; }
	v.quitting = true;
	for (const h of v.hosts) {
		const retry = h.retry;
		if (retry !== null) { clearTimeout(retry); }
		h.retry = null;
		h.link?.detach();
	}
	await v.closeShells();
	v.host.quit();
}

async function busyCount(this v: WorkspaceView, h: LinkedHost, ids: PaneId[]): Promise<int32> {
	let busy: int32 = 0;
	const link = h.link;
	for (const id of ids) {
		const pane = h.panes.paneOf(id);
		if (pane === null) { continue; }
		const running = h.inProcess || link === null
			? !(await pane.foregroundIsShell())
			: await link.busy(id);
		if (running) { busy += 1; }
	}
	return busy;
}

async function askClose(
	this v: WorkspaceView,
	what: Closing,
	h: LinkedHost,
	ids: PaneId[],
	then: WorkspaceCommand | null,
): Promise<void> {
	if (v.confirm.visible()) { return; }
	const confirming = v.config.confirmClose;
	const busy = confirming ? await v.busyCount(h, ids) : 0;
	const pending: HostCommand | null = then === null ? null : { host: h.id, command: then };
	if (!closeNeedsConfirm(busy == 0, confirming)) {
		v.closeNow(pending);
		return;
	}
	v.closing = pending;
	const asked: CloseAsk = {
		what: what,
		program: "",
		count: ids.length as int32,
	};
	v.confirm.ask(asked, v.font.metrics.cellWidth(), v.areaWidth);
	flush();
}

function closeNow(this v: WorkspaceView, then: HostCommand | null): void {
	if (then === null) {
		const _quit = v.quit();
		return;
	}
	const h = v.hostOf(then.host);
	if (h !== null) { v.sendTo(h, then.command); }
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

export function askClosePane(this v: WorkspaceView, id: HostPane): void {
	const h = v.hostOf(id.host);
	if (h === null) { return; }
	const close: WorkspaceCommand = { kind: CommandKind.ClosePane, pane: id.pane };
	const _asked = v.askClose(Closing.Pane, h, [id.pane], close);
}

function askCloseTab(this v: WorkspaceView): void {
	const h = v.shownHost();
	const tab = h.w.activeTab();
	if (tab === null) { return; }
	const ids = tab.root.panes().map((p: Pane): PaneId => p.id);
	const close: WorkspaceCommand = { kind: CommandKind.CloseTab, tab: tab.id };
	const _asked = v.askClose(Closing.Tab, h, ids, close);
}

export function closeWindow(this v: WorkspaceView): void {
	v.host.report.note("Close Window, Quit or a keybind asked to close");
	if (v.hosts.some((h: LinkedHost): boolean => !h.inProcess)) {
		const _detached = v.quit();
		return;
	}
	const h = v.primary();
	const ids = h.panes.running.map((r: RunningPane): PaneId => r.id);
	const _asked = v.askClose(Closing.Window, h, ids, null);
}

export function focusPane(this v: WorkspaceView, id: HostPane): void {
	const h = v.hostOf(id.host);
	if (h === null) { return; }
	v.sendTo(h, { kind: CommandKind.FocusPane, pane: id.pane });
}

export function allTabs(this v: WorkspaceView): HostTab[] {
	const out: HostTab[] = [];
	for (const h of v.hosts) {
		for (const tab of h.w.tabs) { out.push({ host: h.id, tab: tab.id }); }
	}
	return out;
}

export function selectTab(this v: WorkspaceView, id: HostTab): void {
	const h = v.hostOf(id.host);
	if (h === null) { return; }
	for (let i: int32 = 0; i < h.w.tabs.length; i++) {
		if (h.w.tabs[i].id == id.tab) {
			if (!(h.id == v.shown())) {
				v.setShown(h.id);
				v.redraw();
			}
			v.sendTo(h, { kind: CommandKind.GotoTab, index: i });
			return;
		}
	}
}

function cycleTab(this v: WorkspaceView, by: int32): void {
	const all = v.allTabs();
	if (all.length == 0) { return; }
	const h = v.shownHost();
	const active = h.w.active;
	let at: int32 = 0;
	if (active !== null) {
		const here: HostTab = { host: h.id, tab: active };
		at = all.findIndex((t: HostTab): boolean => t == here) as int32;
	}
	const count = all.length as int32;
	v.selectTab(all[(((at + by) % count) + count) % count]);
}

function gotoTab(this v: WorkspaceView, index: int32): void {
	const all = v.allTabs();
	if (index < all.length) { v.selectTab(all[index]); }
}

function split(this v: WorkspaceView, axis: Axis): void {
	const h = v.shownHost();
	const id = h.w.focusedPane();
	if (id === null) { return; }
	v.sendTo(h, { kind: CommandKind.Split, pane: id, axis: axis });
}

function resized(this v: WorkspaceView, direction: Direction): void {
	const cells = v.config.paneResizeStep as int32;
	v.send({ kind: CommandKind.Resize, direction: direction, cells: cells });
}

export function toggleSidebar(this v: WorkspaceView): void {
	v.setSidebarShown(!v.sidebarShown());
	flush();
}

export function newTabOn(this v: WorkspaceView, id: HostId): void {
	const h = v.hostOf(id);
	if (h === null) { return; }
	if (!h.inProcess && h.link === null) {
		v.retryNow(h);
		v.focusedModel()?.notify(`${v.labelOf(h)} is ${stateText(h)}${reasonText(h)}; connecting again`);
		return;
	}
	if (h.w.tabs.length > 0) {
		if (!(h.id == v.shown())) {
			v.setShown(h.id);
			v.redraw();
		}
	} else {
		v.pendingShow = h.id;
	}
	v.sendTo(h, { kind: CommandKind.NewTab });
}

function hostChoices(this v: WorkspaceView): HostChoice[] {
	return v.hosts.map((h: LinkedHost): HostChoice => {
		return { id: h.id as int32, label: v.labelOf(h), state: stateText(h) };
	});
}

export function askHost(this v: WorkspaceView): void {
	v.hostDialog.askPick(v.hostChoices());
	flush();
}

export function askNewHost(this v: WorkspaceView): void {
	v.hostDialog.askAdd();
	flush();
}

export function hostDialogShut(this v: WorkspaceView): void {
	v.hostDialog.shut();
	flush();
	v.focusedModel()?.grid?.focus();
}

export function addRemote(this v: WorkspaceView, label: string, dial: Dial): LinkedHost {
	const h = v.made(label, dial, false);
	v.hosts.push(h);
	v.showHosts();
	if (v.begun) { const _dialed = v.dialHost(h); }
	return h;
}

export function addHost(this v: WorkspaceView, label: string, address: string): string {
	const name = label.trim();
	if (name == "") { return "A host needs a label."; }
	if (v.hosts.some((h: LinkedHost): boolean => v.labelOf(h) == name)) {
		return `The label ${name} is taken.`;
	}
	const destination = destinationOf(address.trim());
	if (!destination.ok) { return `The address ${destination.error}.`; }
	const _added = v.addRemote(name, v.host.hostBook.dial(destination.value));
	v.kept.push({ label: name, address: destination.value });
	const saved = writeKept(v.host.hostBook.path, v.kept);
	if (saved.ok) {
		v.focusedModel()?.notify(`${name} is added and comes back the next time Haro opens.`);
	} else {
		v.host.report.note(`remote hosts: ${saved.error}`);
		v.focusedModel()?.notify(`${name} is added to this window, but Haro could not keep it: ${saved.error}`);
	}
	return "";
}

export function addHosts(this v: WorkspaceView, configured: Vec<RemoteHost>): void {
	const book = v.host.hostBook;
	for (const c of configured) { const _added = v.addRemote(c.label, book.dial(c.address)); }
	const kept = readKept(book.path);
	if (!kept.ok) {
		v.host.report.note(`remote hosts: ${kept.error}`);
		return;
	}
	for (const k of kept.value) {
		if (configured.some((c: RemoteHost): boolean => c.label == k.label)) { continue; }
		v.kept.push(k);
		const _added = v.addRemote(k.label, book.dial(k.address));
	}
}

export function askRemoveHost(this v: WorkspaceView): void {
	const choices = v.hostChoices().filter((c: HostChoice): boolean =>
		v.kept.some((k: RemoteHost): boolean => k.label == c.label)
	);
	if (choices.length == 0) {
		v.focusedModel()?.notify("No remote host added from the File menu is kept; hosts in config.ms leave by editing it.");
		return;
	}
	v.hostDialog.askForget(choices);
	flush();
}

export function hostPicked(this v: WorkspaceView, id: HostId): void {
	const forgetting = v.hostDialog.ask() == HostAsk.Forget;
	v.hostDialogShut();
	if (forgetting) {
		const _removed = v.removeHost(id);
	} else {
		v.newTabOn(id);
	}
}

export async function removeHost(this v: WorkspaceView, id: HostId): Promise<void> {
	const h = v.hostOf(id);
	if (h === null || h === v.primary()) { return; }
	v.kept = v.kept.filter((k: RemoteHost): boolean => k.label != h.label);
	const saved = writeKept(v.host.hostBook.path, v.kept);
	if (!saved.ok) { v.host.report.note(`remote hosts: ${saved.error}`); }
	const retry = h.retry;
	if (retry !== null) { clearTimeout(retry); }
	h.retry = null;
	h.dial = null;
	h.link?.detach();
	h.link = null;
	await v.dropPanes(h);
	v.hosts = v.hosts.filter((k: LinkedHost): boolean => !(k.id == id));
	if (v.pendingShow !== null && v.pendingShow == id) { v.pendingShow = null; }
	v.redraw();
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
			const id = v.focusedAt();
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
		Action.NewTab => { v.newTabOn(v.shownHost().id); },
		Action.CloseTab => { v.askCloseTab(); },
		Action.PreviousTab => { v.cycleTab(-1); },
		Action.NextTab => { v.cycleTab(1); },
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
		Action.NewTabOnHost => { v.askHost(); },
		Action.AddRemoteHost => { v.askNewHost(); },
		Action.RemoveRemoteHost => { v.askRemoveHost(); },
		_ => {
			v.host.report.note(`the window does not run ${action.toString()}`);
		},
	}
}

export function begin(this v: WorkspaceView): void {
	v.begun = true;
	const h = v.primary();
	const link = h.link;
	const attached = v.attached;
	v.attached = null;
	if (link !== null && attached !== null) {
		const _attached = v.attachHost(h, link, attached);
	} else if (h.inProcess) {
		v.sendTo(h, { kind: CommandKind.NewTab });
	}
	for (const other of v.hosts) {
		if (other.link === null) { const _dialed = v.dialHost(other); }
	}
}

function adopt(h: LinkedHost, layout: Layout): void {
	h.w.tabs = layout.tabs;
	h.w.active = layout.active;
}

function opening(this v: WorkspaceView, h: LinkedHost): WorkspaceEvent[] {
	const events: WorkspaceEvent[] = [];
	for (const tab of h.w.tabs) {
		for (const p of tab.layout(v.cols, v.rows, h.w.dividerCells)) {
			events.push({
				kind: EventKind.PaneOpened,
				pane: p.pane.id,
				tab: tab.id,
				origin: p.pane.origin,
				rect: p.rect,
			});
		}
	}
	const focused = h.w.focusedPane();
	if (focused !== null) { events.push({ kind: EventKind.FocusChanged, pane: focused }); }
	return events;
}

export async function attachTo(
	this v: WorkspaceView,
	link: ServerLink,
	attached: Attached,
): Promise<void> {
	await v.attachHost(v.primary(), link, attached);
}

async function dropPanes(this v: WorkspaceView, h: LinkedHost): Promise<void> {
	h.inbox = [];
	await closeHostShells(h);
	h.panes.running = [];
	v.forgetHost(h.id);
	h.w.tabs = [];
	h.w.active = null;
	if (h.id == v.shown()) { v.setLayout(emptyFrame(h.w.dividerCells)); }
	v.setTabs(v.sidebarHosts());
	flush();
}

export async function attachHost(
	this v: WorkspaceView,
	h: LinkedHost,
	link: ServerLink,
	attached: Attached,
): Promise<void> {
	if (h.panes.running.length > 0 || h.w.tabs.length > 0) { await v.dropPanes(h); }
	h.link = link;
	h.state = LinkState.Connected;
	h.reason = "";
	h.failures = 0;
	h.panes.remote = {
		screens: attached.screens,
		input: (pane: PaneId, bytes: Vec<uint8>): void => { link.input(pane, bytes); },
	};
	adopt(h, attached.layout);
	await v.applyEvents(h, v.opening(h));
	if (h.w.tabs.length == 0) {
		if (h.id == v.primary().id) { link.command({ kind: CommandKind.NewTab }); }
		v.showHosts();
	}
	link.fit(v.cols, v.rows);
	link.listen(
		(ms: Message[]): void => { v.received(h, link, ms); },
		(why: string): void => { v.lost(h, link, why); },
	);
}

export async function detachPanes(this v: WorkspaceView): Promise<void> {
	const h = v.primary();
	h.link?.detach();
	h.link = null;
	h.state = LinkState.Offline;
	h.reason = "detached";
	await v.dropPanes(h);
}

async function dialHost(this v: WorkspaceView, h: LinkedHost): Promise<void> {
	const dial = h.dial;
	if (dial === null || h.dialing || h.link !== null || v.quitting) { return; }
	h.dialing = true;
	h.state = LinkState.Connecting;
	v.showHosts();
	const uploading = (): void => {
		h.state = LinkState.Uploading;
		v.showHosts();
	};
	const got = await linkTo(dial, uploading, vtBuild(), v.cols, v.rows, ATTACH_TIMEOUT_MS);
	h.dialing = false;
	if (got.ok && v.quitting) {
		got.value.link.detach();
		return;
	}
	if (got.ok) {
		v.host.report.note(`${v.labelOf(h)}: attached`);
		await v.attachHost(h, got.value.link, got.value.attached);
		return;
	}
	await v.failed(h, got.error);
}

async function failed(this v: WorkspaceView, h: LinkedHost, e: DialError): Promise<void> {
	match (e.failure) {
		Failure.Offline => { v.offline(h, e.why); },
		Failure.Refused => {
			v.host.report.note(`${v.labelOf(h)}: refused: ${e.why}`);
			h.state = LinkState.Refused;
			h.reason = e.why;
			v.showHosts();
		},
		Failure.Unkept => { await v.unkept(h, e); },
	}
}

async function unkept(this v: WorkspaceView, h: LinkedHost, e: DialError): Promise<void> {
	v.host.report.note(`${v.labelOf(h)}: no session keeping: ${e.why}`);
	await v.dropPanes(h);
	h.inProcess = true;
	h.state = LinkState.Unkept;
	h.reason = e.why;
	h.panes.remote = null;
	h.panes.launch = { ...v.launch, command: e.command, shellScripts: null, startIn: null };
	v.showHosts();
	const pending = v.pendingShow;
	if (h.id == v.primary().id || (pending !== null && pending == h.id)) {
		v.sendTo(h, { kind: CommandKind.NewTab });
	}
}

function offline(this v: WorkspaceView, h: LinkedHost, why: string): void {
	h.state = LinkState.Offline;
	h.reason = why;
	v.showHosts();
	if (h.dial === null || v.quitting) { return; }
	const delay = retryDelayMs(h.failures);
	h.failures += 1;
	v.host.report.note(`${v.labelOf(h)}: offline (${why}); trying again in ${delay} ms`);
	h.retry = setTimeout((): void => {
		h.retry = null;
		const _dialed = v.dialHost(h);
	}, delay);
}

export function retryNow(this v: WorkspaceView, h: LinkedHost): void {
	const pending = h.retry;
	if (pending !== null) { clearTimeout(pending); }
	h.retry = null;
	const _dialed = v.dialHost(h);
}

function lost(this v: WorkspaceView, h: LinkedHost, link: ServerLink | null, why: string): void {
	if (link === null || h.link !== link) { return; }
	h.link = null;
	h.inbox = [];
	v.host.report.note(`server ${v.labelOf(h)}: ${why}`);
	if (h.dial === null) {
		v.focusedModel()?.notify(`Haro lost its server: ${why}. Close this window and open Haro again.`);
	}
	v.offline(h, why);
}

function received(this v: WorkspaceView, h: LinkedHost, link: ServerLink, ms: Message[]): void {
	if (h.link !== link) { return; }
	for (const m of ms) { h.inbox.push(m); }
	if (h.receiving) { return; }
	const _drained = v.drainInbox(h);
}

async function drainInbox(this v: WorkspaceView, h: LinkedHost): Promise<void> {
	h.receiving = true;
	while (h.inbox.length > 0 && !v.quitting) {
		const link = h.link;
		const batch = h.inbox;
		h.inbox = [];
		const feeds: Feed[] = [];
		for (const m of batch) {
			if (v.quitting || h.link !== link) { break; }
			if (m.kind == MessageKind.Output) {
				feeds.add(m.pane, m.seq, m.bytes);
			} else {
				v.feed(h, feeds);
				await v.receive(h, m);
			}
		}
		v.feed(h, feeds);
	}
	h.receiving = false;
}

function feed(this v: WorkspaceView, h: LinkedHost, feeds: Feed[]): void {
	if (feeds.length == 0) { return; }
	const fed: PaneId[] = [];
	for (const f of feeds) {
		const pane = h.panes.paneOf(f.pane);
		if (pane === null) {
			v.host.report.note(
				`server ${v.labelOf(h)}: output for pane ${f.pane as int32}, which this window does not show`,
			);
		} else {
			pane.shell.feed(f.first, f.last, move f.bytes);
			if (!fed.includes(f.pane)) { fed.push(f.pane); }
		}
	}
	feeds.length = 0;
	v.wakePanes(h, fed);
}

function wakePanes(this v: WorkspaceView, h: LinkedHost, ids: PaneId[]): void {
	if (ids.length == 0) { return; }
	v.host.stats.noteWake(performance.now());
	for (const id of ids) {
		const wake = v.hooksOf({ host: h.id, pane: id }).wake;
		if (wake !== null) { wake(); }
	}
}

async function receive(this v: WorkspaceView, h: LinkedHost, m: Message): Promise<void> {
	const parts = screenParts(m);
	if (parts !== null) {
		const layout = parts.layout;
		if (layout !== null) { adopt(h, layout); }
		const remote = h.panes.remote;
		const reseeded: PaneId[] = [];
		for (const s of parts.screens) {
			const pane = h.panes.paneOf(s.pane);
			if (pane !== null) {
				pane.shell.reseed(s.seed);
				reseeded.push(s.pane);
			} else if (remote !== null) {
				remote.screens.push(s);
			}
		}
		v.wakePanes(h, reseeded);
		v.follow(h);
		v.redraw();
		return;
	}
	if (m.kind == MessageKind.Event) {
		await v.applyEvents(h, [m.event]);
	} else if (m.kind == MessageKind.Exited) {
		v.exited({ host: h.id, pane: m.pane }, m.code);
	} else if (m.kind == MessageKind.Failed) {
		v.host.report.note(`pane ${m.pane as int32}: ${m.reason}`);
		v.shellFailed(m.reason);
	} else if (m.kind == MessageKind.Refused) {
		v.lost(h, h.link, `the server refused: ${m.reason}`);
	} else if (m.kind == MessageKind.Bye) {
		v.lost(h, h.link, "the server said goodbye");
	} else {
		v.host.report.note(`server: a window does not take ${m.kind.toString()}`);
	}
}

test "a dropped host waits 1, 2, 4 seconds and so on before it dials again, never more than 30" {
	assert retryDelayMs(0) == 1000;
	assert retryDelayMs(1) == 2000;
	assert retryDelayMs(2) == 4000;
	assert retryDelayMs(4) == 16000;
	assert retryDelayMs(5) == 30000;
	assert retryDelayMs(40) == 30000;
}
