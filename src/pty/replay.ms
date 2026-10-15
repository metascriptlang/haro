import { Pty, PtyError } from "./transport";

export struct Replay { bytes: Vec<uint8>; }

export function ofText(this typeof Replay, text: string): Replay {
	const view = text.asBytes();
	let bytes: Vec<uint8> = new Array(view.length);
	for (let i = 0; i < view.length; i++) { bytes[i] = view[i]; }
	return { bytes: bytes };
}

export function toPty(this r: Replay): Pty {
	const bytes = r.bytes;
	const total = bytes.length as int32;
	let at = 0;
	let closed = false;
	return {
		wait: (timeoutMs: int32): Result<boolean, PtyError> => {
			if (closed) { return Result.err(PtyError.Closed); }
			return Result.ok(true);
		},
		read: (buf: Span<uint8>): Result<int32, PtyError> => {
			if (closed || at >= total) { return Result.err(PtyError.Closed); }
			const room = buf.length as int32;
			const n = total - at < room ? total - at : room;
			for (let i = 0; i < n; i++) { buf[i] = bytes[at + i]; }
			at += n;
			return Result.ok(n);
		},
		write: (data: Span<uint8>): Result<int32, PtyError> => {
			if (closed) { return Result.err(PtyError.Closed); }
			return Result.ok(data.length as int32);
		},
		resize: (cols: int32, rows: int32): Result<void, PtyError> => {
			if (closed) { return Result.err(PtyError.Closed); }
			return Result.ok(null);
		},
		exitCode: (): int32 | null => { return at >= total ? 0 : null; },
		close: (): void => { closed = true; },
	};
}

function drainText(this p: Pty, chunk: int32): string {
	let buf: Vec<uint8> = new Array(chunk);
	let text = "";
	while (true) {
		const r = p.read(buf);
		if (!r.ok) { return text; }
		for (let i = 0; i < r.value; i++) { text += String.fromCharCode(buf[i] as int32); }
	}
}

test "a replay hands back its bytes in order, whatever the read size" {
	const replay = Replay.ofText("hello, replay");
	assert replay.bytes.length == 13;
	assert replay.toPty().drainText(4096) == "hello, replay";
	assert replay.toPty().drainText(5) == "hello, replay";
	assert replay.toPty().drainText(1) == "hello, replay";
}

test "a replay is ready until its last byte, then ends like a child that exited" {
	const pty = Replay.ofText("ab").toPty();
	let buf: Vec<uint8> = new Array(8);
	assert pty.exitCode() === null;
	const ready = pty.wait(0);
	assert ready.ok;
	if (ready.ok) { assert ready.value; }
	const first = pty.read(buf);
	assert first.ok;
	if (first.ok) { assert first.value == 2; }
	assert pty.exitCode() === 0;
	const ended = pty.read(buf);
	assert !ended.ok;
	if (!ended.ok) { assert ended.error == PtyError.Closed; }
	const readyAtEnd = pty.wait(0);
	assert readyAtEnd.ok;
	if (readyAtEnd.ok) { assert readyAtEnd.value; }
}

test "a replay accepts writes and resizes and changes nothing" {
	const pty = Replay.ofText("xyz").toPty();
	let buf: Vec<uint8> = new Array(8);
	buf[0] = 113;
	const wrote = pty.write(buf[0..1]);
	assert wrote.ok;
	if (wrote.ok) { assert wrote.value == 1; }
	assert pty.resize(100, 30).ok;
	assert pty.drainText(8) == "xyz";
}

test "a closed replay refuses every call" {
	const pty = Replay.ofText("xyz").toPty();
	let buf: Vec<uint8> = new Array(8);
	pty.close();
	assert !pty.wait(0).ok;
	assert !pty.read(buf).ok;
	assert !pty.write(buf[0..1]).ok;
	assert !pty.resize(100, 30).ok;
}

test "a replay can be played again from its start" {
	const replay = Replay.ofText("again");
	assert replay.toPty().drainText(8) == "again";
	assert replay.toPty().drainText(8) == "again";
}
