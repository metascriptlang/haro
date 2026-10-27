import { MouseButton } from "./mouseButton";
import { KeyEvent } from "../keys/keys";
import { CellInk } from "../grid/lines";
import { NativePty, spawn } from "../pty/pty";
import { Replay, ofText, toPty } from "../pty/replay";
import { Pty, PtyError } from "../pty/transport";
import { FrameRows, none } from "./rows";
import { Hit } from "./controls";
import {
	Io,
	IoFrame,
	IoPort,
	Settings,
	autoscroll,
	cancelDialog,
	closeKey,
	configure,
	confirmDialog,
	drain,
	fit,
	focus,
	frame,
	key,
	keyReleased,
	move,
	open,
	pasted,
	press,
	release,
	relight,
	shutdown,
	text,
	wheel,
} from "./io";
import { OpenPty, TermError, openTerm } from "./term";

export struct PtySpec {
	command: string;
	cwd: string | null;
	recording: string | null;
}

function openerOf(spec: PtySpec): OpenPty {
	const recording = spec.recording;
	if (recording !== null) {
		const replay = Replay.ofText(recording);
		return (cols: int32, rows: int32): Result<Pty, PtyError> => {
			return Result.ok(replay.toPty());
		};
	}
	const command = spec.command;
	const cwd = spec.cwd;
	return (cols: int32, rows: int32, cellWidth: int32, cellHeight: int32): Result<Pty, PtyError> => {
		return NativePty.spawn(command, cols, rows, cwd, cellWidth, cellHeight);
	};
}

export actor Shell {
	private io: Io | null = null;
	private refused: TermError | null = null;

	constructor(spec: PtySpec) {
		const opened = openTerm(openerOf(spec));
		if (opened.ok) {
			this.io = Io.open(opened.value);
		} else {
			this.refused = opened.error;
		}
	}

	openError(): TermError | null { return this.refused; }
	configure(settings: Settings): void { this.io?.configure(settings); }
	fit(cols: int32, rows: int32, cellWidth: int32, cellHeight: int32): void {
		this.io?.fit(cols, rows, cellWidth, cellHeight);
	}
	drain(): void { this.io?.drain(); }
	key(k: KeyEvent, time: float64): void { this.io?.key(k, time); }
	keyReleased(k: KeyEvent): void { this.io?.keyReleased(k); }
	text(typed: string, time: float64): void { this.io?.text(typed, time); }
	focus(gained: boolean): void { this.io?.focus(gained); }
	press(button: MouseButton, h: Hit, time: float64): void { this.io?.press(button, h, time); }
	move(h: Hit, pressed: boolean): void { this.io?.move(h, pressed); }
	release(button: MouseButton, h: Hit): void { this.io?.release(button, h); }
	wheel(notches: float64, h: Hit): void { this.io?.wheel(notches, h); }
	autoscroll(): void { this.io?.autoscroll(); }
	closeKey(): void { this.io?.closeKey(); }
	confirmDialog(): void { this.io?.confirmDialog(); }
	cancelDialog(): void { this.io?.cancelDialog(); }
	pasted(clipboard: string): void { this.io?.pasted(clipboard); }

	frame(): IoFrame | null {
		const io = this.io;
		if (io === null) { return null; }
		let got = io.frame();
		return move got;
	}

	relight(ink: CellInk | null): FrameRows {
		const io = this.io;
		if (io === null) { return FrameRows.none(); }
		let got = io.relight(ink);
		return move got;
	}

	shutdown(): boolean {
		const io = this.io;
		if (io === null) { return false; }
		io.shutdown();
		this.io = null;
		return true;
	}
}

async function framed(shell: Shell, done: (got: IoFrame) => void): Promise<void> {
	const got = await shell.frame();
	if (got !== null) { done(got); }
}

async function relit(shell: Shell, ink: CellInk | null, done: (rows: FrameRows) => void): Promise<void> {
	done(await shell.relight(ink));
}

export async function closed(shell: Shell): Promise<void> {
	const _closed = await shell.shutdown();
}

export async function closeThen(shell: Shell, then: () => void): Promise<void> {
	await closed(shell);
	then();
}

export async function opened(shell: Shell): Promise<TermError | null> {
	return await shell.openError();
}

export function portOf(shell: Shell): IoPort {
	return {
		configure: (settings: Settings): void => { shell.configure(settings); },
		fit: (cols: int32, rows: int32, cellWidth: int32, cellHeight: int32): void => {
			shell.fit(cols, rows, cellWidth, cellHeight);
		},
		drain: (): void => { shell.drain(); },
		key: (k: KeyEvent, time: float64): void => { shell.key(k, time); },
		keyReleased: (k: KeyEvent): void => { shell.keyReleased(k); },
		text: (typed: string, time: float64): void => { shell.text(typed, time); },
		focus: (gained: boolean): void => { shell.focus(gained); },
		press: (button: MouseButton, h: Hit, time: float64): void => { shell.press(button, h, time); },
		move: (h: Hit, pressed: boolean): void => { shell.move(h, pressed); },
		release: (button: MouseButton, h: Hit): void => { shell.release(button, h); },
		wheel: (notches: float64, h: Hit): void => { shell.wheel(notches, h); },
		autoscroll: (): void => { shell.autoscroll(); },
		closeKey: (): void => { shell.closeKey(); },
		confirmDialog: (): void => { shell.confirmDialog(); },
		cancelDialog: (): void => { shell.cancelDialog(); },
		pasted: (clipboard: string): void => { shell.pasted(clipboard); },
		frame: (done: (got: IoFrame) => void): void => { const _framed = framed(shell, done); },
		relight: (ink: CellInk | null, done: (rows: FrameRows) => void): void => {
			const _relit = relit(shell, ink, done);
		},
	};
}
