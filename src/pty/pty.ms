@include("./nativePty.h");
when (windows) {
	@compile("./conpty.c");
} else {
	@compile("./posixPty.c");
}
when (linux) {
	@passL("-lutil");
}

import { isDir } from "std/fs";
import { langEntry } from "./locale";
import { ShellLaunch, launchOf } from "./shellIntegration";
import { Pty, PtyError } from "./transport";

extern function ptyOpen(
	commandLine: cstring,
	cwd: cstring,
	env: Readonly<Span<uint8>>,
	cols: int32,
	rows: int32,
	widthPx: int32,
	heightPx: int32,
): int32;
extern function ptyRead(id: int32, buf: Span<uint8>): int64;
extern function ptyWait(id: int32, timeoutMs: int32): int32;
extern function ptyWrite(id: int32, data: Readonly<Span<uint8>>): int64;
extern function ptyResize(
	id: int32,
	cols: int32,
	rows: int32,
	widthPx: int32,
	heightPx: int32,
): int32;
extern function ptyExited(id: int32): int32;
extern function ptyExitCode(id: int32): int32;
extern function ptyClose(id: int32): void;

when (!windows) {
	import { env } from "std/process";

	@include("unistd.h");

	extern function ptyMaster(id: int32): int32;
	extern function ptyChildPid(id: int32): int32;
	extern function ptyExitSignal(id: int32): int32;
	extern function tcgetpgrp(fd: int32): int32;
}

export struct NativePty { id: int32; }

function launchIn(commandLine: string, shellScripts: string | null): ShellLaunch {
	when (!windows) {
		if (shellScripts !== null) {
			const inherited = (name: string): string => { return env.get(name); };
			return launchOf(commandLine, shellScripts, inherited);
		}
	}
	return { commandLine: commandLine, env: [] };
}

function envBlock(entries: Vec<string>): Vec<uint8> {
	let block: Vec<uint8> = [];
	for (const entry of entries) {
		for (const b of entry.asBytes()) { block.push(b); }
		block.push(0);
	}
	return block;
}

export function open(
	this typeof NativePty,
	commandLine: string,
	cols: int32,
	rows: int32,
	cwd: string | null = null,
	cellWidth: int32 = 0,
	cellHeight: int32 = 0,
	shellScripts: string | null = null,
): Result<NativePty, PtyError> {
	const dir = cwd !== null && isDir(cwd) ? cwd : "";
	let launch = launchIn(commandLine, shellScripts);
	const lang = langEntry();
	if (lang != "") { launch.env.push(lang); }
	const id = ptyOpen(
		launch.commandLine,
		dir,
		envBlock(launch.env),
		cols,
		rows,
		cols * cellWidth,
		rows * cellHeight,
	);
	if (id < 0) { return Result.err(PtyError.OpenFailed); }
	return Result.ok({ id: id });
}

const PTY_OUT_OF_MEMORY: int64 = -2;
const PTY_BACKLOGGED: int64 = -3;

function transferred(n: int64): Result<int32, PtyError> {
	return match (n) {
		PTY_OUT_OF_MEMORY => Result.err(PtyError.OutOfMemory),
		PTY_BACKLOGGED => Result.err(PtyError.Backlogged),
		_ when n < 0 => Result.err(PtyError.Closed),
		_ => Result.ok(n as int32),
	};
}

export function read(this p: NativePty, buf: Span<uint8>): Result<int32, PtyError> {
	return transferred(ptyRead(p.id, buf));
}

export function wait(this p: NativePty, timeoutMs: int32): Result<boolean, PtyError> {
	const r = ptyWait(p.id, timeoutMs);
	return match (r) {
		-2 => Result.err(PtyError.WaitFailed),
		_ when r < 0 => Result.err(PtyError.Closed),
		_ => Result.ok(r == 1),
	};
}

export function write(this p: NativePty, data: Readonly<Span<uint8>>): Result<void, PtyError> {
	const sent = transferred(ptyWrite(p.id, data));
	if (!sent.ok) { return Result.err(sent.error); }
	return Result.ok(null);
}

export function resize(
	this p: NativePty,
	cols: int32,
	rows: int32,
	cellWidth: int32 = 0,
	cellHeight: int32 = 0,
): Result<void, PtyError> {
	if (ptyResize(p.id, cols, rows, cols * cellWidth, rows * cellHeight) != 0) {
		return Result.err(PtyError.ResizeFailed);
	}
	return Result.ok(null);
}

export function exitCode(this p: NativePty): int32 | null {
	if (ptyExited(p.id) == 0) { return null; }
	return ptyExitCode(p.id);
}

export function exitSignal(this p: NativePty): int32 {
	when (windows) {
		return 0;
	} else {
		if (ptyExited(p.id) == 0) { return 0; }
		return ptyExitSignal(p.id);
	}
}

export function close(this p: NativePty): void {
	ptyClose(p.id);
}

export function busy(this p: NativePty): boolean {
	when (windows) {
		return false;
	} else {
		if (ptyExited(p.id) != 0) { return false; }
		const group = tcgetpgrp(ptyMaster(p.id));
		return group > 0 && group != ptyChildPid(p.id);
	}
}

export function toPty(this p: NativePty): Pty {
	return {
		wait: (timeoutMs: int32): Result<boolean, PtyError> => { return p.wait(timeoutMs); },
		read: (buf: Span<uint8>): Result<int32, PtyError> => { return p.read(buf); },
		write: (data: Readonly<Span<uint8>>): Result<void, PtyError> => { return p.write(data); },
		resize: (
			cols: int32,
			rows: int32,
			cellWidth: int32,
			cellHeight: int32,
		): Result<void, PtyError> => {
			return p.resize(cols, rows, cellWidth, cellHeight);
		},
		exitCode: (): int32 | null => { return p.exitCode(); },
		exitSignal: (): int32 => { return p.exitSignal(); },
		close: (): void => { p.close(); },
		busy: (): boolean => { return p.busy(); },
		ownsScreen: true,
	};
}

export function spawn(
	this typeof NativePty,
	commandLine: string,
	cols: int32,
	rows: int32,
	cwd: string | null = null,
	cellWidth: int32 = 0,
	cellHeight: int32 = 0,
	shellScripts: string | null = null,
): Result<Pty, PtyError> {
	const opened = try NativePty.open(
		commandLine,
		cols,
		rows,
		cwd,
		cellWidth,
		cellHeight,
		shellScripts,
	);
	return Result.ok(opened.toPty());
}
