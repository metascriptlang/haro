@include("./conpty.h");
@compile("./conpty.c");

extern function ptyOpen(commandLine: cstring, cols: int32, rows: int32): int32;
extern function ptyRead(id: int32, buf: Span<uint8>): int64;
extern function ptyWait(id: int32, timeoutMs: int32): int32;
extern function ptyWrite(id: int32, data: Span<uint8>): int64;
extern function ptyResize(id: int32, cols: int32, rows: int32): int32;
extern function ptyExited(id: int32): int32;
extern function ptyExitCode(id: int32): int32;
extern function ptyClose(id: int32): void;

export enum PtyError {
	OpenFailed,
	Closed,
	OutOfMemory,
	ResizeFailed,
	WaitFailed,
}

export struct Pty { id: int32; }

export function open(
	this typeof Pty,
	commandLine: string,
	cols: int32,
	rows: int32,
): Result<Pty, PtyError> {
	const id = ptyOpen(commandLine, cols, rows);
	if (id < 0) { return Result.err(PtyError.OpenFailed); }
	return Result.ok({ id: id });
}

export function read(this p: Pty, buf: Span<uint8>): Result<int32, PtyError> {
	const n = ptyRead(p.id, buf);
	if (n == -2) { return Result.err(PtyError.OutOfMemory); }
	if (n < 0) { return Result.err(PtyError.Closed); }
	return Result.ok(n as int32);
}

export function wait(this p: Pty, timeoutMs: int32): Result<boolean, PtyError> {
	const r = ptyWait(p.id, timeoutMs);
	if (r == -2) { return Result.err(PtyError.WaitFailed); }
	if (r < 0) { return Result.err(PtyError.Closed); }
	return Result.ok(r == 1);
}

export function write(this p: Pty, data: Span<uint8>): Result<int32, PtyError> {
	const n = ptyWrite(p.id, data);
	if (n < 0) { return Result.err(PtyError.Closed); }
	return Result.ok(n as int32);
}

export function resize(this p: Pty, cols: int32, rows: int32): Result<Pty, PtyError> {
	if (ptyResize(p.id, cols, rows) != 0) { return Result.err(PtyError.ResizeFailed); }
	return Result.ok(p);
}

export function exitCode(this p: Pty): int32 | null {
	if (ptyExited(p.id) == 0) { return null; }
	return ptyExitCode(p.id);
}

export function close(this p: Pty): void {
	ptyClose(p.id);
}

function drain(this p: Pty): string {
	let buf: Vec<uint8> = new Array(4096);
	let text = "";
	while (true) {
		const ready = p.wait(10000);
		if (!ready.ok || !ready.value) { return text; }
		const r = p.read(buf);
		if (!r.ok) { return text; }
		for (let i = 0; i < r.value; i++) {
			text += String.fromCharCode(buf[i] as int32);
		}
	}
}

function quietWaitMs(this p: Pty, timeoutMs: int32): Result<float64, PtyError> {
	let buf: Vec<uint8> = new Array(4096);
	while (true) {
		const start: float64 = performance.now();
		const ready = try p.wait(timeoutMs);
		if (!ready) { return Result.ok(performance.now() - start); }
		const _read = try p.read(buf);
	}
}

test "a ConPTY child's output reaches read and its exit ends the stream" {
	const opened = Pty.open("cmd.exe /c echo hello", 80, 24);
	assert opened.ok;
	if (opened.ok) {
		const p = opened.value;
		const text = p.drain();
		assert text.includes("hello");
		const code = p.exitCode();
		assert code !== null;
		if (code !== null) { assert code == 0; }
		p.close();
	}
}

test "a wait returns as soon as the child writes" {
	const opened = Pty.open("cmd.exe /c echo hello", 80, 24);
	assert opened.ok;
	if (opened.ok) {
		const p = opened.value;
		const start: float64 = performance.now();
		const ready = p.wait(10000);
		assert ready.ok;
		if (ready.ok) { assert ready.value; }
		assert performance.now() - start < 5000;
		p.close();
	}
}

test "a wait on a quiet child sleeps until its timeout" {
	const opened = Pty.open("cmd.exe /c ping -n 4 127.0.0.1 > nul", 80, 24);
	assert opened.ok;
	if (opened.ok) {
		const p = opened.value;
		const waited = p.quietWaitMs(300);
		assert waited.ok;
		if (waited.ok) { assert waited.value >= 250; }
		assert p.exitCode() === null;
		p.close();
	}
}

test "a resize of a live console succeeds and hands the pty back" {
	const opened = Pty.open("cmd.exe /c echo hello", 80, 24);
	assert opened.ok;
	if (opened.ok) {
		const resized = opened.value.resize(120, 40);
		assert resized.ok;
		if (resized.ok) { assert resized.value.id == opened.value.id; }
		opened.value.close();
	}
}

test "a command that cannot start is an error" {
	const opened = Pty.open("no-such-program-terminator.exe", 80, 24);
	assert !opened.ok;
}
