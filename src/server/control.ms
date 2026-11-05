import {
	Decoder,
	Message,
	MessageKind,
	PROTOCOL_VERSION,
	Role,
	create as decoder,
	encode,
	push,
} from "./protocol";
import { CloseReason, Connection, PeerProgram, connectToUnix, peerProgram } from "./transport";

const CONNECT_MS: int32 = 1000;
const ANSWER_MS: int32 = 5000;
const STOP_MS: int32 = 15000;
const POLL_MS: int32 = 5;

export struct StatusReport {
	pid: int32;
	listeners: string[];
	clients: string[];
}

class Asker {
	readonly conn: Connection;
	readonly peer: PeerProgram | null;
	decoder: Decoder = Decoder.create();
	got: Message[] = [];
	closed: boolean = false;
	broken: string = "";

	constructor(conn: Connection) {
		this.conn = conn;
		this.peer = peerProgram(conn.fd);
	}
}

function say(this a: Asker, m: Message): void {
	const bytes = encode(m);
	if (bytes.ok) { const _sent = a.conn.send(bytes.value); }
}

function found(this a: Asker, kind: MessageKind): Message | null {
	for (const m of a.got) {
		if (m.kind == kind) { return m; }
	}
	return null;
}

async function waitFor(this a: Asker, done: () => boolean, timeoutMs: int32): Promise<boolean> {
	const deadline = Date.now() + timeoutMs;
	while (!done()) {
		if (Date.now() > deadline) { return false; }
		await sleepAsync(POLL_MS);
	}
	return true;
}

export function nobody(socket: string): string {
	return `no Haro server answers at ${socket}`;
}

async function dialed(socket: string): Promise<Asker | null> {
	const got = await connectToUnix(socket, CONNECT_MS);
	if (!got.ok) { return null; }
	const a = new Asker(got.value);
	a.conn.start((chunk: uint8[]): void => {
		const got = a.decoder.push(chunk);
		if (!got.ok) {
			a.broken = got.error.toString();
			return;
		}
		for (const m of got.value) { a.got.push(m); }
	}, (why: CloseReason): void => { a.closed = true; });
	a.say({ kind: MessageKind.Hello, version: PROTOCOL_VERSION, role: Role.Cli, cols: 0, rows: 0, vtBuild: "" });
	const _answered = await a.waitFor((): boolean => a.got.length > 0 || a.closed || a.broken != "", ANSWER_MS);
	return a;
}

async function greeted(socket: string): Promise<Result<Asker, string>> {
	const a = await dialed(socket);
	if (a === null) { return Result.err(nobody(socket)); }
	if (a.broken != "") { return Result.err(`the server at ${socket} sent a malformed stream: ${a.broken}`); }
	if (a.got.length == 0) {
		a.conn.close();
		return Result.err(`the server at ${socket} did not answer Hello`);
	}
	const first = a.got[0];
	if (first.kind == MessageKind.Refused) { return Result.err(`the server at ${socket} refused: ${first.reason}`); }
	if (first.kind != MessageKind.Welcome) {
		a.conn.close();
		return Result.err(`the server at ${socket} answered Hello with ${first.kind.toString()}`);
	}
	return Result.ok(a);
}

function pidOf(a: Asker): int32 {
	const welcome = a.got[0];
	return welcome.kind == MessageKind.Welcome ? welcome.serverPid : 0;
}

export async function answeringPid(socket: string): Promise<int32 | null> {
	const a = await greeted(socket);
	if (!a.ok) { return null; }
	a.value.say({ kind: MessageKind.Bye });
	a.value.conn.finish();
	return pidOf(a.value);
}

export async function askStatus(socket: string): Promise<Result<StatusReport, string>> {
	const a = try await greeted(socket);
	a.say({ kind: MessageKind.AskStatus });
	const answered = await a.waitFor((): boolean => a.found(MessageKind.Status) !== null || a.closed, ANSWER_MS);
	const status = a.found(MessageKind.Status);
	a.conn.close();
	if (!answered || status === null || status.kind != MessageKind.Status) {
		return Result.err(`the server at ${socket} did not answer the status request`);
	}
	return Result.ok({ pid: pidOf(a), listeners: [...status.listeners], clients: [...status.clients] });
}

export async function askStop(socket: string): Promise<Result<int32, string>> {
	const a = try await greeted(socket);
	const pid = pidOf(a);
	a.say({ kind: MessageKind.Stop });
	if (!(await a.waitFor((): boolean => a.closed, STOP_MS))) {
		a.conn.close();
		return Result.err(`the server ${pid} at ${socket} was asked to stop and still runs after ${STOP_MS / 1000} s`);
	}
	return Result.ok(pid);
}

export function otherVersionAdvice(socket: string, reason: string, peer: PeerProgram | null): string {
	const said = `A Haro server of another version answers at ${socket} and keeps its shells (${reason}).`;
	if (peer === null || peer.path == "") {
		return `${said} Close its shells and stop it with the Haro it came from, then connect again.`;
	}
	if (peer.path.endsWith("/haro-server")) {
		return `${said} Close its shells and run ${peer.path} stop, then connect again.`;
	}
	return `${said} It is ${peer.path}, pid ${peer.pid}: close its shells, end it with kill ${peer.pid}, then connect again.`;
}

export async function otherVersion(socket: string): Promise<string | null> {
	const a = await dialed(socket);
	if (a === null) { return null; }
	const first: Message | null = a.got.length > 0 ? a.got[0] : null;
	if (first !== null && first.kind == MessageKind.Refused) {
		a.conn.close();
		return otherVersionAdvice(socket, first.reason, a.peer);
	}
	a.say({ kind: MessageKind.Bye });
	a.conn.finish();
	return null;
}
