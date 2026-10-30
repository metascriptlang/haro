import { Pty, PtyError } from "../pty/transport";
import { Vt } from "../vt/vt";

export enum SessionError {
	PtyReadFailed,
	PtyWriteFailed,
	PtyBacklogged,
	VtCreateFailed,
	VtReadFailed,
	ResizeFailed,
}

export struct Session {
	pty: Pty;
	vt: Vt;
}

export function start(
	this typeof Session,
	pty: Pty,
	cols: int32,
	rows: int32,
	cellWidth: int32 = 0,
	cellHeight: int32 = 0,
): Result<Session, SessionError> {
	const vt = Vt.create(cols, rows);
	if (!vt.ok) {
		pty.close();
		return Result.err(SessionError.VtCreateFailed);
	}
	const pullFailed = pty.ownsScreen && !vt.value.setPullScrollback(false).ok;
	if (pullFailed || !vt.value.resize(cols, rows, cellWidth, cellHeight).ok) {
		vt.value.free();
		pty.close();
		return Result.err(SessionError.VtCreateFailed);
	}
	return Result.ok({ pty: pty, vt: vt.value });
}

export function pump(this s: Session, buf: Span<uint8>): Result<boolean, SessionError> {
	const r = s.pty.read(buf);
	if (!r.ok) {
		if (r.error == PtyError.Closed) { return Result.ok(false); }
		return Result.err(SessionError.PtyReadFailed);
	}
	if (r.value > 0) {
		s.vt.write(buf[0..r.value]);
		try s.sendReplies();
	}
	return Result.ok(true);
}

export function sendReplies(this s: Session): Result<void, SessionError> {
	const replies = s.vt.pendingReplies();
	if (replies.length == 0) { return Result.ok(null); }
	try s.send(replies);
	s.vt.dropReplies();
	return Result.ok(null);
}

export function send(this s: Session, data: Readonly<Span<uint8>>): Result<void, SessionError> {
	const wrote = s.pty.write(data);
	if (wrote.ok || s.pty.exitCode() !== null) { return Result.ok(null); }
	if (wrote.error == PtyError.Backlogged) { return Result.err(SessionError.PtyBacklogged); }
	return Result.err(SessionError.PtyWriteFailed);
}

export function resize(
	this s: Session,
	cols: int32,
	rows: int32,
	cellWidth: int32 = 0,
	cellHeight: int32 = 0,
): Result<void, SessionError> {
	const resizedVt = s.vt.resize(cols, rows, cellWidth, cellHeight);
	if (!resizedVt.ok) { return Result.err(SessionError.ResizeFailed); }
	const resizedPty = s.pty.resize(cols, rows, cellWidth, cellHeight);
	if (!resizedPty.ok && s.pty.exitCode() === null) {
		return Result.err(SessionError.ResizeFailed);
	}
	return s.sendReplies();
}

export function close(this s: Session): void {
	s.pty.close();
	s.vt.free();
}
