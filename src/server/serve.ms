@compile("./wake.c");

import { Config, PaneCwd } from "../config/config";
import { ptySetWake } from "../pty/nativePty.h";
import { vtBuild } from "../vt/vt";
import { PaneId, panes } from "../workspace/tree";
import {
	CommandKind,
	EventKind,
	Workspace,
	WorkspaceCommand,
	apply,
	create,
} from "../workspace/workspace";
import {
	HostLaunch,
	PaneHost,
	apply as applyEvent,
	busy,
	closeAll,
	open,
	pump,
	snapshot,
	write,
} from "./paneHost";
import {
	Decoder,
	MAX_SCREEN_BYTES,
	Message,
	MessageKind,
	ScreenFormat,
	create as decoder,
	encode,
	greet,
	push,
	screenFormat,
} from "./protocol";
import {
	PeerInfo,
	TailnetAllow,
	TailnetError,
	TailnetSelf,
	identityOf,
	listenAddress,
	peerAllowed,
	tailnetSelf,
} from "./tailnet";
import {
	CloseReason,
	Connection,
	ListenError,
	Listener,
	connectToUnix,
	listenTcp,
	listenUnix,
	peerAddress,
	socketPath,
} from "./transport";
import { serverWake, serverWakeTo } from "./wake.h";

when (windows) {
	@include("windows.h");

	extern function GetCurrentProcessId(): uint32;

	function processId(): int32 { return GetCurrentProcessId() as int32; }
} else {
	@include("unistd.h");

	extern function getpid(): int32;

	function processId(): int32 { return getpid(); }
}

const DEFAULT_COLS: int32 = 80;
const DEFAULT_ROWS: int32 = 24;
const WAKE_CONNECT_MS: int32 = 2000;
const FLUSH_ON_EXIT_MS: int32 = 2000;
const MAX_ADMITTING: int32 = 8;
const LOCAL: string = "local";

export struct ServeOptions {
	config: Config;
	shellScripts: string | null;
	startIn: string | null;
	dividerCells: int32;
}

export struct TailnetListen {
	address: string;
	port: int32;
	admits: string;
	admit: (remote: string) => Promise<Result<PeerInfo, TailnetError>>;
}

export struct TailnetChoice {
	port: int32;
	allow: TailnetAllow;
}

export function tailnetListen(self: TailnetSelf, port: int32, allow: TailnetAllow): TailnetListen {
	return {
		address: listenAddress(self),
		port: port,
		admits: allow == TailnetAllow.Owner ? `its owner ${self.loginName}` : "any identified tailnet user",
		admit: (remote: string): Promise<Result<PeerInfo, TailnetError>> => peerAllowed(remote, self, allow),
	};
}

export struct ServerSetup {
	launch: HostLaunch;
	socket: string;
	dividerCells: int32;
	tailnet: TailnetListen | null;
	screenLimit: int32;
	log: (line: string) => void;
}

class Client {
	readonly conn: Connection;
	readonly identity: string;
	decoder: Decoder = Decoder.create();
	greeted: boolean = false;
	attached: boolean = false;
	vtBuild: string = "";
	cols: int32 = 0;
	rows: int32 = 0;

	constructor(conn: Connection, identity: string) {
		this.conn = conn;
		this.identity = identity;
	}
}

struct PaneExit {
	pane: PaneId;
	code: int32;
}

function settle(code: int32): void {}

export class Server {
	readonly setup: ServerSetup;
	readonly vtBuild: string;
	workspace: Workspace;
	host: PaneHost | null = null;
	clients: Client[] = [];
	admitting: Connection[] = [];
	listeners: Listener[] = [];
	serving: string[] = [];
	wakeIn: Connection | null = null;
	wakeOut: Connection | null = null;
	cols: int32 = DEFAULT_COLS;
	rows: int32 = DEFAULT_ROWS;
	jobs: (() => Promise<void>)[] = [];
	working: boolean = false;
	pumpQueued: boolean = false;
	exits: PaneExit[] = [];
	stopping: boolean = false;
	resolve: (code: int32) => void = settle;
	readonly finished: Promise<int32>;

	constructor(setup: ServerSetup, workspace: Workspace) {
		this.setup = setup;
		this.vtBuild = vtBuild();
		this.workspace = workspace;
		this.finished = new Promise<int32>((resolve: (code: int32) => void): void => {
			this.resolve = resolve;
		});
	}
}

function log(this s: Server, line: string): void {
	s.setup.log(`haro server: ${line}`);
}

function hostOf(this s: Server): PaneHost {
	const host = s.host;
	if (host === null) { throw new Error("haro server: the pane host is not open"); }
	return host;
}

function enqueue(this s: Server, job: () => Promise<void>): void {
	if (s.stopping) { return; }
	s.jobs.push(job);
	if (!s.working) {
		s.working = true;
		const _running = s.runJobs();
	}
}

async function runJobs(this s: Server): Promise<void> {
	while (s.jobs.length > 0 && !s.stopping) {
		const job = s.jobs.shift()!;
		await job();
	}
	s.jobs = [];
	s.working = false;
}

function sendTo(this s: Server, c: Client, m: Message): void {
	const bytes = encode(m);
	if (!bytes.ok) {
		s.log(`${m.kind.toString()} not sent: ${bytes.error.toString()}`);
		return;
	}
	const _sent = c.conn.send(bytes.value);
}

function broadcast(this s: Server, m: Message): void {
	const bytes = encode(m);
	if (!bytes.ok) {
		s.log(`${m.kind.toString()} not sent: ${bytes.error.toString()}`);
		return;
	}
	for (const c of s.clients) {
		if (c.attached) { const _sent = c.conn.send(bytes.value); }
	}
}

function kick(this s: Server): void {
	if (s.pumpQueued) { return; }
	s.pumpQueued = true;
	s.enqueue(async (): Promise<void> => {
		s.pumpQueued = false;
		const more = await s.hostOf().pump();
		await s.closeExited();
		if (more) { s.kick(); }
	});
}

async function closeExited(this s: Server): Promise<void> {
	const exits = s.exits;
	s.exits = [];
	for (const e of exits) {
		s.broadcast({ kind: MessageKind.Exited, pane: e.pane, code: e.code });
		await s.run({ kind: CommandKind.ClosePane, pane: e.pane });
	}
}

async function run(this s: Server, c: WorkspaceCommand): Promise<void> {
	if (s.stopping) { return; }
	const events = s.workspace.apply(c, s.cols, s.rows);
	if (!events.ok) {
		s.log(`${c.kind.toString()} refused: ${events.error.toString()}`);
		return;
	}
	if (events.value.length > 0) {
		s.broadcast({ kind: MessageKind.Layout, tabs: s.workspace.tabs, active: s.workspace.active });
	}
	const failed: PaneId[] = [];
	for (const e of events.value) {
		s.broadcast({ kind: MessageKind.Event, event: e });
		const refused = await s.hostOf().applyEvent(e);
		if (refused !== null && e.kind == EventKind.PaneOpened) {
			const reason = `pane ${e.pane as int32} did not start: ${refused.toString()}`;
			s.log(reason);
			s.broadcast({ kind: MessageKind.Failed, pane: e.pane, reason: reason });
			failed.push(e.pane);
		}
		if (e.kind == EventKind.WorkspaceEmpty) {
			s.log("the last pane closed");
			s.stop(0);
			return;
		}
	}
	for (const pane of failed) { await s.run({ kind: CommandKind.ClosePane, pane: pane }); }
}

async function attach(this s: Server, c: Client): Promise<void> {
	if (s.workspace.tabs.length == 0) {
		if (c.cols > 0 && c.rows > 0) {
			s.cols = c.cols;
			s.rows = c.rows;
		}
		await s.run({ kind: CommandKind.NewTab });
	}
	if (!c.conn.isOpen() || s.stopping) { return; }
	s.sendTo(c, { kind: MessageKind.Layout, tabs: s.workspace.tabs, active: s.workspace.active });
	const wanted = screenFormat(c.vtBuild, s.vtBuild);
	for (const tab of s.workspace.tabs) {
		for (const pane of tab.root.panes()) {
			const cols = pane.rect.cols;
			const rows = pane.rect.rows;
			const shot = await s.hostOf().snapshot(pane.id, wanted, s.setup.screenLimit);
			if (shot.ok) {
				s.sendTo(c, {
					kind: MessageKind.Screen,
					pane: pane.id,
					cols: cols,
					rows: rows,
					format: shot.value.format,
					bytes: [...shot.value.bytes],
				});
			} else {
				s.log(`pane ${pane.id as int32} screen sent empty: ${shot.error.toString()}`);
				s.sendTo(c, {
					kind: MessageKind.Screen,
					pane: pane.id,
					cols: cols,
					rows: rows,
					format: ScreenFormat.VtBytes,
					bytes: [],
				});
			}
		}
	}
	c.attached = true;
}

function refuse(this s: Server, c: Client, reason: string): void {
	s.log(`client refused: ${reason}`);
	s.sendTo(c, { kind: MessageKind.Refused, reason: reason });
	c.conn.finish();
}

function hello(this s: Server, c: Client, m: Message): void {
	if (m.kind != MessageKind.Hello) { return; }
	const answer = greet(m.version, processId(), s.vtBuild);
	s.sendTo(c, answer);
	if (answer.kind == MessageKind.Refused) {
		s.log(`client refused: ${answer.reason}`);
		c.conn.finish();
		return;
	}
	c.greeted = true;
	c.vtBuild = m.vtBuild;
	c.cols = m.cols;
	c.rows = m.rows;
}

function fit(this s: Server, cols: int32, rows: int32): void {
	if (cols < 1 || rows < 1) {
		s.log(`fit ${cols}x${rows} ignored: a size needs at least one cell`);
		return;
	}
	s.enqueue(async (): Promise<void> => {
		s.cols = cols;
		s.rows = rows;
		await s.run({ kind: CommandKind.Fit });
	});
}

function received(this s: Server, c: Client, m: Message): void {
	if (!c.greeted) {
		if (m.kind == MessageKind.Hello) {
			s.hello(c, m);
		} else {
			s.refuse(c, `${m.kind.toString()} before Hello`);
		}
		return;
	}
	if (m.kind == MessageKind.Attach) {
		s.enqueue(async (): Promise<void> => { await s.attach(c); });
	} else if (m.kind == MessageKind.Command) {
		const command = m.command;
		s.enqueue(async (): Promise<void> => { await s.run(command); });
	} else if (m.kind == MessageKind.Input) {
		const pane = m.pane;
		const bytes: Vec<uint8> = [...m.bytes];
		s.enqueue(async (): Promise<void> => {
			if (!s.hostOf().write(pane, bytes)) {
				s.log(`input for unknown pane ${pane as int32} dropped`);
			}
		});
	} else if (m.kind == MessageKind.Fit) {
		s.fit(m.cols, m.rows);
	} else if (m.kind == MessageKind.AskBusy) {
		const pane = m.pane;
		s.enqueue(async (): Promise<void> => {
			const busy = await s.hostOf().busy(pane);
			s.sendTo(c, { kind: MessageKind.Busy, pane: pane, busy: busy });
		});
	} else if (m.kind == MessageKind.Bye) {
		c.conn.finish();
	} else if (m.kind == MessageKind.AskStatus) {
		s.sendTo(c, { kind: MessageKind.Status, listeners: [...s.serving], clients: s.attachedIdentities() });
	} else if (m.kind == MessageKind.Stop) {
		s.log(`stop asked by ${c.identity}`);
		s.stop(0);
	} else {
		s.refuse(c, `${m.kind.toString()} is a message only the server sends`);
	}
}

function data(this s: Server, c: Client, chunk: uint8[]): void {
	const got = c.decoder.push(chunk);
	if (!got.ok) {
		s.refuse(c, `malformed stream: ${got.error.toString()}`);
		return;
	}
	for (const m of got.value) {
		if (!c.conn.isOpen()) { return; }
		s.received(c, m);
	}
}

function attachedIdentities(this s: Server): string[] {
	const out: string[] = [];
	for (const c of s.clients) {
		if (c.attached) { out.push(c.identity); }
	}
	return out;
}

function welcome(this s: Server, conn: Connection, identity: string): void {
	if (s.stopping) {
		conn.close();
		return;
	}
	const c = new Client(conn, identity);
	s.clients.push(c);
	conn.start((chunk: uint8[]): void => { s.data(c, chunk); }, (why: CloseReason): void => {
		s.clients = s.clients.filter((other: Client): boolean => other !== c);
		if (why == CloseReason.Backlogged) { s.log("a client fell too far behind and was cut"); }
	});
}

function admit(this s: Server, conn: Connection, tailnet: TailnetListen): void {
	const remote = peerAddress(conn.fd);
	if (remote === null) {
		s.log("tailnet peer refused: its address is unknown");
		conn.close();
		return;
	}
	if (s.admitting.length >= MAX_ADMITTING) {
		s.log(`tailnet peer ${remote} refused: ${MAX_ADMITTING} other peers are still being identified`);
		conn.close();
		return;
	}
	s.admitting.push(conn);
	const _checking = s.identify(conn, remote, tailnet);
}

async function identify(this s: Server, conn: Connection, remote: string, tailnet: TailnetListen): Promise<void> {
	const allowed = await tailnet.admit(remote);
	s.admitting = s.admitting.filter((other: Connection): boolean => other !== conn);
	if (s.stopping || !conn.isOpen()) {
		conn.close();
		return;
	}
	if (!allowed.ok) {
		s.log(`tailnet peer ${remote} refused: ${allowed.error.detail}`);
		conn.close();
		return;
	}
	const identity = identityOf(allowed.value);
	s.log(`tailnet peer ${remote} (${identity}) admitted`);
	s.welcome(conn, identity);
}

export function stop(this s: Server, code: int32): void {
	if (s.stopping) { return; }
	s.stopping = true;
	const _stopped = s.shutdown(code);
}

async function shutdown(this s: Server, code: int32): Promise<void> {
	for (const l of s.listeners) { l.close(); }
	s.listeners = [];
	for (const c of s.admitting) { c.close(); }
	s.admitting = [];
	serverWakeTo(-1);
	s.wakeIn?.close();
	s.wakeOut?.close();
	const host = s.host;
	if (host !== null) { await host.closeAll(); }
	for (const c of s.clients) { c.conn.finish(); }
	const deadline = Date.now() + FLUSH_ON_EXIT_MS;
	while (s.clients.length > 0 && Date.now() < deadline) { await sleepAsync(5); }
	for (const c of s.clients) { c.conn.close(); }
	s.resolve(code);
}

async function openWake(this s: Server): Promise<boolean> {
	const path = `${s.setup.socket}.wake`;
	const listening = listenUnix(path, {
		accepted: (c: Connection): void => {
			s.wakeIn = c;
			c.start((chunk: uint8[]): void => { s.kick(); }, (why: CloseReason): void => {
				if (!s.stopping) { s.log(`the pty wake closed: ${why.toString()}`); }
			});
		},
		failed: (): void => { s.log("the pty wake stopped accepting"); },
	});
	if (!listening.ok) {
		s.log(`the pty wake did not open: ${listening.error.toString()}`);
		return false;
	}
	const dialed = await connectToUnix(path, WAKE_CONNECT_MS);
	if (!dialed.ok) {
		listening.value.close();
		s.log(`the pty wake did not connect: ${dialed.error.toString()}`);
		return false;
	}
	const deadline = Date.now() + WAKE_CONNECT_MS;
	while (s.wakeIn === null && Date.now() < deadline) { await sleepAsync(1); }
	listening.value.close();
	if (s.wakeIn === null) {
		dialed.value.close();
		s.log("the pty wake was never accepted");
		return false;
	}
	s.wakeOut = dialed.value;
	serverWakeTo(dialed.value.fd);
	ptySetWake(serverWake);
	return true;
}

function listenTailnet(this s: Server, tailnet: TailnetListen): void {
	const address = tailnet.address;
	const listening = listenTcp(address, tailnet.port, {
		accepted: (c: Connection): void => { s.admit(c, tailnet); },
		failed: (): void => { s.log("the tailnet listener stopped accepting"); },
	});
	if (!listening.ok) {
		s.log(`tailnet ${address}:${tailnet.port} not served: ${listening.error.toString()}`);
		return;
	}
	s.listeners.push(listening.value);
	const serving = `tailnet ${address}:${tailnet.port} for ${tailnet.admits}`;
	s.serving.push(serving);
	s.log(`serving the ${serving}`);
}

export function listenRefusal(path: string, e: ListenError): string {
	return match (e) {
		ListenError.AlreadyRunning => `a server already answers at ${path}`,
		ListenError.UnsafeDir => `${path} is not in a directory only this user owns`,
		ListenError.BindFailed => `${path} could not be bound`,
		ListenError.ListenFailed => `${path} could not be listened on`,
	};
}

export async function start(this typeof Server, setup: ServerSetup): Promise<Result<Server, string>> {
	const workspace = Workspace.create(setup.dividerCells);
	if (!workspace.ok) { return Result.err(`no workspace: ${workspace.error.toString()}`); }
	const s = new Server(setup, workspace.value);
	const listening = listenUnix(setup.socket, {
		accepted: (c: Connection): void => { s.welcome(c, LOCAL); },
		failed: (): void => { s.log("the socket stopped accepting"); },
	});
	if (!listening.ok) { return Result.err(listenRefusal(setup.socket, listening.error)); }
	s.listeners.push(listening.value);
	s.serving.push(`unix ${setup.socket}`);
	s.host = PaneHost.open(setup.launch, {
		output: (pane: PaneId, seq: int64, bytes: Vec<uint8>): void => {
			s.broadcast({ kind: MessageKind.Output, pane: pane, seq: seq as uint64, bytes: [...bytes] });
		},
		exit: (pane: PaneId, code: int32): void => { s.exits.push({ pane: pane, code: code }); },
		failed: (pane: PaneId, failure: string): void => {
			s.log(`pane ${pane as int32}: ${failure}`);
			s.broadcast({ kind: MessageKind.Failed, pane: pane, reason: failure });
		},
	});
	if (!(await s.openWake())) {
		s.stop(1);
		await s.finished;
		return Result.err("the pty wake did not open");
	}
	const tailnet = setup.tailnet;
	if (tailnet !== null) { s.listenTailnet(tailnet); }
	s.log(`serving ${setup.socket}`);
	return Result.ok(s);
}

function logLine(line: string): void {
	console.error(line);
}

function tailnetOf(choice: TailnetChoice | null, say: (line: string) => void): TailnetListen | null {
	if (choice === null) { return null; }
	const self = tailnetSelf();
	if (!self.ok) {
		say(`haro server: tailnet off, unix socket only: ${self.error.detail}`);
		return null;
	}
	return tailnetListen(self.value, choice.port, choice.allow);
}

export function configuredTailnet(config: Config): TailnetChoice | null {
	if (!config.serverTailnet) { return null; }
	return { port: config.serverTailnetPort, allow: TailnetAllow.Owner };
}

export async function serveOn(
	options: ServeOptions,
	tailnet: TailnetChoice | null,
	log: (line: string) => void,
): Promise<int32> {
	const config = options.config;
	const started = await Server.start({
		launch: {
			command: config.command,
			shellScripts: options.shellScripts,
			startIn: options.startIn,
			originCwd: config.newPaneCwd == PaneCwd.Focused,
		},
		socket: socketPath(),
		dividerCells: options.dividerCells,
		tailnet: tailnetOf(tailnet, log),
		screenLimit: MAX_SCREEN_BYTES,
		log: log,
	});
	if (!started.ok) {
		log(`haro server: ${started.error}`);
		return 1;
	}
	return await started.value.finished;
}

export async function serve(options: ServeOptions): Promise<int32> {
	return await serveOn(options, configuredTailnet(options.config), logLine);
}
