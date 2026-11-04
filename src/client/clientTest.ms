import { removeAll } from "std/fs";
import { join } from "std/fs/path";
import { tmpDir } from "std/os";
import { Connection, connectToUnix, listenUnix } from "../server/transport";
import { ScreenFormat } from "../server/protocol";
import { Vt, lines, update, writeText } from "../vt/vt";
import { vtBuild } from "../vt/snapshot";
import { seededVt } from "../pty/remote";
import { Axis, PaneId, panes } from "../workspace/tree";
import { CommandKind } from "../workspace/workspace";
import { ServerLink, attach } from "./link";
import { DEFAULT_PORT, targetOf } from "./connect";
import { FakeServer, startFake } from "./fakeServer";

const WAIT_MS: float64 = 10000;

test "a connect target is a host with an optional port, bracketed when it is IPv6" {
	const shown = (target: string): string => {
		const got = targetOf(target);
		return got.ok ? `${got.value.host} ${got.value.port}` : "refused";
	};
	assert shown("box") == `box ${DEFAULT_PORT}`;
	assert shown("box:9000") == "box 9000";
	assert shown("100.64.0.1:22") == "100.64.0.1 22";
	assert shown("[fd7a::1]:9000") == "fd7a::1 9000";
	assert shown("[fd7a::1]") == `fd7a::1 ${DEFAULT_PORT}`;
	assert shown("fd7a::1") == `fd7a::1 ${DEFAULT_PORT}`;
	assert shown("") == "refused";
	assert shown(":80") == "refused";
	assert shown("box:0") == "refused";
	assert shown("box:65536") == "refused";
	assert shown("box:http") == "refused";
	assert shown("[fd7a::1") == "refused";
}

let dirs: int32 = 0;

function freshPath(): string {
	dirs += 1;
	return join(join(tmpDir(), `haro-client-${Date.now()}-${dirs}`), "s.sock");
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

function text(this vt: Vt): string {
	if (!vt.update().ok) { return "<update failed>"; }
	const got = vt.lines();
	return got.ok ? got.value.join("\n") : "<lines failed>";
}

function fakeWithTwoPanes(path: string, format: ScreenFormat): FakeServer {
	const fake = startFake(path, format);
	if (!fake.ok) { throw new Error(`the fake server did not listen: ${fake.error.toString()}`); }
	const f = fake.value;
	const _tab = f.apply({ kind: CommandKind.NewTab });
	const _split = f.apply({ kind: CommandKind.Split, pane: 1 as PaneId, axis: Axis.SideBySide });
	f.paneOf(1 as PaneId)?.vt.writeText("one-marker\r\n");
	f.paneOf(2 as PaneId)?.vt.writeText("two-marker\r\n");
	return f;
}

test "attaching reads the layout and one screen per pane, and each screen seeds the server's text" {
	for (const format of [ScreenFormat.Native, ScreenFormat.VtBytes]) {
		const path = freshPath();
		const fake = fakeWithTwoPanes(path, format);
		const link = await linked(path);
		const got = await attach(link, vtBuild(), 80, 24, 5000);
		assert got.ok;
		if (got.ok) {
			const a = got.value;
			assert a.layout.tabs.length == 1;
			assert a.layout.tabs[0].root.panes().length == 2;
			assert a.screens.length == 2;
			for (const s of a.screens) {
				assert s.seed.native == (format == ScreenFormat.Native);
				const vt = s.seed.seededVt();
				const server = fake.paneOf(s.pane)?.vt ?? null;
				assert vt.ok && server !== null;
				if (vt.ok && server !== null) {
					assert vt.value.text() == server.text();
					assert vt.value.text().includes(s.pane == (1 as PaneId) ? "one-marker" : "two-marker");
					vt.value.free();
				}
			}
		}
		link.detach();
		assert await until((): boolean => fake.byes == 1);
		fake.close();
		cleanUp(path);
	}
}

test "attaching to a server that hangs up ends with the reason instead of waiting" {
	const path = freshPath();
	const listener = listenUnix(path, {
		accepted: (c: Connection): void => { c.close(); },
		failed: (): void => {},
	});
	assert listener.ok;
	const link = await linked(path);
	const got = await attach(link, vtBuild(), 80, 24, 5000);
	assert !got.ok;
	if (!got.ok) { assert got.error == "the server closed the connection"; }
	if (listener.ok) { listener.value.close(); }
	cleanUp(path);
}

