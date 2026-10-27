import { Pty, PtyError } from "./transport";

export struct Replay { bytes: Vec<uint8>; }

export function ofText(this typeof Replay, text: string): Replay {
	return { bytes: [...text.asBytes()] };
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
			const n = Math.min(total - at, buf.length as int32);
			for (let i = 0; i < n; i++) { buf[i] = bytes[at + i]; }
			at += n;
			return Result.ok(n);
		},
		write: (data: Readonly<Span<uint8>>): Result<int32, PtyError> => {
			if (closed) { return Result.err(PtyError.Closed); }
			return Result.ok(data.length as int32);
		},
		resize: (
			cols: int32,
			rows: int32,
			cellWidth: int32,
			cellHeight: int32,
		): Result<void, PtyError> => {
			if (closed) { return Result.err(PtyError.Closed); }
			return Result.ok(null);
		},
		exitCode: (): int32 | null => { return at >= total ? 0 : null; },
		exitSignal: (): int32 => { return 0; },
		close: (): void => { closed = true; },
		busy: (): boolean => { return false; },
		ownsScreen: false,
	};
}
