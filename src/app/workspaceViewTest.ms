import { removeAll } from "std/fs";
import { join } from "std/fs/path";
import { tmpDir } from "std/os";
import { CloseReason, Connection, connectToUnix, listenUnix } from "../server/transport";
import { MAX_SCREEN_BYTES, Message, MessageKind, ScreenFormat, encode } from "../server/protocol";
import { append } from "../pty/bytes";
import { Server, start, stop } from "../server/serve";
import { defaults } from "../config/config";
import { HookPane, KeyAnswer, UNHANDLED } from "../config/hooks";
import { KeyEvent } from "../keys/keys";
import { CommandDone, writeText } from "../vt/vt";
import { Action } from "../input/bindings";
import { vtBuild } from "../vt/snapshot";
import { Axis, PaneId, panes } from "../workspace/tree";
import { HostId, HostPane } from "../workspace/hosted";
import { CommandKind, focusedPane } from "../workspace/workspace";
import { DialError, Failure, ServerLink, attach } from "../client/link";
import { FakeServer, startFake } from "../client/fakeServer";
import { dialUnix } from "../client/connect";
import { Stats, empty } from "./stats";
import { ConfigChange } from "./components/features/terminal/paneModel";
import { paneOf } from "./panes";
import {
	WindowHost,
	WorkspaceView,
	attachTo,
	connect,
	detachPanes,
	LinkState,
	LinkedHost,
	addRemote,
	newTabOn,
	open,
	paneAt,
	primary,
	quit,
	retryNow,
	selectTab,
	send,
	shownHost,
	sidebarHosts,
	windowAction,
} from "./workspaceView";

const WAIT_MS: float64 = 10000;

let dirs: int32 = 0;

function freshPath(): string {
	dirs += 1;
	return join(join(tmpDir(), `haro-view-${Date.now()}-${dirs}`), "s.sock");
}

function cleanUp(path: string): void {
	const _removed = removeAll(path.slice(0, path.lastIndexOf("/")));
}

async function until(done: () => boolean): Promise<boolean> {
	const start = performance.now();
	while (!done()) {
		if (performance.now() - start > WAIT_MS) { return false; }
		await sleepAsync(2);
	}
	return true;
}

async function linked(path: string): Promise<ServerLink> {
	const got = await connectToUnix(path, 2000);
	if (!got.ok) { throw new Error(`no connection to ${path}`); }
	const link = new ServerLink(got.value);
	link.begin();
	return link;
}

function fakeWithTwoPanes(path: string): FakeServer {
	const fake = startFake(path, ScreenFormat.Native);
	if (!fake.ok) { throw new Error(`the fake server did not listen: ${fake.error.toString()}`); }
	const f = fake.value;
	const _tab = f.apply({ kind: CommandKind.NewTab });
	const _split = f.apply({ kind: CommandKind.Split, pane: 1 as PaneId, axis: Axis.SideBySide });
	f.paneOf(1 as PaneId)?.vt.writeText("one-marker\r\n");
	f.paneOf(2 as PaneId)?.vt.writeText("two-marker\r\n");
	return f;
}

class Notes {
	lines: string[] = [];
	fatal: string = "";
	woke: () => void = (): void => {};
	wakes: int32 = 0;
	due: (() => void)[] = [];
}

function hostOf(notes: Notes): WindowHost {
	return {
		setTitle: (title: string, belled: boolean): void => {},
		notify: (title: string, body: string): void => {},
		openLink: (uri: string): void => {},
		attention: (): void => {},
		setHand: (on: boolean): void => {},
		openConfig: (): void => {},
		reloadConfig: (): void => {},
		quit: (): void => {},
		wake: (): void => {
			notes.wakes += 1;
			notes.woke();
		},
		report: {
			note: (message: string): void => { notes.lines.push(message); },
			fail: (message: string): void => { notes.fatal = message; },
		},
		timing: {
			clock: (): float64 => performance.now(),
			schedule: (run: () => void): void => { notes.due.push(run); },
		},
		keyHook: {
			answer: (pane: HookPane, k: KeyEvent): Result<KeyAnswer, string> => Result.ok(UNHANDLED),
		},
		shellHook: {
			prompted: (pane: HookPane, at: int32): Result<void, string> => Result.ok(null),
			commandDone: (pane: HookPane, done: CommandDone): Result<void, string> => Result.ok(null),
		},
		events: {
			onWake: (handler: () => void): void => { notes.woke = handler; },
			onMenu: (handler: (id: string) => void): void => {},
			onCloseRequest: (handler: () => void): void => {},
			onConfig: (handler: (change: ConfigChange) => void): void => {},
		},
		stats: Stats.empty(),
		fontFamily: "",
	};
}

async function screenOf(v: WorkspaceView, id: int32): Promise<string> {
	const pane = v.primary().panes.paneOf(id as PaneId);
	if (pane === null) { return "<no pane>"; }
	const shot = await pane.shell.snapshot();
	if (shot === null) { return "<no screen>"; }
	return shot.asString();
}

async function shows(v: WorkspaceView, id: int32, wanted: string): Promise<boolean> {
	const start = performance.now();
	while (performance.now() - start < WAIT_MS) {
		if ((await screenOf(v, id)).includes(wanted)) { return true; }
		await sleepAsync(5);
	}
	return false;
}

function treeIds(v: WorkspaceView): string {
	const ids: string[] = [];
	for (const tab of v.primary().w.tabs) {
		for (const p of tab.root.panes()) { ids.push(`${p.id as int32}`); }
	}
	return ids.join(",");
}

function runningIds(v: WorkspaceView): string {
	return v.primary().panes.running.map((r): string => `${r.id as int32}`).join(",");
}

function focusedIs(v: WorkspaceView, id: int32): boolean {
	const f = v.primary().w.focusedPane();
	return f !== null && f == (id as PaneId);
}

test "a window over a real socket shows the server's panes, sends typing as input, and follows the server's events" {
	const path = freshPath();
	const fake = fakeWithTwoPanes(path);
	const notes = new Notes();
	const link = await linked(path);
	const got = await attach(link, vtBuild(), 80, 24, 5000);
	assert got.ok;
	if (!got.ok) { return; }
	const v = WorkspaceView.open(hostOf(notes), defaults(), "", null, null, null, link, got.value);
	v.connect();
	await v.attachTo(link, got.value);
	assert runningIds(v) == "1,2";
	assert treeIds(v) == "1,2";
	assert await shows(v, 1, "one-marker");
	assert await shows(v, 2, "two-marker");

	v.primary().panes.paneOf(1 as PaneId)?.model.io.text("typed-in\r", 0);
	assert await shows(v, 1, "typed-in");
	assert fake.paneOf(1 as PaneId)?.seq == 1;

	v.send({ kind: CommandKind.Split, pane: 2 as PaneId, axis: Axis.Stacked });
	assert await until((): boolean => runningIds(v) == "1,2,3" && treeIds(v) == "1,2,3" && focusedIs(v, 3));
	v.send({ kind: CommandKind.ClosePane, pane: 1 as PaneId });
	assert await until((): boolean => runningIds(v) == "2,3" && treeIds(v) == "2,3");
	assert notes.fatal == "";

	await v.detachPanes();
	assert await until((): boolean => fake.byes == 1);
	assert v.primary().panes.running.length == 0;
	assert fake.panes.length == 2;

	const again = await linked(path);
	const reattached = await attach(again, vtBuild(), 80, 24, 5000);
	assert reattached.ok;
	if (reattached.ok) {
		await v.attachTo(again, reattached.value);
		assert runningIds(v) == "2,3";
		assert await shows(v, 2, "two-marker");
	}
	await v.detachPanes();
	fake.close();
	cleanUp(path);
}

test "a window shows the server's pane exit and start failure the way an in-process shell does, and the server closes the pane" {
	const path = freshPath();
	const fake = fakeWithTwoPanes(path);
	const notes = new Notes();
	const link = await linked(path);
	const got = await attach(link, vtBuild(), 80, 24, 5000);
	assert got.ok;
	if (!got.ok) { return; }
	const v = WorkspaceView.open(hostOf(notes), defaults(), "", null, null, null, link, got.value);
	v.connect();
	await v.attachTo(link, got.value);
	fake.endPane(1 as PaneId, { kind: MessageKind.Exited, pane: 1 as PaneId, code: 3 });
	assert await until((): boolean => runningIds(v) == "2" && treeIds(v) == "2"), runningIds(v);
	assert notes.lines.includes("pane 1: the shell exited with code 3"), notes.lines.join("\n");
	fake.endPane(2 as PaneId, { kind: MessageKind.Failed, pane: 2 as PaneId, reason: "no such shell" });
	assert await until((): boolean => notes.lines.includes("the last pane closed")), notes.lines.join("\n");
	assert notes.lines.includes("pane 2: no such shell"), notes.lines.join("\n");
	assert notes.fatal == "";
	fake.close();
	cleanUp(path);
}

function chunkOf(messages: Message[]): uint8[] {
	const chunk: uint8[] = [];
	for (const m of messages) {
		const bytes = encode(m);
		if (!bytes.ok) { throw new Error(`encode: ${bytes.error.toString()}`); }
		chunk.append(bytes.value);
	}
	return chunk;
}

function outputs(pane: int32, from: uint64, count: int32, word: string): Message[] {
	const out: Message[] = [];
	for (let i: int32 = 0; i < count; i++) {
		const text = `${word}-${i}\r\n`;
		out.push({ kind: MessageKind.Output, pane: pane as PaneId, seq: from + (i as uint64), bytes: [...text.asBytes()] });
	}
	return out;
}

async function noted(notes: Notes, text: string): Promise<boolean> {
	const start = performance.now();
	while (performance.now() - start < WAIT_MS) {
		if (notes.lines.some((l: string): boolean => l.includes(text))) { return true; }
		const due = notes.due;
		notes.due = [];
		for (const run of due) { run(); }
		await sleepAsync(10);
	}
	return false;
}

async function settled(notes: Notes): Promise<boolean> {
	for (let i: int32 = 0; i < 50; i++) {
		const due = notes.due;
		notes.due = [];
		for (const run of due) { run(); }
		await sleepAsync(20);
		if (notes.due.length == 0) { return true; }
	}
	return false;
}

test "many outputs that arrive together wake only their pane, as one feed and one frame request" {
	const path = freshPath();
	const fake = fakeWithTwoPanes(path);
	const notes = new Notes();
	const link = await linked(path);
	const got = await attach(link, vtBuild(), 80, 24, 5000);
	assert got.ok;
	if (!got.ok) { return; }
	const v = WorkspaceView.open(hostOf(notes), defaults(), "", null, null, null, link, got.value);
	v.connect();
	await v.attachTo(link, got.value);
	assert await shows(v, 1, "one-marker");
	assert await settled(notes);
	const wakes = notes.wakes;
	link.received(chunkOf(outputs(1, 1, 50, "burst")));
	assert notes.wakes == wakes, `${notes.wakes - wakes} window-wide wakes`;
	assert notes.due.length == 1, `${notes.due.length} frame requests`;
	assert await shows(v, 1, "burst-49");
	assert notes.fatal == "";
	await v.detachPanes();
	fake.close();
	cleanUp(path);
}

test "typing in quick succession reaches the server in the order it was typed" {
	const path = freshPath();
	const fake = fakeWithTwoPanes(path);
	const notes = new Notes();
	const link = await linked(path);
	const got = await attach(link, vtBuild(), 80, 24, 5000);
	assert got.ok;
	if (!got.ok) { return; }
	const v = WorkspaceView.open(hostOf(notes), defaults(), "", null, null, null, link, got.value);
	v.connect();
	await v.attachTo(link, got.value);
	const io = v.primary().panes.paneOf(1 as PaneId)?.model.io ?? null;
	assert io !== null;
	if (io === null) { return; }
	let wanted = "";
	for (let i: int32 = 0; i < 30; i++) {
		io.text(`${i}.`, 0);
		wanted += `${i}.`;
	}
	assert await until((): boolean => seqOf(fake, 1) == 30), `${seqOf(fake, 1)} inputs`;
	assert await shows(v, 1, wanted), await screenOf(v, 1);
	assert notes.fatal == "";
	await v.detachPanes();
	fake.close();
	cleanUp(path);
}

test "a screen in the middle of a pane's output replaces its terminal, answers no query, and later output follows it" {
	const path = freshPath();
	const fake = fakeWithTwoPanes(path);
	const notes = new Notes();
	const link = await linked(path);
	const got = await attach(link, vtBuild(), 80, 24, 5000);
	assert got.ok;
	if (!got.ok) { return; }
	const v = WorkspaceView.open(hostOf(notes), defaults(), "", null, null, null, link, got.value);
	v.connect();
	await v.attachTo(link, got.value);
	assert await shows(v, 1, "one-marker");
	const jump = "\x1b[2J\x1b[Hjumped-marker\r\n\x1b[c\x1b[6n";
	const messages = outputs(1, 1, 1, "before");
	messages.push({
		kind: MessageKind.Screen,
		pane: 1 as PaneId,
		cols: 80,
		rows: 24,
		format: ScreenFormat.VtBytes,
		bytes: [...jump.asBytes()],
	});
	for (const m of outputs(1, 7, 2, "after")) { messages.push(m); }
	link.received(chunkOf(messages));
	assert await shows(v, 1, "after-1"), await screenOf(v, 1);
	const shown = await screenOf(v, 1);
	assert shown.includes("jumped-marker") && shown.includes("after-0"), shown;
	assert !shown.includes("one-marker") && !shown.includes("before-0"), shown;
	link.received(chunkOf(outputs(1, 8, 1, "stale")));
	assert await noted(notes, "OutOfOrder"), notes.lines.join("\n");
	await sleepAsync(100);
	assert seqOf(fake, 1) == 0, `the replay answered ${seqOf(fake, 1)} times`;
	await v.detachPanes();
	fake.close();
	cleanUp(path);
}

test "closing a server pane asks first only when the server says its shell runs a program" {
	const path = freshPath();
	const fake = fakeWithTwoPanes(path);
	fake.busyPanes = [2 as PaneId];
	const notes = new Notes();
	const link = await linked(path);
	const got = await attach(link, vtBuild(), 80, 24, 5000);
	assert got.ok;
	if (!got.ok) { return; }
	const v = WorkspaceView.open(hostOf(notes), defaults(), "", null, null, null, link, got.value);
	v.connect();
	await v.attachTo(link, got.value);
	v.askClosePane({ host: 0 as HostId, pane: 1 as PaneId });
	assert await until((): boolean => runningIds(v) == "2"), runningIds(v);
	assert !v.confirm.visible();
	v.askClosePane({ host: 0 as HostId, pane: 2 as PaneId });
	assert await until((): boolean => v.confirm.visible());
	assert runningIds(v) == "2";
	await v.detachPanes();
	fake.close();
	cleanUp(path);
}

test "the first window of a fresh real server shows its first shell's opening output" {
	when (!windows) {
		const path = freshPath();
		const started = await Server.start({
			launch: {
				command: "printf 'opening%swords\\n' -; exec sh",
				shellScripts: null,
				startIn: null,
				originCwd: false,
			},
			socket: path,
			dividerCells: 1,
			tailnet: null,
			screenLimit: MAX_SCREEN_BYTES,
			log: (line: string): void => {},
		});
		assert started.ok;
		if (!started.ok) { return; }
		const notes = new Notes();
		const link = await linked(path);
		const got = await attach(link, vtBuild(), 80, 24, 5000);
		assert got.ok;
		if (!got.ok) { return; }
		const v = WorkspaceView.open(hostOf(notes), defaults(), "", null, null, null, link, got.value);
	v.connect();
		await v.attachTo(link, got.value);
		assert await shows(v, 1, "opening-words"), await screenOf(v, 1);
		await v.detachPanes();
		started.value.stop(0);
		const _done = await started.value.finished;
		cleanUp(path);
	}
}

async function screenAt(v: WorkspaceView, at: HostPane): Promise<string> {
	const pane = v.paneAt(at);
	if (pane === null) { return "<no pane>"; }
	const _frame = await pane.shell.frame();
	const shot = await pane.shell.snapshot();
	return shot === null ? "<no screen>" : shot.asString();
}

async function showsAt(v: WorkspaceView, at: HostPane, wanted: string): Promise<boolean> {
	const start = performance.now();
	while (performance.now() - start < WAIT_MS) {
		if ((await screenAt(v, at)).includes(wanted)) { return true; }
		await sleepAsync(5);
	}
	return false;
}

function at(h: LinkedHost, pane: int32): HostPane {
	return { host: h.id, pane: pane as PaneId };
}

function seqOf(fake: FakeServer, pane: int32): uint64 {
	return fake.paneOf(pane as PaneId)?.seq ?? (99 as uint64);
}

interface TwoHosts {
	v: WorkspaceView;
	notes: Notes;
	local: FakeServer;
	remote: FakeServer;
	paths: string[];
	build: LinkedHost;
}

async function twoHosts(): Promise<TwoHosts> {
	const localPath = freshPath();
	const remotePath = freshPath();
	const local = fakeWithTwoPanes(localPath);
	const remote = fakeWithTwoPanes(remotePath);
	remote.paneOf(1 as PaneId)?.vt.writeText("remote-marker\r\n");
	const notes = new Notes();
	const link = await linked(localPath);
	const got = await attach(link, vtBuild(), 80, 24, 5000);
	if (!got.ok) { throw new Error(`attach: ${got.error.why}`); }
	const v = WorkspaceView.open(hostOf(notes), defaults(), "", null, null, null, link, got.value);
	v.connect();
	await v.attachTo(link, got.value);
	const build = v.addRemote("build", dialUnix(remotePath));
	v.retryNow(build);
	return { v: v, notes: notes, local: local, remote: remote, paths: [localPath, remotePath], build: build };
}

async function closeAll(t: TwoHosts): Promise<void> {
	await t.v.quit();
	t.local.close();
	t.remote.close();
	for (const p of t.paths) { cleanUp(p); }
}

test "two servers' tabs list grouped by host, typing reaches its own server, and equal pane ids stay apart" {
	const t = await twoHosts();
	const v = t.v;
	const b = t.build;
	assert await until((): boolean => b.state == LinkState.Connected && b.panes.running.length == 2);
	const hosts = v.sidebarHosts();
	assert hosts.length == 2;
	assert hosts[0].label == "local" && hosts[0].header && hosts[0].tabs.length == 1;
	assert hosts[1].label == "build" && hosts[1].state == "" && hosts[1].tabs.length == 1;
	const local1 = at(v.primary(), 1);
	const remote1 = at(b, 1);
	assert !(local1 == remote1);
	assert await showsAt(v, local1, "one-marker");
	assert await showsAt(v, remote1, "remote-marker");
	assert !(await screenAt(v, local1)).includes("remote-marker");

	v.paneAt(remote1)?.model.io.text("to-remote\r", 0);
	assert await until((): boolean => seqOf(t.remote, 1) == 1);
	assert seqOf(t.local, 1) == 0;
	assert await showsAt(v, remote1, "to-remote");
	v.paneAt(local1)?.model.io.text("to-local\r", 0);
	assert await until((): boolean => seqOf(t.local, 1) == 1);
	assert seqOf(t.remote, 1) == 1;

	v.selectTab({ host: b.id, tab: b.w.tabs[0].id });
	assert v.shownHost().id == b.id;
	v.windowAction(Action.SplitRight);
	assert await until((): boolean => t.remote.panes.length == 3 && b.panes.running.length == 3);
	assert t.local.panes.length == 2;
	v.windowAction(Action.GotoTab1);
	assert await until((): boolean => v.shownHost().id == v.primary().id);
	v.windowAction(Action.NextTab);
	assert await until((): boolean => v.shownHost().id == b.id);
	assert t.notes.fatal == "";
	await closeAll(t);
}

test "a dropped server's tabs stay listed offline while the other works, and its reconnect rebuilds its screens" {
	const t = await twoHosts();
	const v = t.v;
	const b = t.build;
	assert await until((): boolean => b.state == LinkState.Connected && b.panes.running.length == 2);
	t.remote.latest?.close();
	assert await until((): boolean => b.state == LinkState.Offline);
	const down = v.sidebarHosts()[1];
	assert down.state == "offline" && !down.live && down.tabs.length == 1;
	assert down.reason != "";

	v.paneAt(at(v.primary(), 2))?.model.io.text("still-local\r", 0);
	assert await until((): boolean => seqOf(t.local, 2) == 1);

	t.remote.paneOf(1 as PaneId)?.vt.writeText("while-away\r\n");
	assert await until((): boolean => b.state == LinkState.Connected);
	assert v.sidebarHosts()[1].live;
	assert await showsAt(v, at(b, 1), "while-away");
	assert b.panes.running.length == 2;
	await closeAll(t);
}

test "a host that refuses the window shows refused, is not dialed again, and leaves local panes working" {
	const t = await twoHosts();
	const v = t.v;
	const path = freshPath();
	const refusing = listenUnix(path, {
		accepted: (c: Connection): void => {
			c.start((chunk: uint8[]): void => {
				const no = encode({ kind: MessageKind.Refused, reason: "this peer is not allowed" });
				if (no.ok) { const _sent = c.send(no.value); }
				c.finish();
			}, (reason: CloseReason): void => {});
		},
		failed: (): void => {},
	});
	assert refusing.ok;
	const gpu = v.addRemote("gpu", dialUnix(path));
	v.retryNow(gpu);
	assert await until((): boolean => gpu.state == LinkState.Refused);
	assert gpu.reason == "this peer is not allowed", gpu.reason;
	assert gpu.retry === null;
	const row = v.sidebarHosts()[2];
	assert row.label == "gpu" && row.state == "refused";
	v.windowAction(Action.SplitRight);
	assert await until((): boolean => t.local.panes.length == 3 && v.primary().panes.running.length == 3);
	if (refusing.ok) { refusing.value.close(); }
	cleanUp(path);
	await closeAll(t);
}

test "a host that keeps no session opens its new tab as a local pane, scoped apart from the local server's pane 1" {
	const t = await twoHosts();
	const v = t.v;
	const plain = v.addRemote("plain", async (uploading: () => void): Promise<Result<Connection, DialError>> => {
		return Result.err({
			failure: Failure.Unkept,
			why: "no Haro server for this system",
			command: "printf 'plain-%s\\n' shell; exec sh",
		});
	});
	v.retryNow(plain);
	assert await until((): boolean => plain.state == LinkState.Unkept);
	assert v.sidebarHosts()[2].state == "no session keeping";
	v.newTabOn(plain.id);
	assert await until((): boolean => plain.panes.running.length == 1 && v.shownHost().id == plain.id);
	assert await showsAt(v, at(plain, 1), "plain-shell");
	assert !(await screenAt(v, at(v.primary(), 1))).includes("plain-shell");
	await closeAll(t);
}
