import { Shell, closed, localCwd, opened } from "../controller/shell";
import { Drained, label } from "../controller/io";
import { TermError } from "../controller/term";
import { CellRect, PaneId } from "../workspace/tree";
import { EventKind, WorkspaceEvent } from "../workspace/workspace";
import { ScreenFormat } from "./protocol";

export interface HostLaunch {
	command: string;
	shellScripts: string | null;
	startIn: string | null;
	originCwd: boolean;
}

export interface PaneSink {
	output: (pane: PaneId, seq: int64, bytes: Readonly<Span<uint8>>) => void;
	exit: (pane: PaneId, code: int32) => void;
	failed: (pane: PaneId, failure: string) => void;
}

export enum PaneHostError {
	UnknownPane,
	SnapshotUnavailable,
	SnapshotTooLarge,
}

export struct Shot {
	format: ScreenFormat;
	bytes: Vec<uint8>;
}

export interface HostedPane {
	id: PaneId;
	shell: Shell;
	typedAt: float64;
}

const TYPED_RECENTLY_MS: float64 = 50;

export interface PaneHost {
	launch: HostLaunch;
	sink: PaneSink;
	focused: PaneId | null;
	panes: HostedPane[];
}

export function open(this typeof PaneHost, launch: HostLaunch, sink: PaneSink): PaneHost {
	return { launch: launch, sink: sink, focused: null, panes: [] };
}

export function paneOf(this h: PaneHost, id: PaneId): HostedPane | null {
	for (const pane of h.panes) {
		if (pane.id == id) { return pane; }
	}
	return null;
}

async function cwdFor(this h: PaneHost, origin: PaneId | null): Promise<string | null> {
	const start = h.launch.startIn;
	if (!h.launch.originCwd || origin === null) { return start; }
	const from = h.paneOf(origin);
	if (from === null) { return start; }
	return (await localCwd(from.shell)) ?? start;
}

function deliver(this h: PaneHost, id: PaneId, drained: Drained): TermError | null {
	let refused: TermError | null = null;
	for (const f of drained.failures) {
		if (!f.started && refused === null) { refused = f.error; }
		h.sink.failed(id, `${f.where.label()}: ${f.error}`);
	}
	for (let i = 0; i < drained.output.length; i++) {
		h.sink.output(id, drained.output[i].seq, drained.output[i].bytes);
	}
	const exit = drained.exit;
	if (exit !== null) { h.sink.exit(id, exit.code); }
	return refused;
}

async function start(
	this h: PaneHost,
	id: PaneId,
	origin: PaneId | null,
	rect: CellRect,
): Promise<TermError | null> {
	const shell = new Shell({
		command: h.launch.command,
		cwd: await h.cwdFor(origin ?? h.focused),
		recording: null,
		shellScripts: h.launch.shellScripts,
	}, true);
	const refused = await opened(shell);
	if (refused !== null) { return refused; }
	shell.fit(rect.cols, rect.rows, 0, 0);
	const first = await shell.output();
	const failed = first === null ? null : h.deliver(id, first);
	if (failed !== null) {
		await closed(shell);
		return failed;
	}
	h.panes.push({ id: id, shell: shell, typedAt: -TYPED_RECENTLY_MS });
	return null;
}

async function stop(this h: PaneHost, id: PaneId): Promise<void> {
	const pane = h.paneOf(id);
	if (pane === null) { return; }
	h.panes = h.panes.filter((p: HostedPane): boolean => !(p.id == id));
	await closed(pane.shell);
}

export function resize(this h: PaneHost, id: PaneId, cols: int32, rows: int32): void {
	const pane = h.paneOf(id);
	if (pane === null) { return; }
	pane.shell.fit(cols, rows, 0, 0);
	pane.shell.settleSize();
}

export async function apply(this h: PaneHost, e: WorkspaceEvent): Promise<TermError | null> {
	if (e.kind == EventKind.PaneOpened) {
		return await h.start(e.pane, e.origin, e.rect);
	}
	if (e.kind == EventKind.PaneResized) {
		h.resize(e.pane, e.rect.cols, e.rect.rows);
	} else if (e.kind == EventKind.PaneClosed) {
		await h.stop(e.pane);
	} else if (e.kind == EventKind.FocusChanged) {
		h.focused = e.pane;
	}
	return null;
}

function typedFirst(panes: HostedPane[]): HostedPane[] {
	const now = performance.now();
	const typed = panes.filter((p: HostedPane): boolean => now - p.typedAt < TYPED_RECENTLY_MS);
	const rest = panes.filter((p: HostedPane): boolean => !(now - p.typedAt < TYPED_RECENTLY_MS));
	return [...typed, ...rest];
}

export async function pump(this h: PaneHost): Promise<boolean> {
	const order = typedFirst(h.panes);
	const drains = order.map((pane: HostedPane): Promise<Drained | null> => pane.shell.output());
	let more = false;
	for (let i = 0; i < order.length; i++) {
		const drained = await drains[i];
		if (drained !== null) {
			const _refused = h.deliver(order[i].id, drained);
			more = more || drained.more;
		}
	}
	return more;
}

export function write(this h: PaneHost, id: PaneId, bytes: Vec<uint8>): boolean {
	const pane = h.paneOf(id);
	if (pane === null) { return false; }
	pane.shell.write(bytes);
	pane.typedAt = performance.now();
	return true;
}

export async function busy(this h: PaneHost, id: PaneId): Promise<boolean> {
	const pane = h.paneOf(id);
	return pane !== null && (await pane.shell.busy());
}

export async function pwd(this h: PaneHost, id: PaneId): Promise<string | null> {
	const pane = h.paneOf(id);
	if (pane === null) { return null; }
	return await pane.shell.pwd();
}

export async function title(this h: PaneHost, id: PaneId): Promise<string | null> {
	const pane = h.paneOf(id);
	if (pane === null) { return null; }
	return await pane.shell.title();
}

export async function snapshot(
	this h: PaneHost,
	id: PaneId,
	wanted: ScreenFormat,
	limit: int32,
): Promise<Result<Shot, PaneHostError>> {
	const pane = h.paneOf(id);
	if (pane === null) { return Result.err(PaneHostError.UnknownPane); }
	if (wanted == ScreenFormat.Native) {
		const native = await pane.shell.snapshot(true);
		if (native !== null && native.length <= limit) {
			return Result.ok({ format: ScreenFormat.Native, bytes: native });
		}
	}
	const replayed = await pane.shell.snapshot(false);
	if (replayed === null) { return Result.err(PaneHostError.SnapshotUnavailable); }
	if (replayed.length > limit) { return Result.err(PaneHostError.SnapshotTooLarge); }
	return Result.ok({ format: ScreenFormat.VtBytes, bytes: replayed });
}

export async function closeAll(this h: PaneHost): Promise<void> {
	const all = h.panes;
	h.panes = [];
	for (const pane of all) { await closed(pane.shell); }
}
