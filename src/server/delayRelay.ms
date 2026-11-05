import { recvAsync } from "std/net";
import { Connection, ListenError, Listener, connectToUnix, listenUnix } from "./transport";

const READ_BYTES: int32 = 64 * 1024;
const CONNECT_MS: int32 = 2000;
const ROOM_POLL_MS: int32 = 1;

export struct LinkShape {
	oneWayMs: float64;
	bytesPerSecond: float64;
	windowBytes: int64;
}

export const SSH_WINDOW_BYTES: int64 = 2 * 1024 * 1024;

export function delayed(rttMs: float64): LinkShape {
	return { oneWayMs: rttMs / 2, bytesPerSecond: 0, windowBytes: SSH_WINDOW_BYTES };
}

struct Timed {
	due: float64;
	bytes: uint8[];
}

class Lane {
	readonly to: Connection;
	readonly shape: LinkShape;
	queue: Timed[] = [];
	held: int64 = 0;
	freeAt: float64 = 0;
	timer: number | null = null;
	ended: boolean = false;
	carried: int64 = 0;

	constructor(to: Connection, shape: LinkShape) {
		this.to = to;
		this.shape = shape;
	}
}

function full(this lane: Lane): boolean {
	return lane.held + lane.to.queued() >= lane.shape.windowBytes;
}

function take(this lane: Lane, bytes: uint8[]): void {
	const now = performance.now();
	const start = Math.max(now, lane.freeAt);
	const rate = lane.shape.bytesPerSecond;
	lane.freeAt = rate > 0 ? start + (bytes.length as float64) * 1000 / rate : start;
	lane.queue.push({ due: lane.freeAt + lane.shape.oneWayMs, bytes: bytes });
	lane.held += bytes.length as int64;
	lane.carried += bytes.length as int64;
	if (lane.timer === null) { lane.release(); }
}

function release(this lane: Lane): void {
	lane.timer = null;
	const now = performance.now();
	while (lane.queue.length > 0 && lane.queue[0].due <= now) {
		const next = lane.queue.shift()!;
		lane.held -= next.bytes.length as int64;
		const _sent = lane.to.send(next.bytes);
	}
	if (lane.queue.length > 0) {
		const wait = Math.max(0, Math.ceil(lane.queue[0].due - now)) as int32;
		lane.timer = setTimeout((): void => { lane.release(); }, wait);
	} else if (lane.ended) {
		lane.to.finish();
	}
}

async function pump(from: Connection, lane: Lane): Promise<void> {
	while (from.isOpen() && lane.to.isOpen()) {
		while (lane.full() && from.isOpen() && lane.to.isOpen()) { await sleepAsync(ROOM_POLL_MS); }
		const chunk = await recvAsync(from.fd, READ_BYTES);
		if (chunk.length == 0) { break; }
		lane.take(chunk);
	}
	lane.ended = true;
	if (lane.timer === null) { lane.release(); }
}

export class DelayRelay {
	readonly shape: LinkShape;
	readonly target: string;
	listener: Listener | null = null;
	backs: Lane[] = [];
	ends: Connection[] = [];

	constructor(target: string, shape: LinkShape) {
		this.target = target;
		this.shape = shape;
	}
}

export function carriedBack(this r: DelayRelay): int64 {
	let total: int64 = 0;
	for (const lane of r.backs) { total += lane.carried; }
	return total;
}

export function close(this r: DelayRelay): void {
	r.listener?.close();
	for (const c of r.ends) { c.close(); }
	r.ends = [];
}

async function joined(r: DelayRelay, near: Connection): Promise<void> {
	const dialed = await connectToUnix(r.target, CONNECT_MS);
	if (!dialed.ok) {
		near.close();
		return;
	}
	const far = dialed.value;
	r.ends.push(near);
	r.ends.push(far);
	const out = new Lane(far, r.shape);
	const back = new Lane(near, r.shape);
	r.backs.push(back);
	const _out = pump(near, out);
	const _back = pump(far, back);
}

export function relay(
	this typeof DelayRelay,
	listenAt: string,
	target: string,
	shape: LinkShape,
): Result<DelayRelay, ListenError> {
	const r = new DelayRelay(target, shape);
	const listening = listenUnix(listenAt, {
		accepted: (c: Connection): void => { const _joined = joined(r, c); },
		failed: (): void => {},
	});
	if (!listening.ok) { return Result.err(listening.error); }
	r.listener = listening.value;
	return Result.ok(r);
}
