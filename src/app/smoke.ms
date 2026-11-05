import { frameCounts } from "../../../neon/src/platform/ion/window";
import { Pace } from "./pace";
import { IoPort } from "../controller/io";
import { View, text } from "./frame";
import { exit } from "std/process";
import { Action } from "../input/bindings";
import { CellRect, PaneId } from "../workspace/tree";
import { HostId } from "../workspace/hosted";
import { focusedPane } from "../workspace/workspace";
import { PaneModel } from "./components/features/terminal/paneModel";
import { paneOf } from "./panes";
import { Attached, ServerLink } from "../client/link";
import {
	WorkspaceView,
	attachTo,
	closeShells,
	confirmed,
	detachPanes,
	LinkState,
	addRemote,
	paneAt,
	primary,
	selectTab,
	shownHost,
	sidebarHosts,
	windowAction,
} from "./workspaceView";
import { FakeServer } from "../client/fakeServer";
import { Dial } from "../client/link";


function dump(this view: View, label: string): void {
	console.log(`smoke: ${label}`);
	const n = view.grid.length() as int32;
	for (let i = 0; i < n; i++) {
		const shown = view.text(i);
		if (shown != "") { console.log(`smoke: row ${i}: ${shown}`); }
	}
}

function counts(label: string): void {
	const c = frameCounts();
	console.log(`smoke: ${label}: requested=${c[0]} drawn=${c[1]}`);
}

function numberedLines(count: int32): string {
	when (windows) {
		return `1..${count} | % { "line $_" }\r`;
	} else {
		return `seq 1 ${count} | sed 's/^/line /'\r`;
	}
}

export function smokeReplay(view: View, quit: () => void): void {
	setTimeout((): void => {
		view.dump("replayed");
		counts("after the replay");
		quit();
	}, 3000);
}

export function smoke(io: IoPort, view: View, quit: () => void): void {
	setTimeout((): void => { view.dump("prompt"); counts("after the prompt"); }, 4000);
	setTimeout((): void => {
		io.text(numberedLines(200), performance.now());
		console.log("smoke: sent 200 lines");
	}, 4200);
	setTimeout((): void => { view.dump("after 200 lines"); }, 6500);
	setTimeout((): void => { counts("idle begins"); }, 7000);
	setTimeout((): void => {
		counts("idle 2 s later");
		console.log("smoke: waiting for keys");
	}, 9000);
	setTimeout((): void => {
		view.dump("after keys");
		counts("end");
		quit();
	}, 42000);
}

function shows(this view: View, wanted: string): boolean {
	const n = view.grid.length() as int32;
	for (let i = 0; i < n; i++) {
		if (view.text(i) == wanted) { return true; }
	}
	return false;
}

const FLOOD_LINES: int32 = 200000;
const FLOOD_IDLE_TICKS: int32 = 3;
const FLOOD_MAX_TICKS: int32 = 90;

export function smokeFlood(io: IoPort, view: View, pace: Pace, quit: () => void): void {
	let ticks = 0;
	let doneAt = -1;
	const report = (label: string): void => {
		const c = frameCounts();
		console.log(
			`smoke: ${label}: wakes=${pace.wakes} applies=${pace.applies} ` +
			`requested=${c[0]} drawn=${c[1]}`,
		);
	};
	const tick = (): void => {
		ticks += 1;
		report(`tick ${ticks}`);
		if (doneAt < 0 && view.shows(`line ${FLOOD_LINES}`)) { doneAt = ticks; }
		const finished = doneAt >= 0 && ticks >= doneAt + FLOOD_IDLE_TICKS;
		if (finished || ticks >= FLOOD_MAX_TICKS) {
			console.log(`smoke: flood ${doneAt >= 0 ? "ended" : "did not end"} at tick ${doneAt}`);
			view.dump("after the flood");
			quit();
			return;
		}
		setTimeout(tick, 1000);
	};
	setTimeout((): void => {
		report("before the flood");
		io.text(numberedLines(FLOOD_LINES), performance.now());
		console.log(`smoke: sent ${FLOOD_LINES} lines`);
		setTimeout(tick, 1000);
	}, 4000);
}

const TYPED_KEYS: int32 = 200;
const TYPING_GAP_MS = 50;

export function smokeTyping(io: IoPort, quit: () => void): void {
	let typed = 0;
	const type = (): void => {
		if (typed == TYPED_KEYS) {
			console.log(`smoke: typed ${TYPED_KEYS} keys`);
			setTimeout(quit, 1500);
			return;
		}
		typed += 1;
		io.text(typed % 40 == 0 ? "\r" : "x", performance.now());
		setTimeout(type, TYPING_GAP_MS);
	};
	setTimeout(type, 3000);
}

const PANES_WAIT_MS: float64 = 8000;
const PANES_POLL_MS = 100;

async function pause(ms: number): Promise<int32> {
	return await new Promise<int32>((resolve: (value: int32) => void): void => {
		setTimeout((): void => { resolve(0); }, ms);
	});
}

async function until(holds: () => boolean): Promise<boolean> {
	const start: float64 = performance.now();
	while (!holds()) {
		if (performance.now() - start > PANES_WAIT_MS) { return false; }
		const _waited = await pause(PANES_POLL_MS);
	}
	return true;
}

interface Tally {
	failed: int32;
}

function checked(this t: Tally, ok: boolean, what: string): void {
	console.log(`smoke-panes: ${ok ? "ok" : "FAIL"}: ${what}`);
	if (!ok) { t.failed += 1; }
}

function modelOf(v: WorkspaceView, id: int32): PaneModel | null {
	return v.primary().panes.paneOf(id as PaneId)?.model ?? null;
}

function rectOf(v: WorkspaceView, id: int32): CellRect | null {
	for (const p of v.layout().panes) {
		if (p.pane.id == (id as PaneId)) { return p.rect; }
	}
	return null;
}

function focusedId(v: WorkspaceView): int32 {
	const id = v.primary().w.focusedPane();
	return id === null ? -1 : id as int32;
}

function paneShows(v: WorkspaceView, id: int32, wanted: string): boolean {
	const m = modelOf(v, id);
	return m !== null && m.view.shows(wanted);
}

async function typedInto(
	t: Tally,
	v: WorkspaceView,
	id: int32,
	command: string,
	wanted: string,
): Promise<void> {
	const m = modelOf(v, id);
	if (m === null) {
		t.checked(false, `pane ${id} runs a shell to type into`);
		return;
	}
	m.io.text(`${command}\r`, performance.now());
	const shown = await until((): boolean => paneShows(v, id, wanted));
	t.checked(shown, `pane ${id} shows "${wanted}" after "${command}"`);
	if (!shown) { m.view.dump(`pane ${id}`); }
}

function act(v: WorkspaceView, action: Action): void {
	console.log(`smoke-panes: ${action.toString()}`);
	v.windowAction(action);
}

export async function smokePanes(v: WorkspaceView, stop: () => void): Promise<void> {
	const t: Tally = { failed: 0 };
	t.checked(await until((): boolean => v.cols > 0 && v.primary().panes.cellWidth > 0),
		"the window laid out a grid of cells");
	const _prompt = await pause(1500);
	await typedInto(t, v, 1, "echo hi-1", "hi-1");

	act(v, Action.SplitRight);
	t.checked(await until((): boolean => focusedId(v) == 2 && modelOf(v, 2) !== null),
		"split right opens pane 2 and focuses it");
	act(v, Action.SplitDown);
	t.checked(await until((): boolean => focusedId(v) == 3 && modelOf(v, 3) !== null),
		"split down opens pane 3 under pane 2 and focuses it");
	const left = rectOf(v, 1);
	const top = rectOf(v, 2);
	const below = rectOf(v, 3);
	t.checked(
		left !== null && top !== null && below !== null &&
			left.cols + 1 + top.cols == v.cols &&
			top.rows + 1 + below.rows == v.rows &&
			below.x == top.x,
		`three panes tile ${v.cols}x${v.rows} cells with one-cell dividers`,
	);
	t.checked(v.layout().segments.length > 0, "the frame draws dividers");
	const _settled = await pause(1500);
	await typedInto(t, v, 2, "echo hi-2", "hi-2");
	await typedInto(t, v, 3, "echo hi-3", "hi-3");
	const m3 = modelOf(v, 3);
	t.checked(
		m3 !== null && below !== null && m3.cols == below.cols && m3.rows == below.rows,
		"pane 3's grid is its cell rect",
	);

	act(v, Action.TogglePaneZoom);
	t.checked(await until((): boolean => v.layout().panes.length == 1),
		"zoom shows only the focused pane");
	const zoomed = rectOf(v, 3);
	t.checked(zoomed !== null && zoomed.cols == v.cols && zoomed.rows == v.rows,
		"the zoomed pane fills the tab");
	act(v, Action.TogglePaneZoom);
	t.checked(await until((): boolean => v.layout().panes.length == 3),
		"zoom off shows all three panes again");

	act(v, Action.NewTab);
	t.checked(await until((): boolean => v.primary().w.tabs.length == 2 && modelOf(v, 4) !== null),
		"a new tab opens pane 4");
	t.checked(v.tabs()[0].tabs.length == 2 && v.tabs()[0].tabs[1].active,
		"the sidebar lists two tabs, the new one active");
	await typedInto(t, v, 4, "echo hi-4", "hi-4");
	act(v, Action.PreviousTab);
	t.checked(await until((): boolean => v.layout().panes.length == 3 && focusedId(v) == 3),
		"previous tab shows the first tab's three panes, pane 3 focused");
	act(v, Action.GotoTab2);
	t.checked(await until((): boolean => focusedId(v) == 4), "goto tab 2 focuses pane 4");
	act(v, Action.ClosePane);
	t.checked(await until((): boolean => v.primary().w.tabs.length == 1 && modelOf(v, 4) === null),
		"closing an idle shell's pane closes it at once, and its tab with it");
	t.checked(!v.confirm.visible(), "no dialog asked for an idle shell");

	const busy = modelOf(v, 3);
	if (busy !== null) { busy.io.text("sleep 30\r", performance.now()); }
	const _started = await pause(1000);
	act(v, Action.ClosePane);
	t.checked(await until((): boolean => v.confirm.visible()),
		"closing a pane running sleep asks first");
	t.checked(modelOf(v, 3) !== null, "the asked pane still runs");
	v.confirmed();
	t.checked(await until((): boolean => modelOf(v, 3) === null && !v.confirm.visible()),
		"confirming closes the pane");
	t.checked(await until((): boolean => v.layout().panes.length == 2),
		"the closed pane's sibling takes its place");

	console.log(`smoke-panes: ${t.failed == 0 ? "PASS" : `FAIL ${t.failed}`}`);
	await v.closeShells();
	stop();
	exit(t.failed == 0 ? 0 : 1);
}

function paneHas(v: WorkspaceView, id: int32, wanted: string): boolean {
	const view = modelOf(v, id)?.view ?? null;
	if (view === null) { return false; }
	const n = view.grid.length() as int32;
	for (let i = 0; i < n; i++) {
		if (view.text(i).includes(wanted)) { return true; }
	}
	return false;
}

export interface Reattach {
	link: ServerLink;
	attached: Attached;
}

async function typedMarker(t: Tally, v: WorkspaceView, id: int32, marker: string): Promise<void> {
	const m = modelOf(v, id);
	if (m === null) {
		t.checked(false, `pane ${id} is open to type into`);
		return;
	}
	m.io.text(`echo ${marker}\r`, performance.now());
	t.checked(await until((): boolean => paneHas(v, id, marker)), `pane ${id} shows ${marker}`);
}

async function reattached(
	t: Tally,
	v: WorkspaceView,
	reconnect: () => Promise<Result<Reattach, string>>,
): Promise<boolean> {
	await v.detachPanes();
	t.checked(v.primary().panes.running.length == 0, "the window dropped its panes and its connection");
	const again = await reconnect();
	if (!again.ok) {
		t.checked(false, `the window reconnected: ${again.error}`);
		return false;
	}
	await v.attachTo(again.value.link, again.value.attached);
	return true;
}

export async function smokeAttach(
	v: WorkspaceView,
	reconnect: () => Promise<Result<Reattach, string>>,
	stopServer: () => void,
): Promise<void> {
	const t: Tally = { failed: 0 };
	t.checked(await until((): boolean => v.cols > 0 && v.primary().panes.cellWidth > 0 && modelOf(v, 1) !== null),
		"the window attached and shows the server's first pane");
	await typedMarker(t, v, 1, "attach-1");
	act(v, Action.SplitRight);
	t.checked(await until((): boolean => focusedId(v) == 2 && modelOf(v, 2) !== null),
		"split right asks the server, which opens pane 2");
	await typedMarker(t, v, 2, "attach-2");
	if (await reattached(t, v, reconnect)) {
		t.checked(
			await until((): boolean => paneHas(v, 1, "attach-1") && paneHas(v, 2, "attach-2")),
			"after reconnecting, both panes show their text",
		);
	}
	modelOf(v, 1)?.io.text("printf 'under%salt\\n' -; printf '\\033[?1049h\\033[2J\\033[Hon%salt' -\r", performance.now());
	t.checked(await until((): boolean => paneHas(v, 1, "on-alt")), "pane 1 entered the alternate screen");
	if (await reattached(t, v, reconnect)) {
		t.checked(
			await until((): boolean => paneHas(v, 1, "on-alt") && !paneHas(v, 1, "under-alt")),
			"after reconnecting, pane 1 still shows the alternate screen",
		);
		modelOf(v, 1)?.io.text("printf '\\033[?1049l'\r", performance.now());
		t.checked(
			await until((): boolean => paneHas(v, 1, "under-alt") && paneHas(v, 1, "attach-1")),
			"leaving the alternate screen shows the normal screen kept across the reconnect",
		);
	}
	console.log(`smoke-attach: ${t.failed == 0 ? "PASS" : `FAIL ${t.failed}`}`);
	await v.detachPanes();
	stopServer();
	exit(t.failed == 0 ? 0 : 1);
}

function hostPaneHas(v: WorkspaceView, host: HostId, id: int32, wanted: string): boolean {
	const view = v.paneAt({ host: host, pane: id as PaneId })?.model.view ?? null;
	if (view === null) { return false; }
	const n = view.grid.length() as int32;
	for (let i = 0; i < n; i++) {
		if (view.text(i).includes(wanted)) { return true; }
	}
	return false;
}

export async function smokeHosts(
	v: WorkspaceView,
	fake: FakeServer,
	dial: Dial,
	stop: () => void,
): Promise<void> {
	const t: Tally = { failed: 0 };
	t.checked(await until((): boolean => v.cols > 0 && modelOf(v, 1) !== null),
		"the window attached to the local server and shows its pane 1");
	await typedMarker(t, v, 1, "local-1");
	const remote = v.addRemote("fake", dial);
	t.checked(await until((): boolean => remote.state == LinkState.Connected && remote.panes.running.length == 1),
		"the fake remote host attached and opened its pane 1");
	const hosts = v.sidebarHosts();
	t.checked(hosts.length == 2 && hosts[0].label == "local" && hosts[1].label == "fake" &&
		hosts[1].tabs.length == 1, "the sidebar groups one tab under local and one under fake");
	t.checked(await until((): boolean => hostPaneHas(v, remote.id, 1, "remote-marker")),
		"the remote pane 1 shows the fake server's screen");
	t.checked(!paneHas(v, 1, "remote-marker"), "the local pane 1 does not show the remote's screen");
	v.selectTab({ host: remote.id, tab: remote.w.tabs[0].id });
	t.checked(await until((): boolean => v.layout().panes.length == 1 && v.shownHost().id == remote.id),
		"selecting the remote tab shows its pane");
	v.paneAt({ host: remote.id, pane: 1 as PaneId })?.model.io.text("echo to-fake\r", performance.now());
	t.checked(await until((): boolean => (fake.paneOf(1 as PaneId)?.seq ?? 0) > 0),
		"typing in the remote pane reaches the fake server");
	t.checked(await until((): boolean => hostPaneHas(v, remote.id, 1, "to-fake")),
		"the remote pane shows what the fake server echoed");
	fake.latest?.close();
	t.checked(await until((): boolean => remote.state == LinkState.Offline),
		"dropping the fake server's connection marks its host offline");
	t.checked(v.sidebarHosts()[1].tabs.length == 1, "the offline host's tab stays listed");
	t.checked(await until((): boolean => remote.state == LinkState.Connected),
		"the host reconnects after its first backoff");
	v.windowAction(Action.GotoTab1);
	t.checked(await until((): boolean => v.shownHost().id == v.primary().id),
		"goto tab 1 shows the local tab again");
	await typedMarker(t, v, 1, "local-2");
	console.log(`smoke-hosts: ${t.failed == 0 ? "PASS" : `FAIL ${t.failed}`}`);
	await v.detachPanes();
	stop();
	exit(t.failed == 0 ? 0 : 1);
}
