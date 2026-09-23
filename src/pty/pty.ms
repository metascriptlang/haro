@include("./conpty.h");
@compile("./conpty.c");

extern function ptyOpen(commandLine: cstring, cols: int32, rows: int32): int32;
extern function ptyRead(id: int32, buf: Span<uint8>): int64;
extern function ptyWrite(id: int32, data: Span<uint8>): int64;
extern function ptyResize(id: int32, cols: int32, rows: int32): int32;
extern function ptyExitCode(id: int32): int32;
extern function ptyClose(id: int32): void;

export enum PtyError {
	OpenFailed,
	Closed,
	OutOfMemory,
}

export struct Pty { id: int32; }

export function open(this typeof Pty, commandLine: string, cols: int32, rows: int32): Result<Pty, PtyError> {
	const id = ptyOpen(commandLine, cols, rows);
	if (id < 0) { return Result.err(PtyError.OpenFailed); }
	return Result.ok({ id: id });
}

export function read(this p: Pty, buf: Span<uint8>): Result<int64, PtyError> {
	const n = ptyRead(p.id, buf);
	if (n == -2) { return Result.err(PtyError.OutOfMemory); }
	if (n < 0) { return Result.err(PtyError.Closed); }
	return Result.ok(n);
}

export function write(this p: Pty, data: Span<uint8>): Result<int64, PtyError> {
	const n = ptyWrite(p.id, data);
	if (n < 0) { return Result.err(PtyError.Closed); }
	return Result.ok(n);
}

export function resize(this p: Pty, cols: int32, rows: int32): boolean {
	return ptyResize(p.id, cols, rows) == 0;
}

export function exitCode(this p: Pty): int32 {
	return ptyExitCode(p.id);
}

export function close(this p: Pty): void {
	ptyClose(p.id);
}

function drain(p: Pty): string {
	const buf: Vec<uint8> = new Array(4096);
	let text = "";
	for (let spin = 0; spin < 50000000; spin++) {
		const r = p.read(buf);
		if (!r.ok) { return text; }
		for (let i = 0; i < (r.value as int32); i++) {
			text += String.fromCharCode(buf[i] as int32);
		}
	}
	return text;
}

test "a ConPTY child's output reaches read and its exit ends the stream" {
	const opened = Pty.open("cmd.exe /c echo hello", 80, 24);
	assert opened.ok;
	if (opened.ok) {
		const p = opened.value;
		const text = drain(p);
		assert text.includes("hello");
		assert p.exitCode() == 0;
		p.close();
	}
}

test "a command that cannot start is an error" {
	const opened = Pty.open("no-such-program-terminator.exe", 80, 24);
	assert !opened.ok;
}
