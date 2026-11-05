import { Pty, PtyError } from "./transport";
import { append, copyInto } from "./bytes";
import { Vt, VtError, create, restore, write } from "../vt/vt";

export struct Seed {
	native: boolean;
	cols: int32;
	rows: int32;
	bytes: Vec<uint8>;
}

export function seededVt(this seed: Seed): Result<Vt, VtError> {
	if (seed.bytes.length == 0) { return Vt.create(seed.cols, seed.rows); }
	if (seed.native) { return Vt.restore(seed.bytes); }
	const vt = try Vt.create(seed.cols, seed.rows);
	vt.write(seed.bytes);
	return Result.ok(vt);
}

export interface RemotePty {
	inbound: Vec<Vec<uint8>>;
	head: int32;
	typed: Vec<uint8>;
	lastSeq: uint64;
	closed: boolean;
}

export function empty(this typeof RemotePty): RemotePty {
	return { inbound: [], head: 0, typed: [], lastSeq: 0, closed: false };
}

export function feed(this r: RemotePty, first: uint64, last: uint64, sink bytes: Vec<uint8>): boolean {
	if (first <= r.lastSeq) { return false; }
	r.lastSeq = last;
	if (bytes.length > 0) { r.inbound.push(bytes); }
	return true;
}

export function takeTyped(this r: RemotePty): Vec<uint8> {
	const typed = r.typed;
	r.typed = [];
	return typed;
}

function read(this r: RemotePty, buf: Span<uint8>): int32 {
	let n: int32 = 0;
	while (n < buf.length && r.inbound.length > 0) {
		const chunk: Readonly<Span<uint8>> = r.inbound[0];
		const take = Math.min(chunk.length - r.head, buf.length - n);
		copyInto(buf, n, chunk[r.head..r.head + take]);
		const ended = r.head + take == chunk.length;
		n += take;
		r.head += take;
		if (ended) {
			r.inbound.shift();
			r.head = 0;
		}
	}
	return n;
}

export function asPty(this r: RemotePty): Pty {
	return {
		wait: (timeoutMs: int32): Result<boolean, PtyError> => {
			return Result.ok(r.inbound.length > 0);
		},
		read: (buf: Span<uint8>): Result<int32, PtyError> => {
			if (r.closed) { return Result.err(PtyError.Closed); }
			return Result.ok(r.read(buf));
		},
		write: (data: Readonly<Span<uint8>>): Result<void, PtyError> => {
			if (r.closed) { return Result.err(PtyError.Closed); }
			r.typed.append(data);
			return Result.ok(null);
		},
		resize: (
			cols: int32,
			rows: int32,
			cellWidth: int32,
			cellHeight: int32,
		): Result<void, PtyError> => {
			return Result.ok(null);
		},
		exitCode: (): int32 | null => { return null; },
		exitSignal: (): int32 => { return 0; },
		close: (): void => { r.closed = true; },
		busy: (): boolean => { return true; },
		ownsScreen: false,
		takesReplies: false,
	};
}
