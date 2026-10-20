export enum PtyError {
	OpenFailed,
	Closed,
	OutOfMemory,
	ResizeFailed,
	WaitFailed,
}

export interface Pty {
	wait: (timeoutMs: int32) => Result<boolean, PtyError>;
	read: (buf: Span<uint8>) => Result<int32, PtyError>;
	write: (data: Span<uint8>) => Result<int32, PtyError>;
	resize: (cols: int32, rows: int32) => Result<void, PtyError>;
	exitCode: () => int32 | null;
	close: () => void;
	ownsScreen: boolean;
}

export function drainText(this p: Pty, chunk: int32): string {
	let buf: Vec<uint8> = new Array(chunk);
	let text = "";
	while (true) {
		const ready = p.wait(10000);
		if (!ready.ok || !ready.value) { return text; }
		const r = p.read(buf);
		if (!r.ok) { return text; }
		for (let i = 0; i < r.value; i++) { text += String.fromCharCode(buf[i] as int32); }
	}
}
