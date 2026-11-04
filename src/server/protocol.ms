import {
	Axis,
	CellRect,
	Node,
	NodeKind,
	Pane,
	PaneId,
	TabId,
} from "../workspace/tree";
import {
	CommandKind,
	Direction,
	EventKind,
	Tab,
	TabEntry,
	WorkspaceCommand,
	WorkspaceEvent,
} from "../workspace/workspace";

export const PROTOCOL_VERSION: uint32 = 1;
export const HEADER_BYTES: int32 = 5;
export const MAX_PAYLOAD_BYTES: int32 = 64 * 1024 * 1024;
export const MAX_TREE_DEPTH: int32 = 128;

export enum Role {
	Window,
	Cli,
}

export enum ScreenFormat {
	VtBytes,
	Native,
}

export enum MessageKind {
	Hello,
	Welcome,
	Attach,
	Layout,
	Screen,
	Command,
	Event,
	Input,
	Output,
	Fit,
	Exited,
	Failed,
	Refused,
	Bye,
}

const SCREEN_FIELDS_BYTES: int32 = 17;
export const MAX_SCREEN_BYTES: int32 = MAX_PAYLOAD_BYTES - SCREEN_FIELDS_BYTES;

export struct Message = match (kind: MessageKind) {
	MessageKind.Hello => {
		version: uint32,
		role: Role,
		cols: int32,
		rows: int32,
		vtBuild: string,
	},
	MessageKind.Welcome => {
		version: uint32,
		serverPid: int32,
		vtBuild: string,
	},
	MessageKind.Attach => {},
	MessageKind.Layout => { tabs: Tab[], active: TabId | null },
	MessageKind.Screen => {
		pane: PaneId,
		cols: int32,
		rows: int32,
		format: ScreenFormat,
		bytes: uint8[],
	},
	MessageKind.Command => { command: WorkspaceCommand },
	MessageKind.Event => { event: WorkspaceEvent },
	MessageKind.Input => { pane: PaneId, bytes: uint8[] },
	MessageKind.Output => { pane: PaneId, seq: uint64, bytes: uint8[] },
	MessageKind.Fit => { cols: int32, rows: int32 },
	MessageKind.Exited => { pane: PaneId, code: int32 },
	MessageKind.Failed => { pane: PaneId, reason: string },
	MessageKind.Refused => { reason: string },
	MessageKind.Bye => {},
};

export enum ProtocolError {
	PayloadTooLarge,
	UnknownMessageType,
	PayloadTruncated,
	TrailingBytes,
	UnknownRole,
	UnknownScreenFormat,
	UnknownCommand,
	UnknownEvent,
	UnknownAxis,
	UnknownDirection,
	UnknownNodeKind,
	BadPresenceTag,
	MalformedText,
	RatioOutOfRange,
	TreeTooDeep,
}

export const MESSAGE_KINDS: MessageKind[] = [
	MessageKind.Hello,
	MessageKind.Welcome,
	MessageKind.Attach,
	MessageKind.Layout,
	MessageKind.Screen,
	MessageKind.Command,
	MessageKind.Event,
	MessageKind.Input,
	MessageKind.Output,
	MessageKind.Fit,
	MessageKind.Exited,
	MessageKind.Failed,
	MessageKind.Refused,
	MessageKind.Bye,
];
export const ROLES: Role[] = [Role.Window, Role.Cli];
export const SCREEN_FORMATS: ScreenFormat[] = [
	ScreenFormat.VtBytes,
	ScreenFormat.Native,
];
export const AXES: Axis[] = [Axis.SideBySide, Axis.Stacked];
export const NODE_KINDS: NodeKind[] = [NodeKind.Pane, NodeKind.Split];
export const DIRECTIONS: Direction[] = [
	Direction.Left,
	Direction.Right,
	Direction.Up,
	Direction.Down,
];
export const COMMAND_KINDS: CommandKind[] = [
	CommandKind.NewTab,
	CommandKind.CloseTab,
	CommandKind.GotoTab,
	CommandKind.CycleTab,
	CommandKind.MoveTab,
	CommandKind.RenameTab,
	CommandKind.Split,
	CommandKind.ClosePane,
	CommandKind.FocusPane,
	CommandKind.FocusDirection,
	CommandKind.CyclePane,
	CommandKind.Resize,
	CommandKind.MoveDivider,
	CommandKind.ToggleZoom,
	CommandKind.Fit,
];
export const EVENT_KINDS: EventKind[] = [
	EventKind.PaneClosed,
	EventKind.TabsChanged,
	EventKind.PaneOpened,
	EventKind.PaneResized,
	EventKind.ZoomChanged,
	EventKind.FocusChanged,
	EventKind.WorkspaceEmpty,
];

export function greet(
	version: uint32,
	serverPid: int32,
	vtBuild: string,
): Message {
	if (version != PROTOCOL_VERSION) {
		return {
			kind: MessageKind.Refused,
			reason: `protocol version ${version} refused: ` +
				`this server speaks ${PROTOCOL_VERSION}`,
		};
	}
	return {
		kind: MessageKind.Welcome,
		version: PROTOCOL_VERSION,
		serverPid: serverPid,
		vtBuild: vtBuild,
	};
}

export function screenFormat(
	clientVtBuild: string,
	serverVtBuild: string,
): ScreenFormat {
	if (clientVtBuild.length > 0 && clientVtBuild == serverVtBuild) {
		return ScreenFormat.Native;
	}
	return ScreenFormat.VtBytes;
}

interface Writer {
	bytes: uint8[];
	tooDeep: boolean;
}

function u8(this w: Writer, v: uint8): void {
	w.bytes.push(v);
}

function u32(this w: Writer, v: uint32): void {
	w.bytes.push(((v >> 24) & 0xff) as uint8);
	w.bytes.push(((v >> 16) & 0xff) as uint8);
	w.bytes.push(((v >> 8) & 0xff) as uint8);
	w.bytes.push((v & 0xff) as uint8);
}

function u64(this w: Writer, v: uint64): void {
	w.u32(((v >> 32) & 0xffffffff) as uint32);
	w.u32((v & 0xffffffff) as uint32);
}

function i32(this w: Writer, v: int32): void {
	w.u32(v as uint32);
}

function i64(this w: Writer, v: int64): void {
	w.u64(v as uint64);
}

function f64(this w: Writer, v: float64): void {
	const bits = Buffer.alloc(8);
	bits.writeDoubleBE(v, 0);
	for (const b of bits) { w.bytes.push(b); }
}

function flag(this w: Writer, present: boolean): void {
	w.u8(present ? 1 : 0);
}

function blob(this w: Writer, bytes: Readonly<Span<uint8>>): void {
	w.u32(bytes.length as uint32);
	for (const b of bytes) { w.bytes.push(b); }
}

function text(this w: Writer, s: string): void {
	w.blob(s.asBytes());
}

function optionalText(this w: Writer, s: string | null): void {
	w.flag(s !== null);
	if (s !== null) { w.text(s); }
}

function pane(this w: Writer, id: PaneId): void {
	w.i32(id as int32);
}

function optionalPane(this w: Writer, id: PaneId | null): void {
	w.flag(id !== null);
	if (id !== null) { w.pane(id); }
}

function tab(this w: Writer, id: TabId): void {
	w.i32(id as int32);
}

function optionalTab(this w: Writer, id: TabId | null): void {
	w.flag(id !== null);
	if (id !== null) { w.tab(id); }
}

function rect(this w: Writer, r: CellRect): void {
	w.i32(r.x);
	w.i32(r.y);
	w.i32(r.cols);
	w.i32(r.rows);
}

function node(this w: Writer, n: Node, depth: int32): void {
	if (depth > MAX_TREE_DEPTH) {
		w.tooDeep = true;
		return;
	}
	w.u8(n.kind as uint8);
	if (n.kind == NodeKind.Pane) {
		w.pane(n.pane.id);
		w.optionalPane(n.pane.origin);
		w.i64(n.pane.focusedAt);
		w.rect(n.pane.rect);
		return;
	}
	w.u8(n.split.axis as uint8);
	w.f64(n.split.ratio);
	w.node(n.split.first, depth + 1);
	w.node(n.split.second, depth + 1);
}

function command(this w: Writer, c: WorkspaceCommand): void {
	w.u8(c.kind as uint8);
	if (c.kind == CommandKind.CloseTab) {
		w.tab(c.tab);
	} else if (c.kind == CommandKind.GotoTab) {
		w.i32(c.index);
	} else if (
		c.kind == CommandKind.CycleTab ||
		c.kind == CommandKind.MoveTab ||
		c.kind == CommandKind.CyclePane
	) {
		w.i32(c.by);
	} else if (c.kind == CommandKind.RenameTab) {
		w.tab(c.tab);
		w.optionalText(c.title);
	} else if (c.kind == CommandKind.Split) {
		w.pane(c.pane);
		w.u8(c.axis as uint8);
	} else if (
		c.kind == CommandKind.ClosePane || c.kind == CommandKind.FocusPane
	) {
		w.pane(c.pane);
	} else if (c.kind == CommandKind.FocusDirection) {
		w.u8(c.direction as uint8);
	} else if (c.kind == CommandKind.Resize) {
		w.u8(c.direction as uint8);
		w.i32(c.cells);
	} else if (c.kind == CommandKind.MoveDivider) {
		w.pane(c.pane);
		w.u8(c.axis as uint8);
		w.i32(c.by);
	}
}

function event(this w: Writer, e: WorkspaceEvent): void {
	w.u8(e.kind as uint8);
	if (e.kind == EventKind.PaneClosed || e.kind == EventKind.FocusChanged) {
		w.pane(e.pane);
	} else if (e.kind == EventKind.TabsChanged) {
		w.u32(e.tabs.length as uint32);
		for (const entry of e.tabs) {
			w.tab(entry.id);
			w.optionalText(entry.title);
		}
		w.optionalTab(e.active);
	} else if (e.kind == EventKind.PaneOpened) {
		w.pane(e.pane);
		w.tab(e.tab);
		w.optionalPane(e.origin);
		w.rect(e.rect);
	} else if (e.kind == EventKind.PaneResized) {
		w.pane(e.pane);
		w.rect(e.rect);
	} else if (e.kind == EventKind.ZoomChanged) {
		w.tab(e.tab);
		w.optionalPane(e.pane);
	}
}

function payload(this w: Writer, m: Message): void {
	if (m.kind == MessageKind.Hello) {
		w.u32(m.version);
		w.u8(m.role as uint8);
		w.i32(m.cols);
		w.i32(m.rows);
		w.text(m.vtBuild);
	} else if (m.kind == MessageKind.Welcome) {
		w.u32(m.version);
		w.i32(m.serverPid);
		w.text(m.vtBuild);
	} else if (m.kind == MessageKind.Layout) {
		w.u32(m.tabs.length as uint32);
		for (const t of m.tabs) {
			w.tab(t.id);
			w.optionalText(t.title);
			w.node(t.root, 1);
			w.pane(t.focused);
			w.optionalPane(t.zoomed);
		}
		w.optionalTab(m.active);
	} else if (m.kind == MessageKind.Screen) {
		w.pane(m.pane);
		w.i32(m.cols);
		w.i32(m.rows);
		w.u8(m.format as uint8);
		w.blob(m.bytes);
	} else if (m.kind == MessageKind.Command) {
		w.command(m.command);
	} else if (m.kind == MessageKind.Event) {
		w.event(m.event);
	} else if (m.kind == MessageKind.Input) {
		w.pane(m.pane);
		w.blob(m.bytes);
	} else if (m.kind == MessageKind.Output) {
		w.pane(m.pane);
		w.u64(m.seq);
		w.blob(m.bytes);
	} else if (m.kind == MessageKind.Fit) {
		w.i32(m.cols);
		w.i32(m.rows);
	} else if (m.kind == MessageKind.Exited) {
		w.pane(m.pane);
		w.i32(m.code);
	} else if (m.kind == MessageKind.Failed) {
		w.pane(m.pane);
		w.text(m.reason);
	} else if (m.kind == MessageKind.Refused) {
		w.text(m.reason);
	}
}

export function encode(m: Message): Result<uint8[], ProtocolError> {
	const w: Writer = { bytes: [], tooDeep: false };
	w.u32(0);
	w.u8(m.kind as uint8);
	w.payload(m);
	if (w.tooDeep) { return Result.err(ProtocolError.TreeTooDeep); }
	const length = w.bytes.length - HEADER_BYTES;
	if (length > MAX_PAYLOAD_BYTES) {
		return Result.err(ProtocolError.PayloadTooLarge);
	}
	const size = length as uint32;
	w.bytes[0] = ((size >> 24) & 0xff) as uint8;
	w.bytes[1] = ((size >> 16) & 0xff) as uint8;
	w.bytes[2] = ((size >> 8) & 0xff) as uint8;
	w.bytes[3] = (size & 0xff) as uint8;
	return Result.ok(w.bytes);
}

interface Reader {
	bytes: uint8[];
	at: int32;
	end: int32;
}

function code<T>(
	table: T[],
	value: uint8,
	unknown: ProtocolError,
): Result<T, ProtocolError> {
	if ((value as int32) >= table.length) { return Result.err(unknown); }
	return Result.ok(table[value as int32]);
}

function take(this r: Reader, count: int32): Result<int32, ProtocolError> {
	if (count < 0 || r.end - r.at < count) {
		return Result.err(ProtocolError.PayloadTruncated);
	}
	const at = r.at;
	r.at += count;
	return Result.ok(at);
}

function u8(this r: Reader): Result<uint8, ProtocolError> {
	const at = try r.take(1);
	return Result.ok(r.bytes[at]);
}

function bigEndian(bytes: uint8[], at: int32): uint32 {
	return (bytes[at] as uint32) << 24 |
		(bytes[at + 1] as uint32) << 16 |
		(bytes[at + 2] as uint32) << 8 |
		bytes[at + 3] as uint32;
}

function u32(this r: Reader): Result<uint32, ProtocolError> {
	const at = try r.take(4);
	return Result.ok(bigEndian(r.bytes, at));
}

function u64(this r: Reader): Result<uint64, ProtocolError> {
	const high = try r.u32();
	const low = try r.u32();
	return Result.ok((high as uint64) << 32 | low as uint64);
}

function i32(this r: Reader): Result<int32, ProtocolError> {
	const v = try r.u32();
	if (v < 0x80000000) { return Result.ok(v as int32); }
	return Result.ok(-((~v) as int32) - 1);
}

function i64(this r: Reader): Result<int64, ProtocolError> {
	const v = try r.u64();
	if (v < 0x8000000000000000) { return Result.ok(v as int64); }
	return Result.ok(-((~v) as int64) - 1);
}

function f64(this r: Reader): Result<float64, ProtocolError> {
	const at = try r.take(8);
	const bits = r.bytes.slice(at, at + 8) as Buffer;
	return Result.ok(bits.readDoubleBE(0));
}

function flag(this r: Reader): Result<boolean, ProtocolError> {
	const v = try r.u8();
	if (v > 1) { return Result.err(ProtocolError.BadPresenceTag); }
	return Result.ok(v == 1);
}

function count(this r: Reader): Result<int32, ProtocolError> {
	const n = try r.u32();
	if ((n as int64) > ((r.end - r.at) as int64)) {
		return Result.err(ProtocolError.PayloadTruncated);
	}
	return Result.ok(n as int32);
}

function blob(this r: Reader): Result<uint8[], ProtocolError> {
	const n = try r.count();
	const at = try r.take(n);
	return Result.ok(r.bytes.slice(at, at + n));
}

function text(this r: Reader): Result<string, ProtocolError> {
	const bytes = (try r.blob()) as Buffer;
	if (!Buffer.isUtf8(bytes)) {
		return Result.err(ProtocolError.MalformedText);
	}
	return Result.ok(bytes.toString());
}

function optionalText(this r: Reader): Result<string | null, ProtocolError> {
	if (!(try r.flag())) { return Result.ok(null); }
	return Result.ok(try r.text());
}

function pane(this r: Reader): Result<PaneId, ProtocolError> {
	return Result.ok((try r.i32()) as PaneId);
}

function optionalPane(this r: Reader): Result<PaneId | null, ProtocolError> {
	if (!(try r.flag())) { return Result.ok(null); }
	return Result.ok(try r.pane());
}

function tab(this r: Reader): Result<TabId, ProtocolError> {
	return Result.ok((try r.i32()) as TabId);
}

function optionalTab(this r: Reader): Result<TabId | null, ProtocolError> {
	if (!(try r.flag())) { return Result.ok(null); }
	return Result.ok(try r.tab());
}

function rect(this r: Reader): Result<CellRect, ProtocolError> {
	const x = try r.i32();
	const y = try r.i32();
	const cols = try r.i32();
	const rows = try r.i32();
	return Result.ok({ x: x, y: y, cols: cols, rows: rows });
}

function axis(this r: Reader): Result<Axis, ProtocolError> {
	return code(AXES, try r.u8(), ProtocolError.UnknownAxis);
}

function direction(this r: Reader): Result<Direction, ProtocolError> {
	return code(DIRECTIONS, try r.u8(), ProtocolError.UnknownDirection);
}

function node(this r: Reader, depth: int32): Result<Node, ProtocolError> {
	if (depth > MAX_TREE_DEPTH) {
		return Result.err(ProtocolError.TreeTooDeep);
	}
	const kind = try code(NODE_KINDS, try r.u8(), ProtocolError.UnknownNodeKind);
	if (kind == NodeKind.Pane) {
		const id = try r.pane();
		const origin = try r.optionalPane();
		const focusedAt = try r.i64();
		const placed = try r.rect();
		const leaf: Pane = {
			id: id,
			origin: origin,
			focusedAt: focusedAt,
			rect: placed,
		};
		return Result.ok({ kind: NodeKind.Pane, pane: leaf });
	}
	const along = try r.axis();
	const ratio = try r.f64();
	if (!(ratio >= 0 && ratio <= 1)) {
		return Result.err(ProtocolError.RatioOutOfRange);
	}
	const first = try r.node(depth + 1);
	const second = try r.node(depth + 1);
	return Result.ok({
		kind: NodeKind.Split,
		split: { axis: along, ratio: ratio, first: first, second: second },
	});
}

function command(this r: Reader): Result<WorkspaceCommand, ProtocolError> {
	const kind = try code(
		COMMAND_KINDS,
		try r.u8(),
		ProtocolError.UnknownCommand,
	);
	return match (kind) {
		CommandKind.NewTab => Result.ok({ kind: CommandKind.NewTab }),
		CommandKind.CloseTab => {
			const id = try r.tab();
			Result.ok({ kind: CommandKind.CloseTab, tab: id })
		},
		CommandKind.GotoTab => {
			const index = try r.i32();
			Result.ok({ kind: CommandKind.GotoTab, index: index })
		},
		CommandKind.CycleTab => {
			const by = try r.i32();
			Result.ok({ kind: CommandKind.CycleTab, by: by })
		},
		CommandKind.MoveTab => {
			const by = try r.i32();
			Result.ok({ kind: CommandKind.MoveTab, by: by })
		},
		CommandKind.RenameTab => {
			const id = try r.tab();
			const title = try r.optionalText();
			Result.ok({ kind: CommandKind.RenameTab, tab: id, title: title })
		},
		CommandKind.Split => {
			const id = try r.pane();
			const along = try r.axis();
			Result.ok({ kind: CommandKind.Split, pane: id, axis: along })
		},
		CommandKind.ClosePane => {
			const id = try r.pane();
			Result.ok({ kind: CommandKind.ClosePane, pane: id })
		},
		CommandKind.FocusPane => {
			const id = try r.pane();
			Result.ok({ kind: CommandKind.FocusPane, pane: id })
		},
		CommandKind.FocusDirection => {
			const d = try r.direction();
			Result.ok({ kind: CommandKind.FocusDirection, direction: d })
		},
		CommandKind.CyclePane => {
			const by = try r.i32();
			Result.ok({ kind: CommandKind.CyclePane, by: by })
		},
		CommandKind.Resize => {
			const d = try r.direction();
			const cells = try r.i32();
			Result.ok({ kind: CommandKind.Resize, direction: d, cells: cells })
		},
		CommandKind.MoveDivider => {
			const id = try r.pane();
			const along = try r.axis();
			const by = try r.i32();
			Result.ok({
				kind: CommandKind.MoveDivider,
				pane: id,
				axis: along,
				by: by,
			})
		},
		CommandKind.ToggleZoom => Result.ok({ kind: CommandKind.ToggleZoom }),
		CommandKind.Fit => Result.ok({ kind: CommandKind.Fit }),
	};
}

function event(this r: Reader): Result<WorkspaceEvent, ProtocolError> {
	const kind = try code(EVENT_KINDS, try r.u8(), ProtocolError.UnknownEvent);
	return match (kind) {
		EventKind.PaneClosed => {
			const id = try r.pane();
			Result.ok({ kind: EventKind.PaneClosed, pane: id })
		},
		EventKind.TabsChanged => {
			const n = try r.count();
			const tabs: TabEntry[] = [];
			for (let i: int32 = 0; i < n; i++) {
				const id = try r.tab();
				const title = try r.optionalText();
				tabs.push({ id: id, title: title });
			}
			const active = try r.optionalTab();
			Result.ok({ kind: EventKind.TabsChanged, tabs: tabs, active: active })
		},
		EventKind.PaneOpened => {
			const id = try r.pane();
			const owner = try r.tab();
			const origin = try r.optionalPane();
			const placed = try r.rect();
			Result.ok({
				kind: EventKind.PaneOpened,
				pane: id,
				tab: owner,
				origin: origin,
				rect: placed,
			})
		},
		EventKind.PaneResized => {
			const id = try r.pane();
			const placed = try r.rect();
			Result.ok({ kind: EventKind.PaneResized, pane: id, rect: placed })
		},
		EventKind.ZoomChanged => {
			const owner = try r.tab();
			const id = try r.optionalPane();
			Result.ok({ kind: EventKind.ZoomChanged, tab: owner, pane: id })
		},
		EventKind.FocusChanged => {
			const id = try r.pane();
			Result.ok({ kind: EventKind.FocusChanged, pane: id })
		},
		EventKind.WorkspaceEmpty => Result.ok({ kind: EventKind.WorkspaceEmpty }),
	};
}

function layout(this r: Reader): Result<Message, ProtocolError> {
	const tabCount = try r.count();
	const tabs: Tab[] = [];
	for (let i: int32 = 0; i < tabCount; i++) {
		const id = try r.tab();
		const title = try r.optionalText();
		const root = try r.node(1);
		const focused = try r.pane();
		const zoomed = try r.optionalPane();
		tabs.push({
			id: id,
			title: title,
			root: root,
			focused: focused,
			zoomed: zoomed,
		});
	}
	const active = try r.optionalTab();
	return Result.ok({ kind: MessageKind.Layout, tabs: tabs, active: active });
}

function screen(this r: Reader): Result<Message, ProtocolError> {
	const id = try r.pane();
	const cols = try r.i32();
	const rows = try r.i32();
	const format = try code(
		SCREEN_FORMATS,
		try r.u8(),
		ProtocolError.UnknownScreenFormat,
	);
	const bytes = try r.blob();
	return Result.ok({
		kind: MessageKind.Screen,
		pane: id,
		cols: cols,
		rows: rows,
		format: format,
		bytes: bytes,
	});
}

function message(
	this r: Reader,
	kind: MessageKind,
): Result<Message, ProtocolError> {
	return match (kind) {
		MessageKind.Hello => {
			const version = try r.u32();
			const role = try code(ROLES, try r.u8(), ProtocolError.UnknownRole);
			const cols = try r.i32();
			const rows = try r.i32();
			const vtBuild = try r.text();
			Result.ok({
				kind: MessageKind.Hello,
				version: version,
				role: role,
				cols: cols,
				rows: rows,
				vtBuild: vtBuild,
			})
		},
		MessageKind.Welcome => {
			const version = try r.u32();
			const pid = try r.i32();
			const vtBuild = try r.text();
			Result.ok({
				kind: MessageKind.Welcome,
				version: version,
				serverPid: pid,
				vtBuild: vtBuild,
			})
		},
		MessageKind.Attach => Result.ok({ kind: MessageKind.Attach }),
		MessageKind.Layout => r.layout(),
		MessageKind.Screen => r.screen(),
		MessageKind.Command => {
			const c = try r.command();
			Result.ok({ kind: MessageKind.Command, command: c })
		},
		MessageKind.Event => {
			const e = try r.event();
			Result.ok({ kind: MessageKind.Event, event: e })
		},
		MessageKind.Input => {
			const id = try r.pane();
			const bytes = try r.blob();
			Result.ok({ kind: MessageKind.Input, pane: id, bytes: bytes })
		},
		MessageKind.Output => {
			const id = try r.pane();
			const seq = try r.u64();
			const bytes = try r.blob();
			Result.ok({ kind: MessageKind.Output, pane: id, seq: seq, bytes: bytes })
		},
		MessageKind.Fit => {
			const cols = try r.i32();
			const rows = try r.i32();
			Result.ok({ kind: MessageKind.Fit, cols: cols, rows: rows })
		},
		MessageKind.Exited => {
			const id = try r.pane();
			const exitCode = try r.i32();
			Result.ok({ kind: MessageKind.Exited, pane: id, code: exitCode })
		},
		MessageKind.Failed => {
			const id = try r.pane();
			const reason = try r.text();
			Result.ok({ kind: MessageKind.Failed, pane: id, reason: reason })
		},
		MessageKind.Refused => {
			const reason = try r.text();
			Result.ok({ kind: MessageKind.Refused, reason: reason })
		},
		MessageKind.Bye => Result.ok({ kind: MessageKind.Bye }),
	};
}

export interface Decoder {
	pending: uint8[];
	failed: ProtocolError | null;
}

export function create(this typeof Decoder): Decoder {
	return { pending: [], failed: null };
}

function frame(
	this d: Decoder,
	at: int32,
	out: Message[],
): Result<int32, ProtocolError> {
	if (d.pending.length - at < HEADER_BYTES) { return Result.ok(at); }
	const size = bigEndian(d.pending, at);
	if ((size as int64) > (MAX_PAYLOAD_BYTES as int64)) {
		return Result.err(ProtocolError.PayloadTooLarge);
	}
	const kind = try code(
		MESSAGE_KINDS,
		d.pending[at + 4],
		ProtocolError.UnknownMessageType,
	);
	const start = at + HEADER_BYTES;
	const end = start + (size as int32);
	if (d.pending.length < end) { return Result.ok(at); }
	const r: Reader = { bytes: d.pending, at: start, end: end };
	out.push(try r.message(kind));
	if (r.at != end) { return Result.err(ProtocolError.TrailingBytes); }
	return Result.ok(end);
}

function drain(
	this d: Decoder,
	out: Message[],
): Result<int32, ProtocolError> {
	let at: int32 = 0;
	while (true) {
		const next = try d.frame(at, out);
		if (next == at) { return Result.ok(at); }
		at = next;
	}
}

export function push(
	this d: Decoder,
	chunk: Readonly<Span<uint8>>,
): Result<Message[], ProtocolError> {
	const failed = d.failed;
	if (failed !== null) { return Result.err(failed); }
	for (const b of chunk) { d.pending.push(b); }
	const out: Message[] = [];
	const drained = d.drain(out);
	if (!drained.ok) {
		d.failed = drained.error;
		return Result.err(drained.error);
	}
	if (drained.value > 0) {
		d.pending = d.pending.slice(drained.value, d.pending.length);
	}
	return Result.ok(out);
}
