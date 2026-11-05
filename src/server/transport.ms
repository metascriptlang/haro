@include("runtime/io/engine.h");

import {
	acceptAsync,
	bind,
	bindUnix,
	close as closeFd,
	connect,
	connectUnix,
	createSocket,
	createUnixSocket,
	listen,
	recvAsync,
	sendAsync,
	setNonBlocking,
} from "std/net";
import { chmod, exists, isLinkLike, mkdir, remove } from "std/fs";
import { dirname, join } from "std/fs/path";
import { tmpDir } from "std/os";
import { env } from "std/process";
import { copyInto } from "../pty/bytes";
import { MAX_PAYLOAD_BYTES } from "./protocol";

extern function msIoEngineCancelFd_ms(fd: int32): void;

when (!windows) {
	@include("unistd.h");
	@include("sys/socket.h");
	@include("netinet/in.h");
	@include("arpa/inet.h");

	extern function getuid(): uint32;
	extern struct PeerStorage from "struct sockaddr_storage" { ss_family: uint16; }
	extern struct PeerSockaddr from "struct sockaddr" { sa_family: uint16; }
	extern struct PeerIn4Addr from "struct in_addr" { s_addr: uint32; }
	extern struct PeerIn4 from "struct sockaddr_in" { sin_port: uint16; sin_addr: PeerIn4Addr; }
	extern const AF_INET: int32 from "AF_INET";
	extern function peerName(fd: int32, addr: Ptr<PeerSockaddr>, ref len: uint32): int32 from "getpeername";
	extern function ntohs(v: uint16): uint16;
	extern function ntop(
		family: int32,
		src: Ptr<void>,
		dst: Ptr<uint8>,
		size: uint32,
	): Ptr<void> | null from "inet_ntop";
}

export const MAX_QUEUED_BYTES: int64 = (MAX_PAYLOAD_BYTES as int64) + 8 * 1024 * 1024;
const READ_CHUNK: int32 = 64 * 1024;
const BACKLOG: int32 = 64;
const SOCKET_NAME = "haro.sock";
const OWNER_ONLY_DIR: int32 = 0o700;
const OWNER_ONLY_SOCKET: int32 = 0o600;
const TIMED_OUT: int32 = -2;
const ADDRESS_TEXT_BYTES: int32 = 64;

export enum CloseReason {
	Closed,
	PeerClosed,
	SendFailed,
	Backlogged,
}

export enum ListenError {
	AlreadyRunning,
	UnsafeDir,
	BindFailed,
	ListenFailed,
}

export enum ConnectError {
	Failed,
	TimedOut,
}

export function socketPath(): string {
	const chosen = env.get("HARO_SOCKET");
	if (chosen != "") { return chosen; }
	const runtime = env.get("XDG_RUNTIME_DIR");
	if (runtime != "") { return join(join(runtime, "haro"), SOCKET_NAME); }
	when (windows) {
		return join(join(tmpDir(), "haro"), SOCKET_NAME);
	} else {
		return join(join(tmpDir(), `haro-${getuid()}`), SOCKET_NAME);
	}
}

when (windows) {
	export function peerAddress(fd: int32): string | null {
		return null;
	}
} else {
	export function peerAddress(fd: int32): string | null {
		let peer: PeerStorage = {};
		let len: uint32 = sizeof PeerStorage as uint32;
		if (peerName(fd, peer as Ptr<PeerSockaddr>, len) != 0) { return null; }
		if ((peer.ss_family as int32) != AF_INET) { return null; }
		const v4 = peer as Ptr<PeerIn4>;
		let text: Vec<uint8> = new Array(ADDRESS_TEXT_BYTES);
		const at = text as Span<uint8> as Ptr<uint8>;
		if (ntop(AF_INET, v4[0].sin_addr as Ptr<void>, at, ADDRESS_TEXT_BYTES as uint32) === null) {
			return null;
		}
		const end = text.indexOf(0);
		return `${text.slice(0, end < 0 ? text.length : end).asString()}:${ntohs(v4[0].sin_port)}`;
	}
}

export const UNTAGGED: int32 = -1;

struct Queued {
	bytes: uint8[];
	tag: int32;
}

struct TagBytes {
	tag: int32;
	bytes: int64;
}

function ignoreData(chunk: uint8[]): void {}
function ignoreClose(reason: CloseReason): void {}
function ignoreIdle(): void {}
function ignoreSent(total: int64): void {}

export class Connection {
	readonly fd: int32;
	readonly readBytes: int32;
	private onData: (chunk: uint8[]) => void = ignoreData;
	private onClose: (reason: CloseReason) => void = ignoreClose;
	private onIdle: () => void = ignoreIdle;
	private onSent: (total: int64) => void = ignoreSent;
	private queue: Queued[] = [];
	private queuedBytes: int64 = 0;
	private tagged: Vec<TagBytes> = [];
	private flying: Vec<TagBytes> = [];
	private progressAt: float64 = 0;
	private sending: boolean = false;
	private reading: boolean = false;
	private open: boolean = true;
	private finishing: boolean = false;
	writes: int32 = 0;
	sentBytes: int64 = 0;

	constructor(fd: int32, readBytes: int32 = READ_CHUNK) {
		this.fd = fd;
		this.readBytes = readBytes;
	}

	isOpen(): boolean { return this.open; }

	start(
		onData: (chunk: uint8[]) => void,
		onClose: (reason: CloseReason) => void,
	): void {
		if (!this.open || this.reading) { return; }
		this.onData = onData;
		this.onClose = onClose;
		this.reading = true;
		const _reading = readLoop(this);
	}

	queued(): int64 { return this.queuedBytes; }

	queuedFor(tag: int32): int64 {
		for (const t of this.tagged) {
			if (t.tag == tag) { return t.bytes; }
		}
		return 0;
	}

	stalled(now: float64, quietMs: float64): boolean {
		return this.queuedBytes > 0 && now - this.progressAt > quietMs;
	}

	private count(tag: int32, bytes: int64): void {
		if (tag == UNTAGGED) { return; }
		for (let i = 0; i < this.tagged.length; i++) {
			if (this.tagged[i].tag == tag) {
				this.tagged[i].bytes += bytes;
				return;
			}
		}
		this.tagged.push({ tag: tag, bytes: bytes });
	}

	whenIdle(idle: () => void): void {
		if (!this.open) { return; }
		if (!this.sending) {
			idle();
			return;
		}
		this.onIdle = idle;
	}

	watchSent(sent: (total: int64) => void): void { this.onSent = sent; }

	send(bytes: uint8[], tag: int32 = UNTAGGED): boolean {
		if (!this.open || this.finishing) { return false; }
		if (bytes.length == 0) { return true; }
		if (this.queuedBytes == 0) { this.progressAt = performance.now(); }
		this.queuedBytes += bytes.length as int64;
		if (this.queuedBytes > MAX_QUEUED_BYTES) {
			this.end(CloseReason.Backlogged);
			return false;
		}
		this.queue.push({ bytes: bytes, tag: tag });
		this.count(tag, bytes.length as int64);
		if (!this.sending) {
			this.sending = true;
			const _flushing = flushLoop(this);
		}
		return true;
	}

	close(): void { this.end(CloseReason.Closed); }

	finish(): void {
		if (!this.open) { return; }
		this.finishing = true;
		if (!this.sending) { this.end(CloseReason.Closed); }
	}

	end(reason: CloseReason): void {
		if (!this.open) { return; }
		this.open = false;
		this.queue = [];
		this.queuedBytes = 0;
		this.tagged = [];
		this.flying = [];
		msIoEngineCancelFd_ms(this.fd);
		closeFd(this.fd);
		const onClose = this.onClose;
		this.onData = ignoreData;
		this.onClose = ignoreClose;
		this.onIdle = ignoreIdle;
		this.onSent = ignoreSent;
		onClose(reason);
	}

	deliver(chunk: uint8[]): void { this.onData(chunk); }

	drop(tag: int32): int64 {
		let dropped: int64 = 0;
		const kept: Queued[] = [];
		for (const q of this.queue) {
			if (q.tag == tag) {
				dropped += q.bytes.length as int64;
			} else {
				kept.push(q);
			}
		}
		this.queue = kept;
		this.queuedBytes -= dropped;
		this.count(tag, -dropped);
		return dropped;
	}

	takeQueue(): uint8[] {
		const batch = this.queue;
		this.queue = [];
		if (batch.length == 0) {
			this.sending = false;
			if (this.finishing) { this.end(CloseReason.Closed); }
			const idle = this.onIdle;
			this.onIdle = ignoreIdle;
			idle();
			return [];
		}
		for (const q of batch) { this.fly(q.tag, q.bytes.length as int64); }
		if (batch.length == 1) { return batch[0].bytes; }
		let total: int32 = 0;
		for (const q of batch) { total += q.bytes.length; }
		const joined = Buffer.allocUnsafe(total) as uint8[];
		let at: int32 = 0;
		for (const q of batch) {
			copyInto(joined, at, q.bytes);
			at += q.bytes.length;
		}
		return joined;
	}

	private fly(tag: int32, bytes: int64): void {
		if (tag == UNTAGGED) { return; }
		for (let i = 0; i < this.flying.length; i++) {
			if (this.flying[i].tag == tag) {
				this.flying[i].bytes += bytes;
				return;
			}
		}
		this.flying.push({ tag: tag, bytes: bytes });
	}

	sent(count: int64): void {
		for (const f of this.flying) { this.count(f.tag, -f.bytes); }
		this.flying = [];
		this.progressAt = performance.now();
		this.queuedBytes -= count;
		this.sentBytes += count;
		this.onSent(this.sentBytes);
	}
}

async function readLoop(c: Connection): Promise<void> {
	while (c.isOpen()) {
		const chunk = await recvAsync(c.fd, c.readBytes);
		if (!c.isOpen()) { return; }
		if (chunk.length == 0) {
			c.end(CloseReason.PeerClosed);
			return;
		}
		c.deliver(chunk);
	}
}

async function flushLoop(c: Connection): Promise<void> {
	let batch = c.takeQueue();
	while (batch.length > 0) {
		c.writes += 1;
		const sent = await sendAsync(c.fd, batch);
		if (!c.isOpen()) { return; }
		if (sent < 0) {
			c.end(CloseReason.SendFailed);
			return;
		}
		c.sent(batch.length as int64);
		batch = c.takeQueue();
	}
}

export struct ListenHandlers {
	accepted: (c: Connection) => void;
	failed: () => void;
}

export class Listener {
	readonly fd: int32;
	readonly path: string | null;
	private handlers: ListenHandlers;
	private open: boolean = true;

	constructor(fd: int32, path: string | null, handlers: ListenHandlers) {
		this.fd = fd;
		this.path = path;
		this.handlers = handlers;
	}

	isOpen(): boolean { return this.open; }

	accepted(fd: int32): void { this.handlers.accepted(new Connection(fd)); }

	close(): void {
		if (!this.open) { return; }
		this.open = false;
		msIoEngineCancelFd_ms(this.fd);
		closeFd(this.fd);
		const path = this.path;
		if (path !== null) { const _removed = remove(path); }
	}

	fail(): void {
		if (!this.open) { return; }
		const failed = this.handlers.failed;
		this.close();
		failed();
	}
}

async function acceptLoop(l: Listener): Promise<void> {
	while (l.isOpen()) {
		const fd = await acceptAsync(l.fd);
		if (!l.isOpen()) {
			if (fd >= 0) { closeFd(fd); }
			return;
		}
		if (fd < 0) {
			l.fail();
			return;
		}
		l.accepted(fd);
	}
}

function listening(
	fd: int32,
	path: string | null,
	handlers: ListenHandlers,
): Result<Listener, ListenError> {
	if (listen(fd, BACKLOG) != 0 || setNonBlocking(fd) != 0) {
		closeFd(fd);
		if (path !== null) { const _removed = remove(path); }
		return Result.err(ListenError.ListenFailed);
	}
	const l = new Listener(fd, path, handlers);
	const _accepting = acceptLoop(l);
	return Result.ok(l);
}

function privateDir(dir: string): boolean {
	if (!mkdir(dir).ok) { return false; }
	const link = isLinkLike(dir);
	return link.ok && !link.value && chmod(dir, OWNER_ONLY_DIR).ok;
}

function answers(path: string): boolean {
	const fd = createUnixSocket();
	if (fd < 0) { return false; }
	const _nonBlocking = setNonBlocking(fd);
	const reached = connectUnix(fd, path) == 0;
	closeFd(fd);
	return reached;
}

export function listenUnix(
	path: string,
	handlers: ListenHandlers,
): Result<Listener, ListenError> {
	if (!privateDir(dirname(path))) { return Result.err(ListenError.UnsafeDir); }
	if (exists(path)) {
		if (answers(path)) { return Result.err(ListenError.AlreadyRunning); }
		const _removed = remove(path);
	}
	const fd = createUnixSocket();
	if (fd < 0) { return Result.err(ListenError.BindFailed); }
	if (bindUnix(fd, path) != 0) {
		closeFd(fd);
		return Result.err(ListenError.BindFailed);
	}
	if (!chmod(path, OWNER_ONLY_SOCKET).ok) {
		closeFd(fd);
		const _removed = remove(path);
		return Result.err(ListenError.BindFailed);
	}
	return listening(fd, path, handlers);
}

export function listenTcp(
	address: string,
	port: int32,
	handlers: ListenHandlers,
): Result<Listener, ListenError> {
	const fd = createSocket();
	if (fd < 0) { return Result.err(ListenError.BindFailed); }
	if (bind(fd, address, port) != 0) {
		closeFd(fd);
		return Result.err(ListenError.BindFailed);
	}
	return listening(fd, null, handlers);
}

function dialedUnix(path: string): int32 {
	const fd = createUnixSocket();
	if (fd < 0) { return -1; }
	if (connectUnix(fd, path) == 0) { return fd; }
	closeFd(fd);
	return -1;
}

function dialedTcp(host: string, port: int32): int32 {
	const fd = createSocket();
	if (fd < 0) { return -1; }
	if (connect(fd, host, port) == 0) { return fd; }
	closeFd(fd);
	return -1;
}

function closeWhenDialed(job: Promise<int32>): void {
	job.then((fd: int32): void => {
		if (fd >= 0) { closeFd(fd); }
	});
}

async function dialed(
	job: Promise<int32>,
	timeoutMs: int32,
): Promise<Result<Connection, ConnectError>> {
	let timer: number = 0;
	const expired = new Promise<int32>((resolve) => {
		timer = setTimeout((): void => { resolve(TIMED_OUT); }, timeoutMs);
	});
	const fd = await Promise.race([job, expired]);
	if (fd == TIMED_OUT) {
		closeWhenDialed(job);
		return Result.err(ConnectError.TimedOut);
	}
	clearTimeout(timer);
	if (fd < 0) { return Result.err(ConnectError.Failed); }
	return Result.ok(new Connection(fd));
}

export async function connectToUnix(
	path: string,
	timeoutMs: int32,
): Promise<Result<Connection, ConnectError>> {
	const target = path;
	const job = spawn((): int32 => dialedUnix(target), { move: [target] });
	return await dialed(job, timeoutMs);
}

export async function connectToTcp(
	host: string,
	port: int32,
	timeoutMs: int32,
): Promise<Result<Connection, ConnectError>> {
	const target = host;
	const job = spawn((): int32 => dialedTcp(target, port), { move: [target] });
	return await dialed(job, timeoutMs);
}
