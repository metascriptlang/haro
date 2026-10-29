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
import { ShellLaunch, bashMajorOf, launchOf } from "./shellIntegration";
import { Pty, PtyError } from "./transport";
import {
	ptyClose,
	ptyExitCode,
	ptyExited,
	ptyResize,
	ptyWait,
} from "./nativePty.h";

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
extern function ptyWrite(id: int32, data: Readonly<Span<uint8>>): int64;

when (!windows) {
	import { env } from "std/process";
	import { ptyChildPid, ptyExitSignal, ptyMaster } from "./nativePty.h";

	extern function ptyEnviron(): Ptr<Ptr<char>>;

	@include("unistd.h");

	extern function tcgetpgrp(fd: int32): int32;
}

export struct NativePty { id: int32; }

function launchIn(commandLine: string, shellScripts: string | null): ShellLaunch {
	when (!windows) {
		if (shellScripts !== null) {
			const inherited = (name: string): string => { return env.get(name); };
			return launchOf(commandLine, shellScripts, inherited, bashMajorOf);
		}
	}
	return { commandLine: commandLine, env: [] };
}

const REPLACED_NAMES: string[] = [
	"TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "VTE_VERSION",
];
const ADDED_ENTRIES: string[] = ["TERM=xterm-256color", "COLORTERM=truecolor", "TERM_PROGRAM=Haro"];

function nameOf(entry: string): string {
	const eq = entry.indexOf("=");
	return eq < 0 ? entry : entry.slice(0, eq);
}

export function mergedEnv(inherited: Vec<string>, given: Vec<string>, cwd: string): Vec<string> {
	const givenNames = given.map(nameOf);
	const kept = inherited.filter((entry: string): boolean => {
		const name = nameOf(entry);
		return !(cwd != "" && name == "PWD") &&
			!REPLACED_NAMES.includes(name) &&
			!givenNames.includes(name);
	});
	let merged: Vec<string> = [...kept, ...ADDED_ENTRIES, ...given];
	if (cwd != "") { merged.push(`PWD=${cwd}`); }
	return merged;
}

when (!windows) {
	function inheritedEnv(): Vec<string> {
		const vars = ptyEnviron();
		let entries: Vec<string> = [];
		for (let i = 0; vars[i] != null; i++) {
			const entry: cstring = vars[i] as cstring;
			entries.push(entry as string);
		}
		return entries;
	}
}

function childEnv(given: Vec<string>, cwd: string): Vec<string> {
	when (windows) {
		return given;
	} else {
		return mergedEnv(inheritedEnv(), given, cwd);
	}
}

function envBlock(entries: Vec<string>): Vec<uint8> {
	let block: Vec<uint8> = [];
	for (const entry of entries) {
		block = [...block, ...entry.asBytes(), 0];
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
		envBlock(childEnv(launch.env, dir)),
		cols,
		rows,
		cols * cellWidth,
		rows * cellHeight,
	);
	if (id < 0) { return Result.err(openError(id)); }
	return Result.ok({ id: id });
}

const PTY_OPEN_TABLE_FULL: int32 = -1;
const PTY_OPEN_BLANK_COMMAND: int32 = -2;
const PTY_OPEN_BAD_ENV: int32 = -3;
const PTY_OPEN_FORK_FAILED: int32 = -5;
const PTY_OPEN_EXEC_FAILED: int32 = -6;
const PTY_OPEN_THREAD_FAILED: int32 = -7;

function openError(code: int32): PtyError {
	return match (code) {
		PTY_OPEN_TABLE_FULL => PtyError.OpenTableFull,
		PTY_OPEN_BLANK_COMMAND => PtyError.OpenBlankCommand,
		PTY_OPEN_BAD_ENV => PtyError.OpenBadEnv,
		PTY_OPEN_FORK_FAILED => PtyError.OpenForkFailed,
		PTY_OPEN_EXEC_FAILED => PtyError.OpenExecFailed,
		PTY_OPEN_THREAD_FAILED => PtyError.OpenThreadFailed,
		_ => PtyError.OpenFailed,
	};
}

const PTY_WAIT_FAILED: int32 = -2;
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
		PTY_WAIT_FAILED => Result.err(PtyError.WaitFailed),
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
