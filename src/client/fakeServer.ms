import {
	CloseReason,
	Connection,
	ListenError,
	Listener,
	listenUnix,
} from "../server/transport";
import {
	Decoder,
	Message,
	MessageKind,
	ScreenFormat,
	create,
	encode,
	greet,
	push,
} from "../server/protocol";
import { nativeSnapshot, snapshot, vtBuild } from "../vt/snapshot";
import { Vt, create, dropReplies, free, resize, write } from "../vt/vt";
import { PaneId } from "../workspace/tree";
import {
	CommandKind,
	EventKind,
	Workspace,
	WorkspaceCommand,
	WorkspaceEvent,
	apply,
	create,
} from "../workspace/workspace";
import { Screen, screenMessages } from "./wire";

const CR: uint8 = 0x0d;
const LF: uint8 = 0x0a;

export interface FakePane {
	id: PaneId;
	vt: Vt;
	cols: int32;
	rows: int32;
	seq: uint64;
}

export class FakeServer {
	readonly format: ScreenFormat;
	w: Workspace;
	cols: int32 = 80;
	rows: int32 = 24;
	panes: FakePane[] = [];
	listener: Listener | null = null;
	commands: int32 = 0;
	byes: int32 = 0;
	latest: Connection | null = null;
	busyPanes: PaneId[] = [];

	constructor(format: ScreenFormat, w: Workspace) {
		this.format = format;
		this.w = w;
	}

	paneOf(id: PaneId): FakePane | null {
		for (const p of this.panes) {
			if (p.id == id) { return p; }
		}
		return null;
	}

	accepted(c: Connection): void {
		this.latest = c;
		const decoder = Decoder.create();
		c.start((chunk: uint8[]): void => {
			const got = decoder.push(chunk);
			if (!got.ok) {
				c.close();
				return;
			}
			for (const m of got.value) { this.handle(c, m); }
		}, (reason: CloseReason): void => {});
	}

	send(c: Connection, m: Message): void {
		const bytes = encode(m);
		if (bytes.ok) { const _sent = c.send(bytes.value); }
	}

	screens(): Screen[] {
		const out: Screen[] = [];
		for (const p of this.panes) {
			const native = this.format == ScreenFormat.Native;
			const shot = native ? p.vt.nativeSnapshot() : p.vt.snapshot();
			if (shot.ok) {
				out.push({
					pane: p.id,
					seed: {
						native: native,
						cols: p.cols,
						rows: p.rows,
						bytes: shot.value,
					},
				});
			}
		}
		return out;
	}

	layoutTo(c: Connection, screens: Screen[]): void {
		const layout = { tabs: this.w.tabs, active: this.w.active };
		for (const m of screenMessages(layout, screens)) { this.send(c, m); }
	}

	opened(e: WorkspaceEvent): void {
		if (e.kind == EventKind.PaneOpened) {
			const vt = Vt.create(e.rect.cols, e.rect.rows);
			if (vt.ok) {
				this.panes.push({
					id: e.pane,
					vt: vt.value,
					cols: e.rect.cols,
					rows: e.rect.rows,
					seq: 0,
				});
			}
		} else if (e.kind == EventKind.PaneResized) {
			const p = this.paneOf(e.pane);
			if (p !== null && p.vt.resize(e.rect.cols, e.rect.rows).ok) {
				p.cols = e.rect.cols;
				p.rows = e.rect.rows;
			}
		} else if (e.kind == EventKind.PaneClosed) {
			const gone = this.paneOf(e.pane);
			if (gone !== null) {
				gone.vt.free();
				this.panes = this.panes.filter((p: FakePane): boolean => !(p.id == e.pane));
			}
		}
	}

	apply(command: WorkspaceCommand): WorkspaceEvent[] {
		this.commands += 1;
		const applied = this.w.apply(command, this.cols, this.rows);
		if (!applied.ok) { return []; }
		for (const e of applied.value) { this.opened(e); }
		return applied.value;
	}

	run(c: Connection, command: WorkspaceCommand): void {
		const events = this.apply(command);
		if (events.length == 0) { return; }
		this.layoutTo(c, []);
		for (const e of events) { this.send(c, { kind: MessageKind.Event, event: e }); }
	}

	endPane(id: PaneId, why: Message): void {
		const c = this.latest;
		if (c === null) { return; }
		this.send(c, why);
		this.run(c, { kind: CommandKind.ClosePane, pane: id });
	}

	echo(c: Connection, id: PaneId, bytes: uint8[]): void {
		const p = this.paneOf(id);
		if (p === null) { return; }
		const out: uint8[] = [];
		for (const b of bytes) {
			out.push(b);
			if (b == CR) { out.push(LF); }
		}
		p.vt.write(out);
		p.vt.dropReplies();
		p.seq += 1;
		this.send(c, { kind: MessageKind.Output, pane: id, seq: p.seq, bytes: out });
	}

	handle(c: Connection, m: Message): void {
		if (m.kind == MessageKind.Hello) {
			this.send(c, greet(m.version, 0, vtBuild()));
		} else if (m.kind == MessageKind.Attach) {
			this.layoutTo(c, this.screens());
		} else if (m.kind == MessageKind.Command) {
			this.run(c, m.command);
		} else if (m.kind == MessageKind.Fit) {
			this.cols = m.cols;
			this.rows = m.rows;
			this.run(c, { kind: CommandKind.Fit });
		} else if (m.kind == MessageKind.Input) {
			this.echo(c, m.pane, m.bytes);
		} else if (m.kind == MessageKind.AskBusy) {
			const busy = this.busyPanes.includes(m.pane);
			this.send(c, { kind: MessageKind.Busy, pane: m.pane, busy: busy });
		} else if (m.kind == MessageKind.Bye) {
			this.byes += 1;
			c.close();
		}
	}

	close(): void {
		this.listener?.close();
		for (const p of this.panes) { p.vt.free(); }
		this.panes = [];
	}
}

export function startFake(
	path: string,
	format: ScreenFormat,
): Result<FakeServer, ListenError> {
	const w = Workspace.create(1);
	if (!w.ok) { throw new Error(`fake server: ${w.error.toString()}`); }
	const server = new FakeServer(format, w.value);
	const listener = try listenUnix(path, {
		accepted: (c: Connection): void => { server.accepted(c); },
		failed: (): void => {},
	});
	server.listener = listener;
	return Result.ok(server);
}
