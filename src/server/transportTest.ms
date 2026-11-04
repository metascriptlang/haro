import {
	close as closeFd,
	bindUnix,
	connectUnix,
	createUnixSocket,
} from "std/net";
import { exists, removeAll } from "std/fs";
import { join } from "std/fs/path";
import { tmpDir } from "std/os";
import {
	CloseReason,
	ConnectError,
	Connection,
	ListenError,
	ListenHandlers,
	Listener,
	MAX_QUEUED_BYTES,
	connectToTcp,
	connectToUnix,
	listenTcp,
	listenUnix,
	socketPath,
} from "./transport";

const MIB: int32 = 1024 * 1024;

class Accepted { c: Connection | null = null; }

class Sink {
	count: int64 = 0;
	text: string = "";
	patterned: boolean = true;
	closed: CloseReason | null = null;
}

function patternAt(i: int64): uint8 { return ((i * 31) % 251) as uint8; }

function patterned(from: int64, length: int32): uint8[] {
	let bytes: uint8[] = [];
	for (let i: int32 = 0; i < length; i++) {
		bytes.push(patternAt(from + (i as int64)));
	}
	return bytes;
}

function collect(c: Connection, sink: Sink, keepText: boolean): void {
	c.start((chunk: uint8[]): void => {
		for (const b of chunk) {
			if (b != patternAt(sink.count)) { sink.patterned = false; }
			sink.count += 1;
		}
		if (keepText) { sink.text += chunk.asString(); }
	}, (reason: CloseReason): void => { sink.closed = reason; });
}

function echoing(): ListenHandlers {
	return {
		accepted: (c: Connection): void => {
			c.start((chunk: uint8[]): void => { const _sent = c.send(chunk); },
				(reason: CloseReason): void => {});
		},
		failed: (): void => {},
	};
}

async function until(done: () => boolean): Promise<boolean> {
	const deadline = Date.now() + 10000;
	while (!done()) {
		if (Date.now() > deadline) { return false; }
		await sleepAsync(1);
	}
	return true;
}

let dirs: int32 = 0;

function freshPath(): string {
	dirs += 1;
	const dir = join(tmpDir(), `haro-transport-${Date.now()}-${dirs}`);
	return join(dir, "s.sock");
}

function cleanUp(path: string): void {
	const _removed = removeAll(path.slice(0, path.lastIndexOf("/")));
}

async function dialed(path: string): Promise<Connection> {
	const got = await connectToUnix(path, 2000);
	if (!got.ok) { throw new Error(`no connection to ${path}`); }
	return got.value;
}

test "the socket path is the user's own runtime directory" {
	const path = socketPath();
	assert path.endsWith("/haro.sock");
	const dir = path.slice(0, path.lastIndexOf("/"));
	const leaf = dir.slice(dir.lastIndexOf("/") + 1);
	assert leaf == "haro" || leaf.startsWith("haro-");
}

test "a unix client's bytes echo back through the listener" {
	const path = freshPath();
	const listener = listenUnix(path, echoing());
	assert listener.ok;
	const client = await dialed(path);
	const sink = new Sink();
	collect(client, sink, true);
	assert client.send("hello".asBytes().slice(0));
	assert await until((): boolean => sink.text == "hello");
	client.close();
	assert sink.closed == CloseReason.Closed;
	listener.value.close();
	assert !exists(path);
	cleanUp(path);
}

test "two clients each get their own echo" {
	const path = freshPath();
	const listener = listenUnix(path, echoing());
	assert listener.ok;
	const first = await dialed(path);
	const second = await dialed(path);
	const one = new Sink();
	const two = new Sink();
	collect(first, one, true);
	collect(second, two, true);
	assert first.send("first".asBytes().slice(0));
	assert second.send("second".asBytes().slice(0));
	assert await until((): boolean => one.text == "first" && two.text == "second");
	first.close();
	second.close();
	listener.value.close();
	cleanUp(path);
}

test "8 MiB crosses both ways intact across uneven chunk boundaries" {
	const path = freshPath();
	const server = new Sink();
	const handlers: ListenHandlers = {
		accepted: (c: Connection): void => {
			c.start((chunk: uint8[]): void => {
				for (const b of chunk) {
					if (b != patternAt(server.count)) { server.patterned = false; }
					server.count += 1;
				}
				const _sent = c.send(chunk);
			}, (reason: CloseReason): void => { server.closed = reason; });
		},
		failed: (): void => {},
	};
	const listener = listenUnix(path, handlers);
	assert listener.ok;
	const client = await dialed(path);
	const sink = new Sink();
	collect(client, sink, false);
	const total: int64 = (8 * MIB) as int64;
	const sizes: int32[] = [1, 7, 4096, 65537, MIB + 3, 333];
	let sent: int64 = 0;
	let next: int32 = 0;
	while (sent < total) {
		const want = sizes[next % sizes.length] as int64;
		const size = (want < total - sent ? want : total - sent) as int32;
		assert client.send(patterned(sent, size));
		sent += size as int64;
		next += 1;
	}
	assert await until((): boolean => sink.count == total);
	assert server.count == total;
	assert server.patterned;
	assert sink.patterned;
	assert sink.closed === null;
	client.close();
	assert await until((): boolean => server.closed == CloseReason.PeerClosed);
	listener.value.close();
	cleanUp(path);
}

test "a reader that never reads is cut once its queue passes the limit" {
	const path = freshPath();
	const writer = new Accepted();
	const reason = new Sink();
	const handlers: ListenHandlers = {
		accepted: (c: Connection): void => {
			writer.c = c;
			c.start((chunk: uint8[]): void => {},
				(why: CloseReason): void => { reason.closed = why; });
		},
		failed: (): void => {},
	};
	const listener = listenUnix(path, handlers);
	assert listener.ok;
	const stalled = createUnixSocket();
	assert connectUnix(stalled, path) == 0;
	assert await until((): boolean => writer.c !== null);
	const w = writer.c!;
	const chunk = patterned(0, MIB);
	let pushed: int64 = 0;
	while (w.send(chunk)) {
		pushed += MIB as int64;
		await sleepAsync(1);
	}
	assert reason.closed == CloseReason.Backlogged;
	assert pushed >= MAX_QUEUED_BYTES - (MIB as int64);
	closeFd(stalled);
	listener.value.close();
	cleanUp(path);
}

test "a socket file left by a dead server is replaced" {
	const path = freshPath();
	const first = listenUnix(path, echoing());
	assert first.ok;
	first.value.close();
	const dead = createUnixSocket();
	assert bindUnix(dead, path) == 0;
	closeFd(dead);
	assert exists(path);
	const listener = listenUnix(path, echoing());
	assert listener.ok;
	const client = await dialed(path);
	const sink = new Sink();
	collect(client, sink, true);
	assert client.send("again".asBytes().slice(0));
	assert await until((): boolean => sink.text == "again");
	client.close();
	listener.value.close();
	cleanUp(path);
}

test "a second server finds the first running and leaves it serving" {
	const path = freshPath();
	const first = listenUnix(path, echoing());
	assert first.ok;
	const second = listenUnix(path, echoing());
	assert !second.ok;
	assert second.error == ListenError.AlreadyRunning;
	const client = await dialed(path);
	const sink = new Sink();
	collect(client, sink, true);
	assert client.send("still".asBytes().slice(0));
	assert await until((): boolean => sink.text == "still");
	client.close();
	first.value.close();
	cleanUp(path);
}

test "a client of a path nobody serves fails instead of waiting" {
	const got = await connectToUnix(freshPath(), 2000);
	assert !got.ok;
	assert got.error == ConnectError.Failed;
}

test "a tcp client on loopback echoes through the listener" {
	let port: int32 = 41000 + ((Date.now() % 20000) as int32);
	let listener: Listener | null = null;
	for (let tries: int32 = 0; tries < 50 && listener === null; tries++) {
		const got = listenTcp("127.0.0.1", port, echoing());
		if (got.ok) { listener = got.value; } else { port += 1; }
	}
	assert listener !== null;
	const got = await connectToTcp("127.0.0.1", port, 2000);
	assert got.ok;
	const client = got.value;
	const sink = new Sink();
	collect(client, sink, true);
	assert client.send("over tcp".asBytes().slice(0));
	assert await until((): boolean => sink.text == "over tcp");
	client.close();
	listener!.close();
}
