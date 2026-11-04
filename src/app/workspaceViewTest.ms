import { removeAll } from "std/fs";
import { join } from "std/fs/path";
import { tmpDir } from "std/os";
import { connectToUnix } from "../server/transport";
import { MessageKind, ScreenFormat } from "../server/protocol";
import { defaults } from "../config/config";
import { HookPane, KeyAnswer, UNHANDLED } from "../config/hooks";
import { KeyEvent } from "../keys/keys";
import { CommandDone } from "../vt/vt";
import { vtBuild } from "../vt/snapshot";
import { Axis, PaneId, panes } from "../workspace/tree";
import { CommandKind, focusedPane } from "../workspace/workspace";
import { ServerLink, attach } from "../client/link";
import { FakeServer, startFake } from "../client/fakeServer";
import { Stats, empty } from "./stats";
import { ConfigChange } from "./components/features/terminal/paneModel";
import { paneOf } from "./panes";
import {
	WindowHost,
	WorkspaceView,
	attachTo,
	detachPanes,
	open,
	send,
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
		report: {
			note: (message: string): void => { notes.lines.push(message); },
			fail: (message: string): void => { notes.fatal = message; },
		},
		timing: {
			clock: (): float64 => performance.now(),
			schedule: (run: () => void): void => {},
		},
		keyHook: {
			answer: (pane: HookPane, k: KeyEvent): Result<KeyAnswer, string> => Result.ok(UNHANDLED),
		},
		shellHook: {
			prompted: (pane: HookPane, at: int32): Result<void, string> => Result.ok(null),
			commandDone: (pane: HookPane, done: CommandDone): Result<void, string> => Result.ok(null),
		},
		events: {
			onWake: (handler: () => void): void => {},
			onMenu: (handler: (id: string) => void): void => {},
			onCloseRequest: (handler: () => void): void => {},
			onConfig: (handler: (change: ConfigChange) => void): void => {},
		},
		stats: Stats.empty(),
		fontFamily: "",
	};
}

async function screenOf(v: WorkspaceView, id: int32): Promise<string> {
	const pane = v.panes.paneOf(id as PaneId);
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
	for (const tab of v.w.tabs) {
		for (const p of tab.root.panes()) { ids.push(`${p.id as int32}`); }
	}
	return ids.join(",");
}

function runningIds(v: WorkspaceView): string {
	return v.panes.running.map((r): string => `${r.id as int32}`).join(",");
}

function focusedIs(v: WorkspaceView, id: int32): boolean {
	const f = v.w.focusedPane();
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
	await v.attachTo(link, got.value);
	assert runningIds(v) == "1,2";
	assert treeIds(v) == "1,2";
	assert await shows(v, 1, "one-marker");
	assert await shows(v, 2, "two-marker");

	v.panes.paneOf(1 as PaneId)?.model.io.text("typed-in\r", 0);
	assert await shows(v, 1, "typed-in");
	assert fake.paneOf(1 as PaneId)?.seq == 1;

	v.send({ kind: CommandKind.Split, pane: 2 as PaneId, axis: Axis.Stacked });
	assert await until((): boolean => runningIds(v) == "1,2,3" && treeIds(v) == "1,2,3" && focusedIs(v, 3));
	v.send({ kind: CommandKind.ClosePane, pane: 1 as PaneId });
	assert await until((): boolean => runningIds(v) == "2,3" && treeIds(v) == "2,3");
	assert notes.fatal == "";

	await v.detachPanes();
	assert await until((): boolean => fake.byes == 1);
	assert v.panes.running.length == 0;
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
