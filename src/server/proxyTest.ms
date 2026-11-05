import { removeAll } from "std/fs";
import { join } from "std/fs/path";
import { tmpDir } from "std/os";
import { vtBuild } from "../vt/vt";
import { PaneId } from "../workspace/tree";
import {
	Decoder,
	MAX_SCREEN_BYTES,
	Message,
	MessageKind,
	PROTOCOL_VERSION,
	Role,
	create,
	encode,
	push,
} from "./protocol";
import { bridge, pumped } from "./proxy";
import { Server, start, stop } from "./serve";
import { CloseReason, connectToUnix } from "./transport";

when (!windows) {
	@include("unistd.h");

	extern function pipe(fds: Ptr<int32>): int32;
	extern function write(fd: int32, buf: Ptr<uint8>, count: uint64): int64;
	extern function close(fd: int32): int32;

	const FIRST: PaneId = 1 as PaneId;

	function piped(): Vec<int32> {
		let fds: Vec<int32> = new Array(2);
		if (pipe(fds as Span<int32> as Ptr<int32>) != 0) { throw new Error("no pipe"); }
		return fds;
	}

	function sent(fd: int32, m: Message): void {
		const bytes = encode(m);
		if (!bytes.ok) { throw new Error("encode refused"); }
		let all: Vec<uint8> = [...bytes.value];
		if (write(fd, all as Span<uint8> as Ptr<uint8>, all.length as uint64) != all.length as int64) {
			throw new Error("short write");
		}
	}

	test "a proxy passes the stream both ways, and its stdin's end closes only its own client" {
		const socket = join(join(tmpDir(), `haro-proxy-${Date.now()}`), "s.sock");
		const started = await Server.start({
			launch: { command: "sh", shellScripts: null, startIn: null, originCwd: false },
			socket: socket,
			dividerCells: 1,
			tailnet: null,
			screenLimit: MAX_SCREEN_BYTES,
			log: (line: string): void => {},
		});
		assert started.ok;
		if (!started.ok) { return; }
		const s = started.value;
		let code: int32 = -1;
		s.finished.then((c: int32): void => { code = c; });
		const input = piped();
		const output = piped();
		const dialed = await connectToUnix(socket, 2000);
		assert dialed.ok;
		if (!dialed.ok) { return; }
		const bridged = bridge(dialed.value, input[0], output[1]);
		sent(input[1], {
			kind: MessageKind.Hello,
			version: PROTOCOL_VERSION,
			role: Role.Window,
			cols: 80,
			rows: 24,
			vtBuild: vtBuild(),
		});
		sent(input[1], { kind: MessageKind.Attach });
		const d = Decoder.create();
		const got: Message[] = [];
		const reader = pumped(output[0]);
		assert reader !== null;
		if (reader === null) { return; }
		reader.start((chunk: uint8[]): void => {
			const decoded = d.push(chunk);
			if (decoded.ok) { for (const m of decoded.value) { got.push(m); } }
		}, (why: CloseReason): void => {});
		const deadline = Date.now() + 10000;
		while (!got.some((m: Message): boolean => m.kind == MessageKind.Screen && m.pane == FIRST) && Date.now() < deadline) {
			await sleepAsync(5);
		}
		assert got.length > 0 && got[0].kind == MessageKind.Welcome;
		assert got.some((m: Message): boolean => m.kind == MessageKind.Screen && m.pane == FIRST);
		assert s.clients.length == 1;
		const _closed = close(input[1]);
		const done = await bridged;
		assert done.ok;
		const until = Date.now() + 5000;
		while (s.clients.length > 0 && Date.now() < until) { await sleepAsync(5); }
		assert s.clients.length == 0;
		assert code < 0;
		assert s.host !== null;
		s.stop(0);
		while (code < 0) { await sleepAsync(5); }
		reader.close();
		const _a = close(input[0]);
		const _c = close(output[1]);
		const _removed = removeAll(socket.slice(0, socket.lastIndexOf("/")));
	}
}
