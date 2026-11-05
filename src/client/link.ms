import { CloseReason, Connection } from "../server/transport";
import {
	Decoder,
	Message,
	MessageKind,
	PROTOCOL_VERSION,
	Role,
	create,
	encode,
	push,
} from "../server/protocol";
import { append } from "../pty/bytes";
import { PaneId, panes } from "../workspace/tree";
import { WorkspaceCommand } from "../workspace/workspace";
import { Layout, Screen, screenParts } from "./wire";

const POLL_MS = 5;

interface BusyWait {
	pane: PaneId;
	answer: (busy: boolean) => void;
}

function ignoreMessages(ms: Message[]): void {}
function ignoreEnd(why: string): void {}

function closeText(reason: CloseReason): string {
	return match (reason) {
		CloseReason.Closed => "the window closed the connection",
		CloseReason.PeerClosed => "the server closed the connection",
		CloseReason.SendFailed => "a send to the server failed",
		CloseReason.Backlogged => "the server stopped reading",
	};
}

export class ServerLink {
	readonly connection: Connection;
	private decoder: Decoder = Decoder.create();
	private held: Message[] = [];
	private listening: boolean = false;
	private handler: (ms: Message[]) => void = ignoreMessages;
	private onEnd: (why: string) => void = ignoreEnd;
	private busyWaits: BusyWait[] = [];
	ended: string | null = null;

	constructor(connection: Connection) { this.connection = connection; }

	begin(): void {
		this.connection.start(
			(chunk: uint8[]): void => { this.received(chunk); },
			(reason: CloseReason): void => { this.end(closeText(reason)); },
		);
	}

	received(chunk: uint8[]): void {
		const got = this.decoder.push(chunk);
		if (!got.ok) {
			this.connection.close();
			this.end(`the server sent a malformed message: ${got.error.toString()}`);
			return;
		}
		const kept: Message[] = [];
		for (const m of got.value) {
			if (this.answeredBusy(m)) { continue; }
			if (this.listening) {
				kept.push(m);
			} else {
				this.held.push(m);
			}
		}
		if (kept.length > 0) { this.handler(kept); }
	}

	answeredBusy(m: Message): boolean {
		if (m.kind != MessageKind.Busy) { return false; }
		const at = this.busyWaits.findIndex((w: BusyWait): boolean => w.pane == m.pane);
		if (at < 0) { return true; }
		const wait = this.busyWaits[at];
		this.busyWaits.splice(at, 1);
		wait.answer(m.busy);
		return true;
	}

	unanswered(): void {
		const waits = this.busyWaits;
		this.busyWaits = [];
		for (const w of waits) { w.answer(true); }
	}

	busy(pane: PaneId): Promise<boolean> {
		if (this.ended !== null) { return Promise.resolve(true); }
		this.send({ kind: MessageKind.AskBusy, pane: pane });
		return new Promise<boolean>((answer: (busy: boolean) => void): void => {
			this.busyWaits.push({ pane: pane, answer: answer });
		});
	}

	end(why: string): void {
		if (this.ended !== null) { return; }
		this.ended = why;
		this.unanswered();
		if (this.listening) { this.onEnd(why); }
	}

	take(): Message | null {
		if (this.held.length == 0) { return null; }
		return this.held.shift() ?? null;
	}

	putBack(kept: Message[]): void {
		this.held = [...kept, ...this.held];
	}

	listen(handler: (ms: Message[]) => void, onEnd: (why: string) => void): void {
		this.handler = handler;
		this.onEnd = onEnd;
		this.listening = true;
		const held = this.held;
		this.held = [];
		if (held.length > 0) { handler(held); }
		const ended = this.ended;
		if (ended !== null) { onEnd(ended); }
	}

	send(m: Message): void {
		const bytes = encode(m);
		if (!bytes.ok) {
			this.end(`a ${m.kind.toString()} message did not encode: ${bytes.error.toString()}`);
			return;
		}
		const _sent = this.connection.send(bytes.value);
	}

	command(c: WorkspaceCommand): void {
		this.send({ kind: MessageKind.Command, command: c });
	}

	input(pane: PaneId, bytes: Vec<uint8>): void {
		const out: uint8[] = [];
		out.append(bytes);
		this.send({ kind: MessageKind.Input, pane: pane, bytes: out });
	}

	fit(cols: int32, rows: int32): void {
		this.send({ kind: MessageKind.Fit, cols: cols, rows: rows });
	}

	detach(): void {
		this.listening = false;
		this.handler = ignoreMessages;
		this.onEnd = ignoreEnd;
		this.unanswered();
		this.send({ kind: MessageKind.Bye });
		this.connection.finish();
	}
}

export enum Failure {
	Offline,
	Refused,
	Unkept,
}

export struct DialError {
	failure: Failure;
	why: string;
	command: string;
}

export type Dial = (uploading: () => void) => Promise<Result<Connection, DialError>>;

export function offline(why: string): DialError {
	return { failure: Failure.Offline, why: why, command: "" };
}

export function refused(why: string): DialError {
	return { failure: Failure.Refused, why: why, command: "" };
}

export interface Linked {
	link: ServerLink;
	attached: Attached;
}

export struct Attached {
	serverPid: int32;
	vtBuild: string;
	layout: Layout;
	screens: Screen[];
}

async function next(link: ServerLink, deadline: float64): Promise<Message | null> {
	while (true) {
		const m = link.take();
		if (m !== null) { return m; }
		if (link.ended !== null || performance.now() > deadline) { return null; }
		await sleepAsync(POLL_MS);
	}
}

function stopped(link: ServerLink, waiting: string): DialError {
	return offline(link.ended ?? `the server sent no ${waiting} in time`);
}

function paneIds(layout: Layout): PaneId[] {
	const ids: PaneId[] = [];
	for (const tab of layout.tabs) {
		for (const p of tab.root.panes()) { ids.push(p.id); }
	}
	return ids;
}

function missing(ids: PaneId[], screens: Screen[]): boolean {
	for (const id of ids) {
		if (!screens.some((s: Screen): boolean => s.pane == id)) { return true; }
	}
	return false;
}

export async function attach(
	link: ServerLink,
	vtBuild: string,
	cols: int32,
	rows: int32,
	timeoutMs: int32,
): Promise<Result<Attached, DialError>> {
	const deadline = performance.now() + (timeoutMs as float64);
	link.send({
		kind: MessageKind.Hello,
		version: PROTOCOL_VERSION,
		role: Role.Window,
		cols: cols,
		rows: rows,
		vtBuild: vtBuild,
	});
	const greeted = await next(link, deadline);
	if (greeted === null) { return Result.err(stopped(link, "welcome")); }
	if (greeted.kind == MessageKind.Refused) {
		return Result.err(refused(greeted.reason));
	}
	if (greeted.kind != MessageKind.Welcome) {
		return Result.err(offline(`the server answered hello with ${greeted.kind.toString()}`));
	}
	if (greeted.version != PROTOCOL_VERSION) {
		return Result.err(refused(
			`the server speaks protocol ${greeted.version}, this window ${PROTOCOL_VERSION}`,
		));
	}
	link.send({ kind: MessageKind.Attach });
	let layout: Layout | null = null;
	const screens: Screen[] = [];
	const later: Message[] = [];
	while (layout === null || missing(paneIds(layout), screens)) {
		const m = await next(link, deadline);
		if (m === null) { return Result.err(stopped(link, "layout and screens")); }
		const parts = screenParts(m);
		if (parts === null) {
			later.push(m);
		} else {
			if (parts.layout !== null) { layout = parts.layout; }
			for (const s of parts.screens) { screens.push(s); }
		}
	}
	link.putBack(later);
	return Result.ok({
		serverPid: greeted.serverPid,
		vtBuild: greeted.vtBuild,
		layout: layout,
		screens: screens,
	});
}

export async function linkTo(
	dial: Dial,
	uploading: () => void,
	vtBuild: string,
	cols: int32,
	rows: int32,
	timeoutMs: int32,
): Promise<Result<Linked, DialError>> {
	const connected = await dial(uploading);
	if (!connected.ok) { return Result.err(connected.error); }
	const link = new ServerLink(connected.value);
	link.begin();
	const got = await attach(link, vtBuild, cols, rows, timeoutMs);
	if (!got.ok) {
		link.connection.close();
		return Result.err(got.error);
	}
	return Result.ok({ link: link, attached: got.value });
}
