import {
	Axis,
	CellRect,
	Node,
	NodeKind,
	PaneId,
	TabId,
} from "../workspace/tree";
import {
	CommandKind,
	Direction,
	EventKind,
	TabEntry,
	WorkspaceCommand,
	WorkspaceEvent,
} from "../workspace/workspace";
import {
	AXES,
	COMMAND_KINDS,
	DIRECTIONS,
	Decoder,
	EVENT_KINDS,
	HEADER_BYTES,
	MAX_PAYLOAD_BYTES,
	MAX_SCREEN_BYTES,
	MAX_TREE_DEPTH,
	MESSAGE_KINDS,
	Message,
	MessageKind,
	NODE_KINDS,
	PROTOCOL_VERSION,
	ProtocolError,
	ROLES,
	Role,
	SCREEN_FORMATS,
	ScreenFormat,
	create,
	encode,
	greet,
	push,
	screenFormat,
} from "./protocol";

// msc card 2026-11-04-literal-into-nullable-variant-field-dies-at-clang:
// a non-null value in a variant's nullable field fails in the C compiler.
const TITLE: string | null = "logs \u{e9}\u{1f680}";
const NO_TITLE: string | null = null;
const SECOND_TAB: TabId | null = 2 as TabId;
const FOURTH_TAB: TabId | null = 4 as TabId;
const FIRST_PANE: PaneId | null = 1 as PaneId;
const THIRD_PANE: PaneId | null = 3 as PaneId;

function pane(n: int32): PaneId {
	return n as PaneId;
}

function tab(n: int32): TabId {
	return n as TabId;
}

function rect(x: int32, y: int32, cols: int32, rows: int32): CellRect {
	return { x: x, y: y, cols: cols, rows: rows };
}

function bytesOf(m: Message): uint8[] {
	const encoded = encode(m);
	if (!encoded.ok) { throw new Error(`encode refused: ${encoded.error}`); }
	return encoded.value;
}

function same(a: uint8[], b: uint8[]): boolean {
	if (a.length != b.length) { return false; }
	for (let i: int32 = 0; i < a.length; i++) {
		if (a[i] != b[i]) { return false; }
	}
	return true;
}

function decodeAll(stream: uint8[], step: int32): Message[] {
	const d = Decoder.create();
	const out: Message[] = [];
	for (let at: int32 = 0; at < stream.length; at += step) {
		const end = Math.min(at + step, stream.length);
		const got = d.push(stream.slice(at, end));
		if (!got.ok) { throw new Error(`decode refused: ${got.error}`); }
		for (const m of got.value) { out.push(m); }
	}
	if (d.pending.length != 0) { throw new Error("bytes left undecoded"); }
	return out;
}

function roundTrips(m: Message): Message {
	const bytes = bytesOf(m);
	const back = decodeAll(bytes, bytes.length);
	if (back.length != 1 || back[0].kind != m.kind) {
		throw new Error(`${m.kind} did not decode to one ${m.kind}`);
	}
	if (!same(bytesOf(back[0]), bytes)) {
		throw new Error(`${m.kind} changed on its round trip`);
	}
	return back[0];
}

function refusal(stream: uint8[]): ProtocolError | null {
	const got = Decoder.create().push(stream);
	return got.ok ? null : got.error;
}

function frame(kind: uint8, payload: uint8[]): uint8[] {
	const n = payload.length as uint32;
	const out: uint8[] = [
		((n >> 24) & 0xff) as uint8,
		((n >> 16) & 0xff) as uint8,
		((n >> 8) & 0xff) as uint8,
		(n & 0xff) as uint8,
		kind,
	];
	for (const b of payload) { out.push(b); }
	return out;
}

function tree(): Node {
	return {
		kind: NodeKind.Split,
		split: {
			axis: Axis.SideBySide,
			ratio: 0.3125,
			first: {
				kind: NodeKind.Pane,
				pane: {
					id: pane(1),
					origin: null,
					focusedAt: -9007199254740993,
					rect: rect(0, 0, 25, 24),
				},
			},
			second: {
				kind: NodeKind.Split,
				split: {
					axis: Axis.Stacked,
					ratio: 1,
					first: {
						kind: NodeKind.Pane,
						pane: {
							id: pane(2),
							origin: pane(1),
							focusedAt: 7,
							rect: rect(26, 0, 55, 12),
						},
					},
					second: {
						kind: NodeKind.Pane,
						pane: {
							id: pane(-3),
							origin: pane(2),
							focusedAt: 9223372036854775807,
							rect: rect(26, 13, 55, 11),
						},
					},
				},
			},
		},
	};
}

function layout(): Message {
	return {
		kind: MessageKind.Layout,
		tabs: [
			{
				id: tab(1),
				title: TITLE,
				root: tree(),
				focused: pane(2),
				zoomed: pane(2),
			},
			{
				id: tab(4),
				title: NO_TITLE,
				root: {
					kind: NodeKind.Pane,
					pane: {
						id: pane(9),
						origin: null,
						focusedAt: 0,
						rect: rect(0, 0, 0, 0),
					},
				},
				focused: pane(9),
				zoomed: null,
			},
		],
		active: FOURTH_TAB,
	};
}

function screens(): Message[] {
	return [
		{
			kind: MessageKind.Screen,
			pane: pane(1),
			cols: 25,
			rows: 24,
			format: ScreenFormat.VtBytes,
			bytes: [27, 91, 72, 0, 255],
		},
		{
			kind: MessageKind.Screen,
			pane: pane(9),
			cols: 80,
			rows: 24,
			format: ScreenFormat.Native,
			bytes: [],
		},
	];
}

function commands(): WorkspaceCommand[] {
	return [
		{ kind: CommandKind.NewTab },
		{ kind: CommandKind.CloseTab, tab: tab(3) },
		{ kind: CommandKind.GotoTab, index: -1 },
		{ kind: CommandKind.CycleTab, by: -2147483648 },
		{ kind: CommandKind.MoveTab, by: 2147483647 },
		{ kind: CommandKind.RenameTab, tab: tab(2), title: TITLE },
		{ kind: CommandKind.RenameTab, tab: tab(2), title: NO_TITLE },
		{ kind: CommandKind.Split, pane: pane(5), axis: Axis.Stacked },
		{ kind: CommandKind.ClosePane, pane: pane(6) },
		{ kind: CommandKind.FocusPane, pane: pane(7) },
		{ kind: CommandKind.FocusDirection, direction: Direction.Down },
		{ kind: CommandKind.CyclePane, by: -1 },
		{ kind: CommandKind.Resize, direction: Direction.Left, cells: 3 },
		{
			kind: CommandKind.MoveDivider,
			pane: pane(8),
			axis: Axis.SideBySide,
			by: -4,
		},
		{ kind: CommandKind.ToggleZoom },
		{ kind: CommandKind.Fit },
	];
}

function events(): WorkspaceEvent[] {
	const entries: TabEntry[] = [
		{ id: tab(1), title: TITLE },
		{ id: tab(2), title: NO_TITLE },
	];
	return [
		{ kind: EventKind.PaneClosed, pane: pane(1) },
		{ kind: EventKind.TabsChanged, tabs: entries, active: SECOND_TAB },
		{ kind: EventKind.TabsChanged, tabs: [], active: null },
		{
			kind: EventKind.PaneOpened,
			pane: pane(3),
			tab: tab(1),
			origin: FIRST_PANE,
			rect: rect(41, 0, 40, 24),
		},
		{
			kind: EventKind.PaneOpened,
			pane: pane(4),
			tab: tab(2),
			origin: null,
			rect: rect(0, 0, 81, 25),
		},
		{ kind: EventKind.PaneResized, pane: pane(3), rect: rect(1, 2, 3, 4) },
		{ kind: EventKind.ZoomChanged, tab: tab(1), pane: THIRD_PANE },
		{ kind: EventKind.ZoomChanged, tab: tab(1), pane: null },
		{ kind: EventKind.FocusChanged, pane: pane(3) },
		{ kind: EventKind.WorkspaceEmpty },
	];
}

function messages(): Message[] {
	return [
		{
			kind: MessageKind.Hello,
			version: PROTOCOL_VERSION,
			role: Role.Cli,
			cols: 81,
			rows: 25,
			vtBuild: "vt 1.2.3+abc \u{e9}",
		},
		{
			kind: MessageKind.Welcome,
			version: PROTOCOL_VERSION,
			serverPid: 4242,
			vtBuild: "",
		},
		{ kind: MessageKind.Attach },
		layout(),
		screens()[0],
		{ kind: MessageKind.Command, command: commands()[5] },
		{ kind: MessageKind.Event, event: events()[3] },
		{ kind: MessageKind.Input, pane: pane(2), bytes: [3, 0, 255, 10] },
		{
			kind: MessageKind.Output,
			pane: pane(2),
			seq: 18446744073709551615,
			bytes: [27, 93, 48, 59, 7],
		},
		{ kind: MessageKind.Fit, cols: 132, rows: 43 },
		{ kind: MessageKind.Exited, pane: pane(2), code: -9 },
		{ kind: MessageKind.Failed, pane: pane(2), reason: "pty \u{e9} gone" },
		{ kind: MessageKind.AskBusy, pane: pane(3) },
		{ kind: MessageKind.Busy, pane: pane(3), busy: true },
		{ kind: MessageKind.Refused, reason: "nope \u{1f680}" },
		{ kind: MessageKind.Bye },
	];
}

function stream(): uint8[] {
	const out: uint8[] = [];
	for (const m of messages()) {
		for (const b of bytesOf(m)) { out.push(b); }
	}
	return out;
}

test "each decode table lists its enum in ordinal order" {
	for (let i: int32 = 0; i < MESSAGE_KINDS.length; i++) {
		assert MESSAGE_KINDS[i] as int32 == i;
	}
	assert MESSAGE_KINDS.length == (MessageKind.Bye as int32) + 1;
	for (let i: int32 = 0; i < COMMAND_KINDS.length; i++) {
		assert COMMAND_KINDS[i] as int32 == i;
	}
	assert COMMAND_KINDS.length == (CommandKind.Fit as int32) + 1;
	for (let i: int32 = 0; i < EVENT_KINDS.length; i++) {
		assert EVENT_KINDS[i] as int32 == i;
	}
	assert EVENT_KINDS.length == (EventKind.WorkspaceEmpty as int32) + 1;
	for (let i: int32 = 0; i < DIRECTIONS.length; i++) {
		assert DIRECTIONS[i] as int32 == i;
	}
	assert DIRECTIONS.length == (Direction.Down as int32) + 1;
	assert ROLES.length == (Role.Cli as int32) + 1;
	assert SCREEN_FORMATS.length == (ScreenFormat.Native as int32) + 1;
	assert SCREEN_FORMATS[1] == ScreenFormat.Native;
	assert ROLES[1] == Role.Cli;
	assert AXES.length == (Axis.Stacked as int32) + 1;
	assert AXES[1] == Axis.Stacked;
	assert NODE_KINDS.length == (NodeKind.Split as int32) + 1;
	assert NODE_KINDS[1] == NodeKind.Split;
}

test "every message kind round trips" {
	const all = messages();
	assert all.length == MESSAGE_KINDS.length;
	for (let i: int32 = 0; i < all.length; i++) {
		assert all[i].kind == MESSAGE_KINDS[i];
		roundTrips(all[i]);
	}
}

test "every workspace command round trips" {
	const all = commands();
	for (const kind of COMMAND_KINDS) {
		let seen = false;
		for (const c of all) { seen = seen || c.kind == kind; }
		assert seen;
	}
	for (const c of all) {
		const back = roundTrips({ kind: MessageKind.Command, command: c });
		if (back.kind == MessageKind.Command) {
			assert back.command.kind == c.kind;
		}
	}
}

test "every workspace event round trips" {
	const all = events();
	for (const kind of EVENT_KINDS) {
		let seen = false;
		for (const e of all) { seen = seen || e.kind == kind; }
		assert seen;
	}
	for (const e of all) {
		const back = roundTrips({ kind: MessageKind.Event, event: e });
		if (back.kind == MessageKind.Event) { assert back.event.kind == e.kind; }
	}
}

test "a layout keeps its tree, titles and extremes" {
	const back = roundTrips(layout());
	assert back.kind == MessageKind.Layout;
	if (back.kind != MessageKind.Layout) { return; }
	assert back.tabs.length == 2;
	assert back.tabs[0].title == TITLE;
	assert back.tabs[1].title === null;
	const root = back.tabs[0].root;
	assert root.kind == NodeKind.Split;
	if (root.kind == NodeKind.Split) {
		assert root.split.ratio == 0.3125;
		const first = root.split.first;
		assert first.kind == NodeKind.Pane;
		if (first.kind == NodeKind.Pane) {
			assert first.pane.focusedAt == -9007199254740993;
		}
		const inner = root.split.second;
		if (inner.kind == NodeKind.Split) {
			const last = inner.split.second;
			if (last.kind == NodeKind.Pane) {
				assert last.pane.id as int32 == -3;
				assert last.pane.focusedAt == 9223372036854775807;
				assert last.pane.rect == rect(26, 13, 55, 11);
			}
		}
	}
	assert back.active == FOURTH_TAB;
}

test "a screen keeps its pane, size, format and bytes, empty bytes included" {
	const shots = screens();
	const vt = roundTrips(shots[0]);
	assert vt.kind == MessageKind.Screen;
	if (vt.kind == MessageKind.Screen) {
		assert vt.pane == pane(1) && vt.cols == 25 && vt.rows == 24;
		assert vt.format == ScreenFormat.VtBytes;
		assert vt.bytes.length == 5 && vt.bytes[4] == 255;
	}
	const native = roundTrips(shots[1]);
	assert native.kind == MessageKind.Screen;
	if (native.kind == MessageKind.Screen) {
		assert native.format == ScreenFormat.Native;
		assert native.bytes.length == 0;
	}
}

function screenOf(size: int32): Message {
	const bytes: uint8[] = new Array(size);
	return {
		kind: MessageKind.Screen,
		pane: pane(1),
		cols: 1,
		rows: 1,
		format: ScreenFormat.Native,
		bytes: bytes,
	};
}

test "a screen of MAX_SCREEN_BYTES fills the largest frame and one byte more is refused" {
	const fits = encode(screenOf(MAX_SCREEN_BYTES));
	assert fits.ok;
	if (fits.ok) { assert fits.value.length == HEADER_BYTES + MAX_PAYLOAD_BYTES; }
	const over = encode(screenOf(MAX_SCREEN_BYTES + 1));
	assert !over.ok && over.error == ProtocolError.PayloadTooLarge;
}

test "a stream cut anywhere decodes to the same messages" {
	const whole = stream();
	const expected = messages();
	for (const step of [1, 2, 3, 5, 7, 64, whole.length]) {
		const back = decodeAll(whole, step);
		assert back.length == expected.length;
		for (let i: int32 = 0; i < back.length; i++) {
			assert same(bytesOf(back[i]), bytesOf(expected[i]));
		}
	}
}

test "a partial frame yields nothing until its last byte arrives" {
	const bytes = bytesOf({ kind: MessageKind.Fit, cols: 1, rows: 2 });
	const d = Decoder.create();
	const head = d.push(bytes.slice(0, bytes.length - 1));
	assert head.ok && head.value.length == 0;
	const tail = d.push(bytes.slice(bytes.length - 1, bytes.length));
	assert tail.ok && tail.value.length == 1;
}

test "a length over the maximum is refused from its header alone" {
	const n = (MAX_PAYLOAD_BYTES as uint32) + 1;
	const header: uint8[] = [
		((n >> 24) & 0xff) as uint8,
		((n >> 16) & 0xff) as uint8,
		((n >> 8) & 0xff) as uint8,
		(n & 0xff) as uint8,
		MessageKind.Bye as uint8,
	];
	const d = Decoder.create();
	const got = d.push(header);
	assert !got.ok && got.error == ProtocolError.PayloadTooLarge;
	const again = d.push(bytesOf({ kind: MessageKind.Bye }));
	assert !again.ok && again.error == ProtocolError.PayloadTooLarge;
}

test "an unknown message type is refused, not skipped" {
	const unknown = MESSAGE_KINDS.length as uint8;
	const stream = frame(unknown, []);
	for (const b of bytesOf({ kind: MessageKind.Bye })) { stream.push(b); }
	assert refusal(stream) == ProtocolError.UnknownMessageType;
}

test "a malformed payload is refused with the case it breaks" {
	const fit = MessageKind.Fit as uint8;
	assert refusal(frame(fit, [0, 0, 0, 1])) == ProtocolError.PayloadTruncated;
	assert refusal(frame(fit, [0, 0, 0, 1, 0, 0, 0, 2, 9])) ==
		ProtocolError.TrailingBytes;
	const hello = MessageKind.Hello as uint8;
	assert refusal(frame(hello, [0, 0, 0, 1, 2, 0, 0, 0, 1, 0, 0, 0, 1])) ==
		ProtocolError.UnknownRole;
	const screen = MessageKind.Screen as uint8;
	const badFormat: uint8[] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 2];
	assert refusal(frame(screen, badFormat)) ==
		ProtocolError.UnknownScreenFormat;
	const command = MessageKind.Command as uint8;
	const unknownCommand = COMMAND_KINDS.length as uint8;
	assert refusal(frame(command, [unknownCommand])) ==
		ProtocolError.UnknownCommand;
	assert refusal(frame(command, [CommandKind.FocusDirection as uint8, 4])) ==
		ProtocolError.UnknownDirection;
	assert refusal(frame(command, [CommandKind.Split as uint8, 0, 0, 0, 1, 2])) ==
		ProtocolError.UnknownAxis;
	const rename = CommandKind.RenameTab as uint8;
	assert refusal(frame(command, [rename, 0, 0, 0, 1, 2])) ==
		ProtocolError.BadPresenceTag;
	const event = MessageKind.Event as uint8;
	assert refusal(frame(event, [EVENT_KINDS.length as uint8])) ==
		ProtocolError.UnknownEvent;
	const refused = MessageKind.Refused as uint8;
	assert refusal(frame(refused, [0, 0, 0, 2, 0xc3, 0x28])) ==
		ProtocolError.MalformedText;
	const busy = MessageKind.Busy as uint8;
	assert refusal(frame(busy, [0, 0, 0, 1, 2])) == ProtocolError.BadPresenceTag;
	const input = MessageKind.Input as uint8;
	assert refusal(frame(input, [0, 0, 0, 1, 0xff, 0xff, 0xff, 0xff])) ==
		ProtocolError.PayloadTruncated;
}

test "a tree with a bad node, ratio or depth is refused" {
	const kind = MessageKind.Layout as uint8;
	const head: uint8[] = [0, 0, 0, 1, 0, 0, 0, 1, 0];
	const badKind: uint8[] = [...head, 2];
	assert refusal(frame(kind, badKind)) == ProtocolError.UnknownNodeKind;
	const nan: uint8[] = [...head, 1, 0, 0x7f, 0xf8, 0, 0, 0, 0, 0, 0];
	assert refusal(frame(kind, nan)) == ProtocolError.RatioOutOfRange;
	const above: uint8[] = [...head, 1, 0, 0x3f, 0xf0, 0, 0, 0, 0, 0, 1];
	assert refusal(frame(kind, above)) == ProtocolError.RatioOutOfRange;
	const half: uint8[] = [1, 0, 0x3f, 0xe0, 0, 0, 0, 0, 0, 0];
	const deep: uint8[] = [...head];
	for (let i: int32 = 0; i < MAX_TREE_DEPTH + 1; i++) {
		for (const b of half) { deep.push(b); }
	}
	assert refusal(frame(kind, deep)) == ProtocolError.TreeTooDeep;
}

function leafOf(id: int32): Node {
	return {
		kind: NodeKind.Pane,
		pane: { id: pane(id), origin: null, focusedAt: 0, rect: rect(0, 0, 1, 1) },
	};
}

function deepTree(depth: int32): Node {
	let n = leafOf(0);
	for (let i: int32 = 1; i < depth; i++) {
		n = {
			kind: NodeKind.Split,
			split: { axis: Axis.Stacked, ratio: 0.5, first: n, second: leafOf(i) },
		};
	}
	return n;
}

function layoutOf(root: Node): Message {
	return {
		kind: MessageKind.Layout,
		tabs: [
			{
				id: tab(1),
				title: NO_TITLE,
				root: root,
				focused: pane(0),
				zoomed: null,
			},
		],
		active: null,
	};
}

test "a tree at the depth limit encodes and one level deeper is refused" {
	roundTrips(layoutOf(deepTree(MAX_TREE_DEPTH)));
	const deeper = encode(layoutOf(deepTree(MAX_TREE_DEPTH + 1)));
	assert !deeper.ok && deeper.error == ProtocolError.TreeTooDeep;
}

test "a hello of another version is refused and this version welcomed" {
	const other = greet(PROTOCOL_VERSION + 1, 77, "b1");
	assert other.kind == MessageKind.Refused;
	if (other.kind == MessageKind.Refused) {
		assert other.reason.includes(`${PROTOCOL_VERSION + 1}`);
	}
	const same = greet(PROTOCOL_VERSION, 77, "b1");
	assert same.kind == MessageKind.Welcome;
	if (same.kind == MessageKind.Welcome) {
		assert same.version == PROTOCOL_VERSION;
		assert same.serverPid == 77;
		assert same.vtBuild == "b1";
	}
}

test "a native screen is chosen only for the same named vt build" {
	assert screenFormat("b1", "b1") == ScreenFormat.Native;
	assert screenFormat("b1", "b2") == ScreenFormat.VtBytes;
	assert screenFormat("", "") == ScreenFormat.VtBytes;
}
