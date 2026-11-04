import { removeAll } from "std/fs";
import { join } from "std/fs/path";
import { tmpDir } from "std/os";
import { vtBuild } from "../vt/vt";
import { Axis, Pane, PaneId, panes } from "../workspace/tree";
import { CommandKind, EventKind, Tab } from "../workspace/workspace";
import {
	Decoder,
	MAX_SCREEN_BYTES,
	Message,
	MessageKind,
	PROTOCOL_VERSION,
	Role,
	ScreenFormat,
	create,
	encode,
	push,
} from "./protocol";
import { screenText } from "./screenRig";
import { Server, ServerSetup, TailnetListen, start, stop } from "./serve";
import { CloseReason, Connection, connectToTcp, connectToUnix } from "./transport";

when (!windows) {
	const COLS: int32 = 80;
	const ROWS: int32 = 24;
	const WAIT_MS: number = 10000;
	const FIRST: PaneId = 1 as PaneId;

	class Logged { text: string = ""; }

	class Peer {
		readonly conn: Connection;
		decoder: Decoder = Decoder.create();
		got: Message[] = [];
		closed: boolean = false;
		broken: string = "";

		constructor(conn: Connection) { this.conn = conn; }
	}

	let made: int32 = 0;

	function socketIn(): string {
		made += 1;
		return join(join(tmpDir(), `haro-serve-${Date.now()}-${made}`), "s.sock");
	}

	function cleanUp(socket: string): void {
		const _removed = removeAll(socket.slice(0, socket.lastIndexOf("/")));
	}

	function setupAt(socket: string, logged: Logged): ServerSetup {
		return {
			launch: { command: "sh", shellScripts: null, startIn: null, originCwd: false },
			socket: socket,
			dividerCells: 1,
			tailnet: null,
			screenLimit: MAX_SCREEN_BYTES,
			log: (line: string): void => { logged.text += `${line}\n`; },
		};
	}

	async function until(done: () => boolean): Promise<boolean> {
		const deadline = Date.now() + WAIT_MS;
		while (!done()) {
			if (Date.now() > deadline) { return false; }
			await sleepAsync(2);
		}
		return true;
	}

	async function serving(setup: ServerSetup): Promise<Server> {
		const started = await Server.start(setup);
		if (!started.ok) { throw new Error(`no server: ${started.error}`); }
		return started.value;
	}

	function watched(p: Peer): Peer {
		p.conn.start((chunk: uint8[]): void => {
			const got = p.decoder.push(chunk);
			if (!got.ok) {
				p.broken = got.error.toString();
				return;
			}
			for (const m of got.value) { p.got.push(m); }
		}, (why: CloseReason): void => { p.closed = true; });
		return p;
	}

	async function dial(socket: string): Promise<Peer> {
		const got = await connectToUnix(socket, 2000);
		if (!got.ok) { throw new Error(`no connection to ${socket}`); }
		return watched(new Peer(got.value));
	}

	function say(p: Peer, m: Message): void {
		const bytes = encode(m);
		if (!bytes.ok) { throw new Error(`encode refused: ${bytes.error}`); }
		if (!p.conn.send(bytes.value)) { throw new Error(`${m.kind} not sent`); }
	}

	function hello(build: string): Message {
		return {
			kind: MessageKind.Hello,
			version: PROTOCOL_VERSION,
			role: Role.Window,
			cols: COLS,
			rows: ROWS,
			vtBuild: build,
		};
	}

	function typed(p: Peer, text: string): void {
		say(p, { kind: MessageKind.Input, pane: FIRST, bytes: [...text.asBytes()] });
	}

	async function attached(socket: string, build: string): Promise<Peer> {
		const p = await dial(socket);
		say(p, hello(build));
		say(p, { kind: MessageKind.Attach });
		if (!(await until((): boolean => screenFor(p, FIRST) !== null))) {
			throw new Error(`no screen: ${kinds(p)}`);
		}
		return p;
	}

	function kinds(p: Peer): string {
		return p.got.map((m: Message): string => m.kind.toString()).join(",");
	}

	function screenFor(p: Peer, pane: PaneId): Message | null {
		let found: Message | null = null;
		for (const m of p.got) {
			if (m.kind == MessageKind.Screen && m.pane == pane) { found = m; }
		}
		return found;
	}

	function printed(p: Peer, pane: PaneId): string {
		let text = "";
		for (const m of p.got) {
			if (m.kind == MessageKind.Output && m.pane == pane) { text += m.bytes.asString(); }
		}
		return text;
	}

	function seqsRise(p: Peer, pane: PaneId): boolean {
		let last: uint64 = 0;
		let seen = 0;
		for (const m of p.got) {
			if (m.kind == MessageKind.Output && m.pane == pane) {
				if (m.seq <= last) { return false; }
				last = m.seq;
				seen += 1;
			}
		}
		return seen > 0;
	}

	function opened(p: Peer, pane: PaneId): boolean {
		for (const m of p.got) {
			if (m.kind == MessageKind.Event && m.event.kind == EventKind.PaneOpened && m.event.pane == pane) {
				return true;
			}
		}
		return false;
	}

	function answers(p: Peer): string[] {
		const out: string[] = [];
		for (const m of p.got) {
			if (m.kind == MessageKind.Busy) { out.push(`${m.pane as int32} ${m.busy}`); }
		}
		return out;
	}

	function layoutBeforeOpened(p: Peer, pane: PaneId): boolean {
		let at = p.got.findIndex((m: Message): boolean =>
			m.kind == MessageKind.Event && m.event.kind == EventKind.PaneOpened && m.event.pane == pane
		);
		while (at > 0) {
			at -= 1;
			const m = p.got[at];
			if (m.kind == MessageKind.Layout) {
				return m.tabs.some((t: Tab): boolean => t.root.panes().some((leaf: Pane): boolean => leaf.id == pane));
			}
			if (m.kind != MessageKind.Event && m.kind != MessageKind.Output) { return false; }
		}
		return false;
	}

	function textOf(m: Message | null, after: string): string {
		if (m === null || m.kind != MessageKind.Screen) { return "<no screen>"; }
		return screenText(m.format, m.bytes, m.cols, m.rows, after);
	}

	function formatOf(m: Message | null): ScreenFormat | null {
		if (m === null || m.kind != MessageKind.Screen) { return null; }
		return m.format;
	}

	class Ended { code: int32 = -1; }

	function ending(s: Server): Ended {
		const ended = new Ended();
		s.finished.then((code: int32): void => { ended.code = code; });
		return ended;
	}

	async function stopped(s: Server, ended: Ended): Promise<void> {
		s.stop(0);
		if (!(await until((): boolean => ended.code >= 0))) { throw new Error("the server did not stop"); }
	}

	test "a fresh server welcomes a client, attaches it with a layout and a screen, and exits 0 with its last shell" {
		const socket = socketIn();
		const logged = new Logged();
		const s = await serving(setupAt(socket, logged));
		const ended = ending(s);
		const a = await attached(socket, vtBuild());
		assert a.got[0].kind == MessageKind.Welcome, kinds(a);
		const welcome = a.got[0];
		if (welcome.kind == MessageKind.Welcome) {
			assert welcome.vtBuild == vtBuild();
			assert welcome.version == PROTOCOL_VERSION;
		}
		const layout = a.got.find((m: Message): boolean => m.kind == MessageKind.Layout);
		assert layout !== undefined && layout.kind == MessageKind.Layout;
		if (layout !== undefined && layout.kind == MessageKind.Layout) {
			assert layout.tabs.length == 1;
		}
		const screen = screenFor(a, FIRST);
		assert formatOf(screen) == ScreenFormat.Native;
		if (screen !== null && screen.kind == MessageKind.Screen) {
			assert screen.cols == COLS && screen.rows == ROWS;
		}

		typed(a, "exit 0\r");
		assert await until((): boolean => ended.code >= 0), logged.text;
		assert ended.code == 0;
		assert a.got.some((m: Message): boolean => m.kind == MessageKind.Exited && m.pane == FIRST && m.code == 0);
		assert a.got.some((m: Message): boolean =>
			m.kind == MessageKind.Event && m.event.kind == EventKind.WorkspaceEmpty
		);
		assert await until((): boolean => a.closed);
		assert a.broken == "", a.broken;
		cleanUp(socket);
	}

	test "a split from one client reaches every attached client as an event" {
		const socket = socketIn();
		const logged = new Logged();
		const s = await serving(setupAt(socket, logged));
		const ended = ending(s);
		const a = await attached(socket, vtBuild());
		const b = await attached(socket, vtBuild());
		say(a, {
			kind: MessageKind.Command,
			command: { kind: CommandKind.Split, pane: FIRST, axis: Axis.SideBySide },
		});
		const second = 2 as PaneId;
		assert await until((): boolean => opened(a, second) && opened(b, second)), logged.text;
		assert layoutBeforeOpened(a, second), kinds(a);
		assert layoutBeforeOpened(b, second), kinds(b);
		await stopped(s, ended);
		cleanUp(socket);
	}

	test "input reaches the shell and its output arrives in rising seq" {
		const socket = socketIn();
		const logged = new Logged();
		const s = await serving(setupAt(socket, logged));
		const ended = ending(s);
		const a = await attached(socket, vtBuild());
		typed(a, "printf 'round%strip\\n' -\r");
		assert await until((): boolean => printed(a, FIRST).includes("round-trip")), printed(a, FIRST);
		typed(a, "printf 'second%sline\\n' -\r");
		assert await until((): boolean => printed(a, FIRST).includes("second-line"));
		assert seqsRise(a, FIRST);
		await stopped(s, ended);
		cleanUp(socket);
	}

	test "a client asking whether a pane is busy gets the pane's answer, and an unknown pane is not busy" {
		const socket = socketIn();
		const logged = new Logged();
		const s = await serving(setupAt(socket, logged));
		const ended = ending(s);
		const a = await attached(socket, vtBuild());
		typed(a, "printf 'idle%sshell\\n' -\r");
		assert await until((): boolean => printed(a, FIRST).includes("idle-shell"));
		say(a, { kind: MessageKind.AskBusy, pane: FIRST });
		say(a, { kind: MessageKind.AskBusy, pane: 9 as PaneId });
		assert await until((): boolean => answers(a).length == 2), kinds(a);
		assert answers(a).join(",") == "1 false,9 false", answers(a).join(",");
		await stopped(s, ended);
		cleanUp(socket);
	}

	test "a client that leaves keeps its shell, and the next one restores the screen, alternate screen included" {
		const socket = socketIn();
		const logged = new Logged();
		const s = await serving(setupAt(socket, logged));
		const ended = ending(s);
		const a = await attached(socket, vtBuild());
		typed(a, "printf 'kept%stext\\n' -\r");
		assert await until((): boolean => printed(a, FIRST).includes("kept-text"));
		a.conn.close();
		assert await until((): boolean => s.clients.length == 0);

		const native = await attached(socket, vtBuild());
		const shot = screenFor(native, FIRST);
		assert formatOf(shot) == ScreenFormat.Native;
		assert textOf(shot, "").includes("kept-text"), textOf(shot, "");

		const other = await attached(socket, "another libghostty-vt build");
		const replayed = screenFor(other, FIRST);
		assert formatOf(replayed) == ScreenFormat.VtBytes;
		assert textOf(replayed, "").includes("kept-text"), textOf(replayed, "");

		typed(native, "printf 'under%salt\\n' -; printf '\\033[?1049h\\033[2J\\033[Hon%salt' -\r");
		assert await until((): boolean => printed(native, FIRST).includes("on-alt"));
		native.conn.close();
		other.conn.close();
		const full = await attached(socket, vtBuild());
		const alt = screenFor(full, FIRST);
		assert formatOf(alt) == ScreenFormat.Native;
		const onAlt = textOf(alt, "");
		assert onAlt.includes("on-alt") && !onAlt.includes("under-alt"), onAlt;
		const left = textOf(alt, "\x1b[?1049l");
		assert left.includes("under-alt") && left.includes("kept-text") && !left.includes("on-alt"), left;
		await stopped(s, ended);
		cleanUp(socket);
	}

	test "a second server refuses to start while the first answers" {
		const socket = socketIn();
		const logged = new Logged();
		const s = await serving(setupAt(socket, logged));
		const ended = ending(s);
		const second = await Server.start(setupAt(socket, logged));
		assert !second.ok;
		if (!second.ok) { assert second.error == `a server already answers at ${socket}`, second.error; }
		const a = await attached(socket, vtBuild());
		assert a.got[0].kind == MessageKind.Welcome;
		await stopped(s, ended);
		cleanUp(socket);
	}

	test "a screen over the limit is sent empty as VT bytes and logged" {
		const socket = socketIn();
		const logged = new Logged();
		const setup = setupAt(socket, logged);
		const s = await serving({ ...setup, screenLimit: 1 });
		const ended = ending(s);
		const a = await attached(socket, vtBuild());
		const shot = screenFor(a, FIRST);
		assert formatOf(shot) == ScreenFormat.VtBytes;
		if (shot !== null && shot.kind == MessageKind.Screen) { assert shot.bytes.length == 0; }
		assert logged.text.includes("pane 1 screen sent empty: SnapshotTooLarge"), logged.text;
		await stopped(s, ended);
		cleanUp(socket);
	}

	test "a peer that is not on the tailnet is closed unread and logged with its address" {
		const socket = socketIn();
		let port: int32 = 43000 + ((Date.now() % 15000) as int32);
		let found: Server | null = null;
		let logged = new Logged();
		for (let tries: int32 = 0; tries < 20 && found === null; tries++) {
			logged = new Logged();
			const tailnet: TailnetListen = {
				self: {
					ipv4: "127.0.0.1",
					ipv6: null,
					userId: 1,
					loginName: "person@example.com",
					hostName: "studio",
				},
				port: port,
			};
			const s = await serving({ ...setupAt(socket, logged), tailnet: tailnet });
			if (logged.text.includes("serving the tailnet")) {
				found = s;
			} else {
				const ended = ending(s);
				await stopped(s, ended);
				port += 1;
			}
		}
		assert found !== null, logged.text;
		if (found === null) { return; }
		const ended = ending(found);
		const dialed = await connectToTcp("127.0.0.1", port, 2000);
		assert dialed.ok;
		if (!dialed.ok) { return; }
		const p = watched(new Peer(dialed.value));
		say(p, hello(vtBuild()));
		assert await until((): boolean => p.closed), logged.text;
		assert p.got.length == 0, kinds(p);
		assert logged.text.includes("tailnet peer 127.0.0.1:"), logged.text;
		assert logged.text.includes("is not a tailnet address"), logged.text;
		await stopped(found, ended);
		cleanUp(socket);
	}
}
