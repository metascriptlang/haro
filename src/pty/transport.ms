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
	write: (data: Readonly<Span<uint8>>) => Result<int32, PtyError>;
	resize: (cols: int32, rows: int32, cellWidth: int32, cellHeight: int32) => Result<void, PtyError>;
	exitCode: () => int32 | null;
	exitSignal: () => int32;
	close: () => void;
	busy: () => boolean;
	ownsScreen: boolean;
}
