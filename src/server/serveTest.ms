import { exists, removeAll } from "std/fs";
import { connectUnix, createUnixSocket, recvAsync, send as sendRaw } from "std/net";
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
import { Server, ServerSetup, TailnetListen, enqueue, start, stop, tailnetListen } from "./serve";
import { PeerInfo, TailnetAllow, TailnetError, TailnetFault, TailnetSelf } from "./tailnet";
import { CloseReason, Connection, connectToTcp, connectToUnix } from "./transport";
import { ServerLink } from "../client/link";

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
		heardAt: string[] = [];
		heardTimes: float64[] = [];
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
			for (const m of got.value) {
				p.got.push(m);
				if (m.kind == MessageKind.Output) {
					p.heardAt.push(printed(p, m.pane));
					p.heardTimes.push(performance.now());
				}
			}
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

	function cliHello(): Message {
		return {
			kind: MessageKind.Hello,
			version: PROTOCOL_VERSION,
			role: Role.Cli,
			cols: 0,
			rows: 0,
			vtBuild: "",
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

	class Heard { rtts: float64[] = []; }

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

	test "the first client of a fresh server sees its first shell's opening output, in its screen or as output" {
		const socket = socketIn();
		const logged = new Logged();
		const setup = setupAt(socket, logged);
		const s = await serving({
			...setup,
			launch: { ...setup.launch, command: "printf 'opening%swords\\n' -; exec sh" },
		});
		const ended = ending(s);
		const a = await attached(socket, vtBuild());
		assert await until((): boolean =>
			textOf(screenFor(a, FIRST), printed(a, FIRST)).includes("opening-words")
		), `${textOf(screenFor(a, FIRST), "")} | ${printed(a, FIRST)} | ${kinds(a)}`;
		await stopped(s, ended);
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

	class Gate { open: boolean = false; }

	test "input reaches the shell while the server's job queue is held" {
		const socket = socketIn();
		const logged = new Logged();
		const s = await serving(setupAt(socket, logged));
		const ended = ending(s);
		const a = await attached(socket, vtBuild());
		const marker = `${socket.slice(0, socket.lastIndexOf("/"))}/typed`;
		const gate = new Gate();
		s.enqueue(async (): Promise<void> => {
			while (!gate.open) { await sleepAsync(2); }
		});
		typed(a, `printf x > ${marker}\r`);
		const reached = await until((): boolean => exists(marker));
		gate.open = true;
		assert reached, logged.text;
		await stopped(s, ended);
		cleanUp(socket);
	}

	function lastScreenAt(p: Peer, pane: PaneId): int32 {
		let at: int32 = -1;
		for (let i: int32 = 0; i < p.got.length; i++) {
			const m = p.got[i];
			if (m.kind == MessageKind.Screen && m.pane == pane) { at = i; }
		}
		return at;
	}

	function screensFor(p: Peer, pane: PaneId): int32 {
		let n: int32 = 0;
		for (const m of p.got) {
			if (m.kind == MessageKind.Screen && m.pane == pane) { n += 1; }
		}
		return n;
	}

	function rawSay(fd: int32, m: Message): void {
		const bytes = encode(m);
		if (!bytes.ok || sendRaw(fd, bytes.value) != bytes.value.length) { throw new Error(`${m.kind} not sent`); }
	}

	test "a client that falls behind skips to a fresh screen of the pane, then output after it, and stays connected" {
		const socket = socketIn();
		const logged = new Logged();
		const s = await serving(setupAt(socket, logged));
		s.jumpBytes = 256 * 1024;
		const ended = ending(s);
		const slow = createUnixSocket();
		assert connectUnix(slow, socket) == 0;
		rawSay(slow, hello(vtBuild()));
		rawSay(slow, { kind: MessageKind.Attach });
		assert await until((): boolean => s.clients.length == 1 && s.clients[0].attached), logged.text;
		const flooded = `${socket.slice(0, socket.lastIndexOf("/"))}/flooded`;
		const flood = 20 * 1024 * 1024;
		rawSay(slow, {
			kind: MessageKind.Input,
			pane: FIRST,
			bytes: [...`head -c ${flood} /dev/zero | tr '\\0' x; touch ${flooded}\r`.asBytes()],
		});
		assert await until((): boolean => exists(flooded)), logged.text;
		const p = watched(new Peer(new Connection(slow)));
		assert await until((): boolean => screensFor(p, FIRST) >= 2), `${kinds(p)} ${logged.text}`;
		say(p, { kind: MessageKind.Input, pane: FIRST, bytes: [...`printf 'after%sjump\\n' -\r`.asBytes()] });
		assert await until((): boolean => printed(p, FIRST).includes("after-jump")), `${kinds(p)} ${logged.text}`;
		assert !p.closed && p.broken == "", p.broken;
		assert !logged.text.includes("fell too far behind"), logged.text;
		const last = lastScreenAt(p, FIRST);
		let before: uint64 = 0;
		let after: uint64 = 0;
		let received: int64 = 0;
		for (let i: int32 = 0; i < p.got.length; i++) {
			const m = p.got[i];
			if (m.kind == MessageKind.Output && m.pane == FIRST) {
				received += m.bytes.length as int64;
				if (i < last) { before = m.seq; } else if (after == 0) { after = m.seq; }
			}
		}
		assert after > before, `${before} then ${after}`;
		assert seqsRise(p, FIRST);
		assert received * 2 < (flood as int64), `${received} bytes of a ${flood} byte flood`;
		await stopped(s, ended);
		cleanUp(socket);
	}

	async function readSlowly(p: Peer, pauseMs: number): Promise<void> {
		while (true) {
			const chunk = await recvAsync(p.conn.fd, 64 * 1024);
			if (chunk.length == 0) {
				p.closed = true;
				return;
			}
			const got = p.decoder.push(chunk);
			if (!got.ok) {
				p.broken = got.error.toString();
				return;
			}
			for (const m of got.value) { p.got.push(m); }
			await sleepAsync(pauseMs);
		}
	}

	function outputBytes(p: Peer, pane: PaneId, from: int32, until: int32): int64 {
		let total: int64 = 0;
		for (let i = from; i < until; i++) {
			const m = p.got[i];
			if (m.kind == MessageKind.Output && m.pane == pane) { total += m.bytes.length as int64; }
		}
		return total;
	}

	function printedAt(p: Peer, pane: PaneId, from: int32, wanted: string): int32 {
		let text = "";
		for (let i = from; i < p.got.length; i++) {
			const m = p.got[i];
			if (m.kind == MessageKind.Output && m.pane == pane) {
				text += m.bytes.asString();
				if (text.includes(wanted)) { return i; }
			}
		}
		return -1;
	}

	test "a flooding pane neither jumps a client that keeps reading nor queues far ahead of another pane's echo" {
		const socket = socketIn();
		const logged = new Logged();
		const s = await serving(setupAt(socket, logged));
		const ended = ending(s);
		const fd = createUnixSocket();
		assert connectUnix(fd, socket) == 0;
		const p = new Peer(new Connection(fd));
		const _reading = readSlowly(p, 2);
		say(p, hello(vtBuild()));
		say(p, { kind: MessageKind.Attach });
		assert await until((): boolean => screenFor(p, FIRST) !== null), kinds(p);
		say(p, {
			kind: MessageKind.Command,
			command: { kind: CommandKind.Split, pane: FIRST, axis: Axis.SideBySide },
		});
		const second = 2 as PaneId;
		assert await until((): boolean => opened(p, second)), logged.text;
		say(p, { kind: MessageKind.Input, pane: FIRST, bytes: [...`yes flooding\r`.asBytes()] });
		assert await until((): boolean => outputBytes(p, FIRST, 0, p.got.length) > 4 * 1024 * 1024), logged.text;
		const from = p.got.length;
		say(p, { kind: MessageKind.Input, pane: second, bytes: [...`printf 'quick%secho\\n' -\r`.asBytes()] });
		assert await until((): boolean => printedAt(p, second, from, "quick-echo") >= 0), logged.text;
		const ahead = outputBytes(p, FIRST, from, printedAt(p, second, from, "quick-echo"));
		assert ahead < 1024 * 1024, `${ahead} flood bytes arrived between the echo's input and the echo`;
		assert screensFor(p, FIRST) == 1, `${screensFor(p, FIRST)} screens: ${logged.text}`;
		assert !p.closed && p.broken == "", p.broken;
		say(p, { kind: MessageKind.Input, pane: FIRST, bytes: [0x03] });
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

	struct OnTailnet {
		server: Server;
		port: int32;
	}

	async function servingTailnet(
		socket: string,
		logged: Logged,
		listen: (port: int32) => TailnetListen,
	): Promise<OnTailnet> {
		let port: int32 = 43000 + ((Date.now() % 15000) as int32);
		for (let tries: int32 = 0; tries < 20; tries++) {
			logged.text = "";
			const s = await serving({ ...setupAt(socket, logged), tailnet: listen(port) });
			if (logged.text.includes("serving the tailnet")) { return { server: s, port: port }; }
			const ended = ending(s);
			await stopped(s, ended);
			port += 1;
		}
		throw new Error(`no free port: ${logged.text}`);
	}

	const BUILD_1: PeerInfo = {
		userId: 7,
		loginName: "person@example.com",
		hostName: "build-1",
		os: "linux",
		tags: [],
	};

	function fakeTailnet(port: int32, delayMs: int32, answer: Result<PeerInfo, TailnetError>): TailnetListen {
		return {
			address: "127.0.0.1",
			port: port,
			admits: "a test",
			admit: async (remote: string): Promise<Result<PeerInfo, TailnetError>> => {
				await sleepAsync(delayMs);
				return answer;
			},
		};
	}

	async function dialTcp(port: int32): Promise<Peer> {
		const dialed = await connectToTcp("127.0.0.1", port, 2000);
		if (!dialed.ok) { throw new Error(`no connection to port ${port}`); }
		return watched(new Peer(dialed.value));
	}

	function statusOf(p: Peer): Message | null {
		const found = p.got.find((m: Message): boolean => m.kind == MessageKind.Status);
		return found === undefined ? null : found;
	}

	test "a peer that is not on the tailnet is closed unread and logged with its address" {
		const socket = socketIn();
		const logged = new Logged();
		const me: TailnetSelf = {
			ipv4: "127.0.0.1",
			ipv6: null,
			userId: 1,
			loginName: "person@example.com",
			hostName: "studio",
			tagged: false,
		};
		const on = await servingTailnet(socket, logged, (port: int32): TailnetListen =>
			tailnetListen(me, port, TailnetAllow.Owner)
		);
		const ended = ending(on.server);
		const p = await dialTcp(on.port);
		say(p, hello(vtBuild()));
		assert await until((): boolean => p.closed), logged.text;
		assert p.got.length == 0, kinds(p);
		assert logged.text.includes("tailnet peer 127.0.0.1:"), logged.text;
		assert logged.text.includes("is not a tailnet address"), logged.text;
		await stopped(on.server, ended);
		cleanUp(socket);
	}

	test "a peer still being identified holds no other client's output, and is closed when refused" {
		const socket = socketIn();
		const logged = new Logged();
		const refused: Result<PeerInfo, TailnetError> = Result.err({ fault: TailnetFault.OtherUser, detail: "not yours" });
		const on = await servingTailnet(socket, logged, (port: int32): TailnetListen =>
			fakeTailnet(port, 3000, refused)
		);
		const ended = ending(on.server);
		const slow = await dialTcp(on.port);
		say(slow, hello(vtBuild()));
		assert await until((): boolean => on.server.admitting.length == 1), logged.text;
		const began = Date.now();
		const a = await attached(socket, vtBuild());
		typed(a, "printf 'not%sheld\\n' -\r");
		assert await until((): boolean => printed(a, FIRST).includes("not-held")), printed(a, FIRST);
		assert Date.now() - began < 2500, `${Date.now() - began} ms`;
		assert on.server.admitting.length == 1;
		assert !slow.closed;
		assert await until((): boolean => slow.closed), logged.text;
		assert slow.got.length == 0, kinds(slow);
		assert logged.text.includes("refused: not yours"), logged.text;
		await stopped(on.server, ended);
		cleanUp(socket);
	}

	test "status names the listeners and each attached client, a tailnet one by its login" {
		const socket = socketIn();
		const logged = new Logged();
		const on = await servingTailnet(socket, logged, (port: int32): TailnetListen =>
			fakeTailnet(port, 0, Result.ok(BUILD_1))
		);
		const ended = ending(on.server);
		const local = await attached(socket, vtBuild());
		const remote = await dialTcp(on.port);
		say(remote, hello(vtBuild()));
		say(remote, { kind: MessageKind.Attach });
		assert await until((): boolean => screenFor(remote, FIRST) !== null), `${kinds(remote)} ${logged.text}`;
		const asker = await dial(socket);
		say(asker, cliHello());
		say(asker, { kind: MessageKind.AskStatus });
		assert await until((): boolean => statusOf(asker) !== null), kinds(asker);
		const status = statusOf(asker);
		if (status !== null && status.kind == MessageKind.Status) {
			assert status.listeners.join("|") == `unix ${socket}|tailnet 127.0.0.1:${on.port} for a test`, status.listeners.join("|");
			assert status.clients.join("|") == "local|person@example.com on build-1", status.clients.join("|");
		}
		assert logged.text.includes("(person@example.com on build-1) admitted"), logged.text;
		local.conn.close();
		remote.conn.close();
		asker.conn.close();
		await stopped(on.server, ended);
		cleanUp(socket);
	}

	test "stop asked through the protocol ends the server with 0, its shells and its socket" {
		const socket = socketIn();
		const logged = new Logged();
		const s = await serving(setupAt(socket, logged));
		const ended = ending(s);
		const a = await attached(socket, vtBuild());
		const asker = await dial(socket);
		say(asker, cliHello());
		say(asker, { kind: MessageKind.Stop });
		assert await until((): boolean => ended.code >= 0), logged.text;
		assert ended.code == 0;
		assert await until((): boolean => asker.closed && a.closed);
		assert logged.text.includes("stop asked by local"), logged.text;
		const again = await connectToUnix(socket, 500);
		assert !again.ok;
		cleanUp(socket);
	}

	test "stop before Hello is refused and the server keeps serving" {
		const socket = socketIn();
		const logged = new Logged();
		const s = await serving(setupAt(socket, logged));
		const ended = ending(s);
		const rude = await dial(socket);
		say(rude, { kind: MessageKind.Stop });
		assert await until((): boolean => rude.closed);
		assert ended.code < 0;
		const a = await attached(socket, vtBuild());
		assert a.got[0].kind == MessageKind.Welcome;
		await stopped(s, ended);
		cleanUp(socket);
	}

	test "a client's ping is answered with a pong of its nonce, and a link turns pongs into a smoothed round trip" {
		const socket = socketIn();
		const logged = new Logged();
		const s = await serving(setupAt(socket, logged));
		const ended = ending(s);
		const p = await dial(socket);
		say(p, cliHello());
		say(p, { kind: MessageKind.Ping, nonce: 41, rttMicros: 42000 });
		assert await until((): boolean => p.got.some((m: Message): boolean => m.kind == MessageKind.Pong && m.nonce == 41)),
			kinds(p);
		const conn = await connectToUnix(socket, 2000);
		assert conn.ok;
		if (conn.ok) {
			const link = new ServerLink(conn.value);
			link.begin();
			link.send(cliHello());
			const heard = new Heard();
			link.measure((ms: float64): void => { heard.rtts.push(ms); });
			assert await until((): boolean => heard.rtts.length > 0), logged.text;
			assert link.rttMs !== null && heard.rtts[0] >= 0;
			link.detach();
		}
		await stopped(s, ended);
		cleanUp(socket);
	}

	function arrivalOf(p: Peer, text: string): float64 {
		return p.heardAt.findIndex((t: string): boolean => t.includes(text)) < 0
			? -1
			: p.heardTimes[p.heardAt.findIndex((t: string): boolean => t.includes(text))];
	}

	test "a remote client's unsolicited output waits out the pacing window, its keystroke echo and a local client's output do not" {
		const socket = socketIn();
		const logged = new Logged();
		const s = await serving(setupAt(socket, logged));
		s.paceCapMs = 600;
		const ended = ending(s);
		const near = await attached(socket, vtBuild());
		const far = await dial(socket);
		say(far, { kind: MessageKind.Proxied });
		say(far, hello(vtBuild()));
		say(far, { kind: MessageKind.Attach });
		say(far, { kind: MessageKind.Ping, nonce: 1, rttMicros: 2000000 });
		assert await until((): boolean => screenFor(far, FIRST) !== null && far.got.some((m: Message): boolean => m.kind == MessageKind.Pong));
		typed(near, "stty -echo; echo R''EADY\r");
		assert await until((): boolean => printed(far, FIRST).includes("READY")), logged.text;
		await sleepAsync(800);
		typed(near, "sleep 0.3; echo L''ATE\r");
		assert await until((): boolean => printed(far, FIRST).includes("LATE")), logged.text;
		const late = arrivalOf(far, "LATE") - arrivalOf(near, "LATE");
		assert late >= 400, `${late}`;
		await sleepAsync(800);
		say(far, { kind: MessageKind.Input, pane: FIRST, bytes: [...("stty echo; echo K''EY\r").asBytes()] });
		assert await until((): boolean => printed(far, FIRST).includes("KEY")), logged.text;
		const key = arrivalOf(far, "KEY") - arrivalOf(near, "KEY");
		assert key < 300, `${key}`;
		await stopped(s, ended);
		cleanUp(socket);
	}

	function lastUnseen(p: Peer): string {
		let said = "none";
		for (const m of p.got) {
			if (m.kind == MessageKind.Unseen && m.pane == FIRST) { said = m.unseen ? "unseen" : "seen"; }
		}
		return said;
	}

	test "a remote client is told when a pane reads a line without echo and when it echoes again, a local one is not" {
		const socket = socketIn();
		const logged = new Logged();
		const s = await serving(setupAt(socket, logged));
		const ended = ending(s);
		const near = await attached(socket, vtBuild());
		const far = await dial(socket);
		say(far, { kind: MessageKind.Proxied });
		say(far, hello(vtBuild()));
		say(far, { kind: MessageKind.Attach });
		assert await until((): boolean => screenFor(far, FIRST) !== null);
		say(far, { kind: MessageKind.Input, pane: FIRST, bytes: [...("stty -echo; echo A''SK; read secret; stty echo; echo D''ONE\r").asBytes()] });
		assert await until((): boolean => lastUnseen(far) == "unseen"), `${kinds(far)} ${logged.text}`;
		say(far, { kind: MessageKind.Input, pane: FIRST, bytes: [...("hidden\r").asBytes()] });
		assert await until((): boolean => printed(far, FIRST).includes("DONE") && lastUnseen(far) == "seen"), kinds(far);
		assert lastUnseen(near) == "none";
		await stopped(s, ended);
		cleanUp(socket);
	}
}
