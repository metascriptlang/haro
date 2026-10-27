import { MouseButton } from "../../../mouseButton";
import { KeyAction, KeyEvent, modsMask, modsOf } from "../../../../keys/keys";
import { Spot } from "../../../../input/pointer";
import { MouseGeometry } from "../../../../vt/vt";
import { CellInk } from "../../../../grid/lines";
import { NativePty, spawn } from "../../../../pty/pty";
import { Replay, ofText, toPty } from "../../../../pty/replay";
import { Pty, PtyError } from "../../../../pty/transport";
import { FrameRows, none } from "../../../rows";
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

// The mods cross as masks until msc takes a BitSet as an actor argument:
// .inbox/compiler/2026-10-27-a-bitset-or-a-moved-match-union-is-refused-as-an-actor-argument.md
struct SentKey {
	action: KeyAction;
	key: string;
	mods: uint16;
	consumedMods: uint16;
	unshifted: uint32;
	text: string;
}

struct SentHit {
	at: Spot;
	x: float64;
	y: float64;
	scale: float64;
	mods: uint16;
	cell: MouseGeometry;
}

function sent(k: KeyEvent): SentKey {
	return { ...k, mods: modsMask(k.mods), consumedMods: modsMask(k.consumedMods) };
}

function keyOf(k: SentKey): KeyEvent {
	return { ...k, mods: modsOf(k.mods), consumedMods: modsOf(k.consumedMods) };
}

function sentHit(h: Hit): SentHit {
	return { ...h, mods: modsMask(h.mods) };
}

function hitOf(h: SentHit): Hit {
	return { ...h, mods: modsOf(h.mods) };
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
	key(k: SentKey, time: float64): void { this.io?.key(keyOf(k), time); }
	keyReleased(k: SentKey): void { this.io?.keyReleased(keyOf(k)); }
	text(typed: string, time: float64): void { this.io?.text(typed, time); }
	focus(gained: boolean): void { this.io?.focus(gained); }
	press(button: MouseButton, h: SentHit, time: float64): void { this.io?.press(button, hitOf(h), time); }
	move(h: SentHit, pressed: boolean): void { this.io?.move(hitOf(h), pressed); }
	release(button: MouseButton, h: SentHit): void { this.io?.release(button, hitOf(h)); }
	wheel(notches: float64, h: SentHit): void { this.io?.wheel(notches, hitOf(h)); }
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
		key: (k: KeyEvent, time: float64): void => { shell.key(sent(k), time); },
		keyReleased: (k: KeyEvent): void => { shell.keyReleased(sent(k)); },
		text: (typed: string, time: float64): void => { shell.text(typed, time); },
		focus: (gained: boolean): void => { shell.focus(gained); },
		press: (button: MouseButton, h: Hit, time: float64): void => { shell.press(button, sentHit(h), time); },
		move: (h: Hit, pressed: boolean): void => { shell.move(sentHit(h), pressed); },
		release: (button: MouseButton, h: Hit): void => { shell.release(button, sentHit(h)); },
		wheel: (notches: float64, h: Hit): void => { shell.wheel(notches, sentHit(h)); },
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
