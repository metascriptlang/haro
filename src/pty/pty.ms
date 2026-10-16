@include("./conpty.h");
@compile("./conpty.c");

import { Pty, PtyError } from "./transport";

extern function ptyOpen(commandLine: cstring, cols: int32, rows: int32): int32;
extern function ptyRead(id: int32, buf: Span<uint8>): int64;
extern function ptyWait(id: int32, timeoutMs: int32): int32;
extern function ptyWrite(id: int32, data: Span<uint8>): int64;
extern function ptyResize(id: int32, cols: int32, rows: int32): int32;
extern function ptyExited(id: int32): int32;
extern function ptyExitCode(id: int32): int32;
extern function ptyClose(id: int32): void;

export struct ConPty { id: int32; }

export function open(
	this typeof ConPty,
	commandLine: string,
	cols: int32,
	rows: int32,
): Result<ConPty, PtyError> {
	const id = ptyOpen(commandLine, cols, rows);
	if (id < 0) { return Result.err(PtyError.OpenFailed); }
	return Result.ok({ id: id });
}

export function read(this p: ConPty, buf: Span<uint8>): Result<int32, PtyError> {
	const n = ptyRead(p.id, buf);
	if (n == -2) { return Result.err(PtyError.OutOfMemory); }
	if (n < 0) { return Result.err(PtyError.Closed); }
	return Result.ok(n as int32);
}

export function wait(this p: ConPty, timeoutMs: int32): Result<boolean, PtyError> {
	const r = ptyWait(p.id, timeoutMs);
	if (r == -2) { return Result.err(PtyError.WaitFailed); }
	if (r < 0) { return Result.err(PtyError.Closed); }
	return Result.ok(r == 1);
}

export function write(this p: ConPty, data: Span<uint8>): Result<int32, PtyError> {
	const n = ptyWrite(p.id, data);
	if (n < 0) { return Result.err(PtyError.Closed); }
	return Result.ok(n as int32);
}

export function resize(this p: ConPty, cols: int32, rows: int32): Result<ConPty, PtyError> {
	if (ptyResize(p.id, cols, rows) != 0) { return Result.err(PtyError.ResizeFailed); }
	return Result.ok(p);
}

export function exitCode(this p: ConPty): int32 | null {
	if (ptyExited(p.id) == 0) { return null; }
	return ptyExitCode(p.id);
}

export function close(this p: ConPty): void {
	ptyClose(p.id);
}

export function toPty(this p: ConPty): Pty {
	return {
		wait: (timeoutMs: int32): Result<boolean, PtyError> => { return p.wait(timeoutMs); },
		read: (buf: Span<uint8>): Result<int32, PtyError> => { return p.read(buf); },
		write: (data: Span<uint8>): Result<int32, PtyError> => { return p.write(data); },
		resize: (cols: int32, rows: int32): Result<void, PtyError> => {
			if (!p.resize(cols, rows).ok) { return Result.err(PtyError.ResizeFailed); }
			return Result.ok(null);
		},
		exitCode: (): int32 | null => { return p.exitCode(); },
		close: (): void => { p.close(); },
		ownsScreen: true,
	};
}

export function spawn(
	this typeof ConPty,
	commandLine: string,
	cols: int32,
	rows: int32,
): Result<Pty, PtyError> {
	const opened = try ConPty.open(commandLine, cols, rows);
	return Result.ok(opened.toPty());
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

function quietWaitMs(this p: ConPty, timeoutMs: int32): Result<float64, PtyError> {
	let buf: Vec<uint8> = new Array(4096);
	while (true) {
		const start: float64 = performance.now();
		const ready = try p.wait(timeoutMs);
		if (!ready) { return Result.ok(performance.now() - start); }
		const _read = try p.read(buf);
	}
}

test "a ConPTY child's output reaches read and its exit ends the stream" {
	const opened = ConPty.open("cmd.exe /c echo hello", 80, 24);
	assert opened.ok;
	if (opened.ok) {
		const p = opened.value;
		const text = p.toPty().drain();
		assert text.includes("hello");
		const code = p.exitCode();
		assert code !== null;
		if (code !== null) { assert code == 0; }
		p.close();
	}
}

test "a wait returns as soon as the child writes" {
	const opened = ConPty.open("cmd.exe /c echo hello", 80, 24);
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
	const opened = ConPty.open("cmd.exe /c ping -n 4 127.0.0.1 > nul", 80, 24);
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
	const opened = ConPty.open("cmd.exe /c echo hello", 80, 24);
	assert opened.ok;
	if (opened.ok) {
		const resized = opened.value.resize(120, 40);
		assert resized.ok;
		if (resized.ok) { assert resized.value.id == opened.value.id; }
		opened.value.close();
	}
}

test "a command that cannot start is an error" {
	const opened = ConPty.open("no-such-program-haro.exe", 80, 24);
	assert !opened.ok;
}

test "a ConPTY spawned as a Pty reads its output and reports its exit through the interface" {
	const spawned = ConPty.spawn("cmd.exe /c echo hello", 80, 24);
	assert spawned.ok;
	if (spawned.ok) {
		const pty = spawned.value;
		assert pty.drain().includes("hello");
		const code = pty.exitCode();
		assert code !== null;
		if (code !== null) { assert code == 0; }
		pty.close();
	}
}

test "a resize through the Pty interface reaches a live ConPTY" {
	const spawned = ConPty.spawn("cmd.exe /c ping -n 4 127.0.0.1 > nul", 80, 24);
	assert spawned.ok;
	if (spawned.ok) {
		const pty = spawned.value;
		assert pty.resize(100, 30).ok;
		pty.close();
	}
}
