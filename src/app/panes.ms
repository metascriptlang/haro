import { isDir } from "std/fs";
import { hostname } from "std/os";
import { Config } from "../config/config";
import { Shell, closed, opened, portOf } from "../controller/shell";
import { TermError } from "../controller/term";
import { fileUri, isLocalHost } from "../term/pwd";
import { CellRect, PaneId } from "../workspace/tree";
import { EventKind, WorkspaceEvent } from "../workspace/workspace";
import { View, open } from "./frame";
import { Stats } from "./stats";
import { NoticeModel, open } from "./components/features/notice/notice";
import { PasteDialogModel, open } from "./components/features/paste/pasteDialog";
import { CellMetrics } from "./components/ui/cellText";
import {
	Desktop,
	HostEvents,
	KeyHook,
	PaneModel,
	Report,
	ShellHook,
	Timing,
	connectHost,
	fitGrid,
	open,
} from "./components/features/terminal/paneModel";

export enum NewPaneCwd {
	Origin,
	Start,
}

export interface PaneLaunch {
	command: string;
	shellScripts: string | null;
	startIn: string | null;
	cwd: NewPaneCwd;
	recording: string | null;
}

export interface PaneHost {
	desktopFor: (pane: PaneId) => Desktop;
	eventsFor: (pane: PaneId) => HostEvents;
	report: Report;
	timing: Timing;
	keyHook: KeyHook;
	shellHook: ShellHook;
	metrics: CellMetrics;
	started: Config;
	stats: Stats;
}

export interface RunningPane {
	id: PaneId;
	shell: Shell;
	model: PaneModel;
}

export interface Panes {
	launch: PaneLaunch;
	host: PaneHost;
	cellWidth: int32;
	cellHeight: int32;
	focused: PaneId | null;
	running: RunningPane[];
}

export function open(
	this typeof Panes,
	launch: PaneLaunch,
	host: PaneHost,
	cellWidth: int32,
	cellHeight: int32,
): Panes {
	return {
		launch: launch,
		host: host,
		cellWidth: cellWidth,
		cellHeight: cellHeight,
		focused: null,
		running: [],
	};
}

export function paneOf(this p: Panes, id: PaneId): RunningPane | null {
	for (const pane of p.running) {
		if (pane.id == id) { return pane; }
	}
	return null;
}

export async function reportedCwd(this pane: RunningPane): Promise<string | null> {
	const uri = await pane.shell.pwd();
	if (uri === null) { return null; }
	const parsed = fileUri(uri);
	if (!parsed.ok || !isLocalHost(parsed.value.host, hostname())) { return null; }
	return isDir(parsed.value.path) ? parsed.value.path : null;
}

export async function foregroundIsShell(this pane: RunningPane): Promise<boolean> {
	return !(await pane.shell.busy());
}

async function cwdFor(this p: Panes, origin: PaneId | null): Promise<string | null> {
	const start = p.launch.startIn;
	if (p.launch.cwd == NewPaneCwd.Start || origin === null) { return start; }
	const from = p.paneOf(origin);
	if (from === null) { return start; }
	return (await from.reportedCwd()) ?? start;
}

export function refit(this p: Panes, id: PaneId, rect: CellRect): void {
	p.paneOf(id)?.model.fitGrid(rect.cols, rect.rows, p.cellWidth, p.cellHeight);
}

interface Waiting {
	run: (() => void) | null;
}

export function paneTiming(shared: Timing): Timing {
	const slot: Waiting = { run: null };
	return {
		clock: shared.clock,
		schedule: (run: () => void): void => {
			const queued = slot.run !== null;
			slot.run = run;
			if (queued) { return; }
			shared.schedule((): void => {
				const latest = slot.run;
				slot.run = null;
				if (latest !== null) { latest(); }
			});
		},
	};
}

async function start(
	this p: Panes,
	id: PaneId,
	origin: PaneId | null,
	rect: CellRect,
): Promise<TermError | null> {
	const shell = new Shell({
		command: p.launch.command,
		cwd: await p.cwdFor(origin ?? p.focused),
		recording: p.launch.recording,
		shellScripts: p.launch.shellScripts,
	});
	const refused = await opened(shell);
	if (refused !== null) { return refused; }
	const h = p.host;
	const model = PaneModel.open(
		portOf(shell),
		View.open(),
		h.desktopFor(id),
		h.report,
		paneTiming(h.timing),
		h.keyHook,
		h.shellHook,
		h.metrics,
		h.started,
		NoticeModel.open(),
		PasteDialogModel.open(),
		h.stats,
	);
	const pane: RunningPane = { id: id, shell: shell, model: model };
	p.running.push(pane);
	model.connectHost(h.eventsFor(id));
	p.refit(id, rect);
	return null;
}

async function stop(this p: Panes, id: PaneId): Promise<void> {
	const pane = p.paneOf(id);
	if (pane === null) { return; }
	p.running = p.running.filter((r: RunningPane): boolean => !(r.id == id));
	await closed(pane.shell);
}

export async function apply(this p: Panes, e: WorkspaceEvent): Promise<TermError | null> {
	if (e.kind == EventKind.PaneOpened) {
		return await p.start(e.pane, e.origin, e.rect);
	}
	if (e.kind == EventKind.PaneResized) {
		p.refit(e.pane, e.rect);
	} else if (e.kind == EventKind.PaneClosed) {
		await p.stop(e.pane);
	} else if (e.kind == EventKind.FocusChanged) {
		p.focused = e.pane;
	}
	return null;
}
