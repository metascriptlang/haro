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

extern function msIoEngineCancelFd_ms(fd: int32): void;

when (!windows) {
	@include("unistd.h");

	extern function getuid(): uint32;
}

export const MAX_QUEUED_BYTES: int64 = 32 * 1024 * 1024;
const READ_CHUNK: int32 = 64 * 1024;
const BACKLOG: int32 = 64;
const SOCKET_NAME = "haro.sock";
const OWNER_ONLY_DIR: int32 = 0o700;
const OWNER_ONLY_SOCKET: int32 = 0o600;
const TIMED_OUT: int32 = -2;

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
	const runtime = env.get("XDG_RUNTIME_DIR");
	if (runtime != "") { return join(join(runtime, "haro"), SOCKET_NAME); }
	when (windows) {
		return join(join(tmpDir(), "haro"), SOCKET_NAME);
	} else {
		return join(join(tmpDir(), `haro-${getuid()}`), SOCKET_NAME);
	}
}

function ignoreData(chunk: uint8[]): void {}
function ignoreClose(reason: CloseReason): void {}

export class Connection {
	readonly fd: int32;
	private onData: (chunk: uint8[]) => void = ignoreData;
	private onClose: (reason: CloseReason) => void = ignoreClose;
	private queue: uint8[][] = [];
	private queuedBytes: int64 = 0;
	private sending: boolean = false;
	private reading: boolean = false;
	private open: boolean = true;

	constructor(fd: int32) { this.fd = fd; }

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

	send(bytes: uint8[]): boolean {
		if (!this.open) { return false; }
		if (bytes.length == 0) { return true; }
		this.queuedBytes += bytes.length as int64;
		if (this.queuedBytes > MAX_QUEUED_BYTES) {
			this.end(CloseReason.Backlogged);
			return false;
		}
		this.queue.push(bytes);
		if (!this.sending) {
			this.sending = true;
			const _flushing = flushLoop(this);
		}
		return true;
	}

	close(): void { this.end(CloseReason.Closed); }

	end(reason: CloseReason): void {
		if (!this.open) { return; }
		this.open = false;
		this.queue = [];
		this.queuedBytes = 0;
		msIoEngineCancelFd_ms(this.fd);
		closeFd(this.fd);
		const onClose = this.onClose;
		this.onData = ignoreData;
		this.onClose = ignoreClose;
		onClose(reason);
	}

	deliver(chunk: uint8[]): void { this.onData(chunk); }

	takeQueue(): uint8[][] {
		const batch = this.queue;
		this.queue = [];
		if (batch.length == 0) { this.sending = false; }
		return batch;
	}

	sent(count: int64): void { this.queuedBytes -= count; }
}

async function readLoop(c: Connection): Promise<void> {
	while (c.isOpen()) {
		const chunk = await recvAsync(c.fd, READ_CHUNK);
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
		for (const bytes of batch) {
			const sent = await sendAsync(c.fd, bytes);
			if (!c.isOpen()) { return; }
			if (sent < 0) {
				c.end(CloseReason.SendFailed);
				return;
			}
			c.sent(bytes.length as int64);
		}
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
