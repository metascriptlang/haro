import { CloseReason, Connection, connectToUnix } from "./transport";
import { MessageKind, encode } from "./protocol";

when (!windows) {
	@include("./pump.h");
	@compile("./pump.c");
	@passL("-lpthread");
	@include("unistd.h");
	@include("errno.h");

	extern function haroPumpToSocket(from: int32): int32;
	extern function write(fd: int32, buf: Ptr<uint8>, count: uint64): int64;
	extern const EINTR: int32 from "EINTR";
	extern const errno: int32 from "errno";
}

const STDIN: int32 = 0;
const STDOUT: int32 = 1;
const BRIDGE_POLL_MS: int32 = 20;
const CONNECT_MS: int32 = 1000;

function writeAll(fd: int32, chunk: uint8[]): boolean {
	let bytes: Vec<uint8> = [...chunk];
	let at: int32 = 0;
	while (at < bytes.length) {
		const rest = bytes.slice(at, bytes.length);
		const put = write(fd, rest as Span<uint8> as Ptr<uint8>, rest.length as uint64);
		if (put < 0) {
			if (errno != EINTR) { return false; }
		} else {
			at += put as int32;
		}
	}
	return true;
}

class Ended { value: boolean = false; }

export function pumped(from: int32): Connection | null {
	const fd = haroPumpToSocket(from);
	return fd < 0 ? null : new Connection(fd);
}

export async function bridge(conn: Connection, from: int32, to: int32): Promise<Result<void, string>> {
	const said = encode({ kind: MessageKind.Proxied });
	if (!said.ok || !conn.send(said.value)) {
		conn.close();
		return Result.err("the proxy could not tell the server it carries a remote client");
	}
	const input = pumped(from);
	if (input === null) {
		conn.close();
		return Result.err("the input pump did not start");
	}
	const ended = new Ended();
	conn.start((chunk: uint8[]): void => {
		if (!writeAll(to, chunk)) { conn.close(); }
	}, (why: CloseReason): void => {
		ended.value = true;
		input.close();
	});
	input.start((chunk: uint8[]): void => {
		const _sent = conn.send(chunk);
	}, (why: CloseReason): void => { conn.finish(); });
	while (!ended.value) { await sleepAsync(BRIDGE_POLL_MS); }
	return Result.ok(null);
}

export async function proxy(socket: string, startServer: () => Promise<boolean>): Promise<Result<void, string>> {
	let dialed = await connectToUnix(socket, CONNECT_MS);
	if (!dialed.ok) {
		if (!(await startServer())) { return Result.err(`no Haro server answered at ${socket} and none could be started`); }
		dialed = await connectToUnix(socket, CONNECT_MS);
		if (!dialed.ok) { return Result.err(`the Haro server started but does not answer at ${socket}`); }
	}
	return await bridge(dialed.value, STDIN, STDOUT);
}
