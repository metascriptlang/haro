@include("./nativePty.h");
when (windows) {
	@compile("./conpty.c");
} else {
	@compile("./posixPty.c");
}
when (linux) {
	@passL("-lutil");
}

import { remove, writeFile } from "std/fs";
import { tmpDir } from "std/os";
import { Pty, PtyError } from "./transport";

extern function ptyOpen(commandLine: cstring, cwd: cstring, cols: int32, rows: int32): int32;
extern function ptyRead(id: int32, buf: Span<uint8>): int64;
extern function ptyWait(id: int32, timeoutMs: int32): int32;
extern function ptyWrite(id: int32, data: Span<uint8>): int64;
extern function ptyResize(id: int32, cols: int32, rows: int32): int32;
extern function ptyExited(id: int32): int32;
extern function ptyExitCode(id: int32): int32;
extern function ptyClose(id: int32): void;

export struct NativePty { id: int32; }

export function open(
	this typeof NativePty,
	commandLine: string,
	cols: int32,
	rows: int32,
	cwd: string | null = null,
): Result<NativePty, PtyError> {
	const id = ptyOpen(commandLine, cwd ?? "", cols, rows);
	if (id < 0) { return Result.err(PtyError.OpenFailed); }
	return Result.ok({ id: id });
}

export function read(this p: NativePty, buf: Span<uint8>): Result<int32, PtyError> {
	const n = ptyRead(p.id, buf);
	if (n == -2) { return Result.err(PtyError.OutOfMemory); }
	if (n < 0) { return Result.err(PtyError.Closed); }
	return Result.ok(n as int32);
}

export function wait(this p: NativePty, timeoutMs: int32): Result<boolean, PtyError> {
	const r = ptyWait(p.id, timeoutMs);
	if (r == -2) { return Result.err(PtyError.WaitFailed); }
	if (r < 0) { return Result.err(PtyError.Closed); }
	return Result.ok(r == 1);
}

export function write(this p: NativePty, data: Span<uint8>): Result<int32, PtyError> {
	const n = ptyWrite(p.id, data);
	if (n < 0) { return Result.err(PtyError.Closed); }
	return Result.ok(n as int32);
}

export function resize(this p: NativePty, cols: int32, rows: int32): Result<NativePty, PtyError> {
	if (ptyResize(p.id, cols, rows) != 0) { return Result.err(PtyError.ResizeFailed); }
	return Result.ok(p);
}

export function exitCode(this p: NativePty): int32 | null {
	if (ptyExited(p.id) == 0) { return null; }
	return ptyExitCode(p.id);
}

export function close(this p: NativePty): void {
	ptyClose(p.id);
}

export function toPty(this p: NativePty): Pty {
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
	this typeof NativePty,
	commandLine: string,
	cols: int32,
	rows: int32,
	cwd: string | null = null,
): Result<Pty, PtyError> {
	const opened = try NativePty.open(commandLine, cols, rows, cwd);
	return Result.ok(opened.toPty());
}

when (windows) {
	const ECHO_HELLO = "cmd.exe /c echo hello";
	const QUIET_FOR_3S = "cmd.exe /c ping -n 4 127.0.0.1 > nul";
	const MISSING_PROGRAM = "no-such-program-haro.exe";
	const ECHO_LINE_READ = "cmd.exe /v:on /c \"set /p line=& echo [!line!]\"";
	function printFile(path: string): string { return `cmd.exe /c type "${path.replaceAll("/", "\\")}"`; }
	const PRINT_DIRECTORY = "cmd.exe /c cd";
} else {
	const ECHO_HELLO = "echo hello";
	const QUIET_FOR_3S = "sleep 3";
	const MISSING_PROGRAM = "no-such-program-haro";
	const ECHO_LINE_READ = "sh -c 'read line; echo \"[$line]\"'";
	function printFile(path: string): string { return `cat "${path}"`; }
	const PRINT_DIRECTORY = "sh -c 'echo \"[$PWD]\"'";
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

function quietWaitMs(this p: NativePty, timeoutMs: int32): Result<float64, PtyError> {
	let buf: Vec<uint8> = new Array(4096);
	while (true) {
		const start: float64 = performance.now();
		const ready = try p.wait(timeoutMs);
		if (!ready) { return Result.ok(performance.now() - start); }
		const _read = try p.read(buf);
	}
}

test "a child's output reaches read and its exit ends the stream" {
	const opened = NativePty.open(ECHO_HELLO, 80, 24);
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
	const opened = NativePty.open(ECHO_HELLO, 80, 24);
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
	const opened = NativePty.open(QUIET_FOR_3S, 80, 24);
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
	const opened = NativePty.open(ECHO_HELLO, 80, 24);
	assert opened.ok;
	if (opened.ok) {
		const resized = opened.value.resize(120, 40);
		assert resized.ok;
		if (resized.ok) { assert resized.value.id == opened.value.id; }
		opened.value.close();
	}
}

test "a command that cannot start is an error" {
	const opened = NativePty.open(MISSING_PROGRAM, 80, 24);
	assert !opened.ok;
}

test "a native pty starts its command in the directory it is given" {
	const dir = tmpDir().replaceAll("\\", "/");
	const spawned = NativePty.spawn(PRINT_DIRECTORY, 80, 24, dir);
	assert spawned.ok;
	if (spawned.ok) {
		const out = spawned.value.drain().replaceAll("\\", "/");
		when (windows) {
			assert out.toLowerCase().includes(dir.toLowerCase());
		} else {
			assert out.includes(`[${dir}]`);
		}
		spawned.value.close();
	}
}

when (!windows) {
	test "a directory that does not exist is skipped and the command still runs, as Alacritty and Ghostty do" {
		const spawned = NativePty.spawn(ECHO_HELLO, 80, 24, "/no/such/haro/directory");
		assert spawned.ok;
		if (spawned.ok) {
			assert spawned.value.drain().includes("hello");
			spawned.value.close();
		}
	}
}

test "a native pty spawned as a Pty reads its output and reports its exit through the interface" {
	const spawned = NativePty.spawn(ECHO_HELLO, 80, 24);
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

test "a resize through the Pty interface reaches a live native pty" {
	const spawned = NativePty.spawn(QUIET_FOR_3S, 80, 24);
	assert spawned.ok;
	if (spawned.ok) {
		const pty = spawned.value;
		assert pty.resize(100, 30).ok;
		pty.close();
	}
}

test "a write to a child that does not read its input returns at once" {
	const opened = NativePty.open(QUIET_FOR_3S, 80, 24);
	assert opened.ok;
	if (opened.ok) {
		const p = opened.value;
		let chunk: Vec<uint8> = new Array(1048576);
		for (let i = 0; i < chunk.length; i++) { chunk[i] = 97 + (i % 26) as uint8; }
		const start: float64 = performance.now();
		for (let i = 0; i < 4; i++) { assert p.write(chunk[0..chunk.length]).ok; }
		assert performance.now() - start < 200;
		p.close();
	}
}

test "a line written to the child reaches it" {
	const opened = NativePty.open(ECHO_LINE_READ, 80, 24);
	assert opened.ok;
	if (opened.ok) {
		const p = opened.value;
		let line: Vec<uint8> = [0x68, 0x69, 0x0D];
		assert p.write(line[0..line.length]).ok;
		assert p.toPty().drain().includes("[hi]");
		p.close();
	}
}

struct LineCheck { next: int32; digits: string; inNumber: boolean; inCsi: boolean; bytes: int64; }

function feed(this before: LineCheck, bytes: Span<uint8>): LineCheck {
	let c = before;
	c.bytes += bytes.length;
	for (const b of bytes) {
		if (c.inCsi) {
			c.inCsi = b < 0x40 || b > 0x7E || b == 0x5B;
		} else if (b == 0x1B) {
			c.inCsi = true;
		} else if (b == 0x4C) {
			c.inNumber = true;
			c.digits = "";
		} else if (c.inNumber && b >= 0x30 && b <= 0x39) {
			c.digits += String.fromCharCode(b as int32);
		} else if (c.inNumber) {
			if (b == 0x2E && c.digits == `${c.next}`) { c.next++; }
			c.inNumber = false;
		}
	}
	return c;
}

test "the flood check counts a line ended by a cursor move, not a newline, and skips escapes inside it" {
	let check: LineCheck = { next: 0, digits: "", inNumber: false, inCsi: false, bytes: 0 };
	const text = "\x1b]0;cmd\x07line L0.\x1b[2;1Hline\x1b[1CL1.\x1b[K\r\nline L3.\r\nline L2.\r\n";
	const view = text.asBytes();
	let bytes: Vec<uint8> = new Array(view.length);
	for (let i = 0; i < view.length; i++) { bytes[i] = view[i]; }
	check = check.feed(bytes[0..bytes.length]);
	assert check.next == 3;
}

test "output past the read buffer's limit arrives whole and in order while the app reads late" {
	const path = `${tmpDir()}/haroPtyFlood.txt`;
	let text = "";
	const count = 400000;
	for (let i = 0; i < count; i++) { text += `line L${i}.\r\n`; }
	text += "end";
	assert writeFile(path, text).ok;
	const opened = NativePty.open(printFile(path), 80, 24);
	assert opened.ok;
	if (opened.ok) {
		const p = opened.value;
		const late: float64 = performance.now();
		while (performance.now() - late < 1500) {}
		let buf: Vec<uint8> = new Array(65536);
		let check: LineCheck = { next: 0, digits: "", inNumber: false, inCsi: false, bytes: 0 };
		while (true) {
			const ready = p.wait(10000);
			if (!ready.ok || !ready.value) { break; }
			const r = p.read(buf);
			if (!r.ok) { break; }
			check = check.feed(buf[0..r.value]);
		}
		console.log(`flood: ${check.bytes} bytes, ${check.next} of ${count} lines in order`);
		assert check.bytes > 4194304;
		assert check.next == count;
		p.close();
	}
	const _gone = remove(path);
}
