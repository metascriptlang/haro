import { MouseButton } from "./mouseButton";
import { KeyEvent } from "../keys/keys";
import { CellInk } from "../grid/lines";
import { NativePty, spawn } from "../pty/pty";
import { Replay, ofText, toPty } from "../pty/replay";
import { Pty, PtyError } from "../pty/transport";
import { RemotePty, Seed, asPty, dropInbound, empty, feed, takeTyped } from "../pty/remote";
import { reseeded } from "../session/session";
import { nativeSnapshot, snapshot } from "../vt/snapshot";
import { Annotation, Decoration, FrameRows, none } from "./rows";
import { Action } from "../input/bindings";
import { Hit, vtOf } from "./controls";
import { nativeSnapshot, pwd, snapshot, title } from "../vt/vt";
import { fileUri, isLocalHost } from "../term/pwd";
import { isDir } from "std/fs";
import { hostname } from "std/os";
import {
	Drained,
	Io,
	IoFrame,
	IoPort,
	Settings,
	Where,
	act,
	annotate,
	autoscroll,
	cancelDialog,
	closeKey,
	compress,
	closeWindow,
	configure,
	confirmDialog,
	decorate,
	drain,
	drainOutput,
	fit,
	settleSize,
	focus,
	frame,
	key,
	outOfOrder,
	keyReleased,
	move,
	open,
	pasted,
	press,
	release,
	relight,
	shutdown,
	text,
	unannotate,
	undecorate,
	wheel,
	write,
} from "./io";
import { OpenPty, Tee, TermError, busy, fresh, openTerm } from "./term";

export struct PtySpec {
	command: string;
	cwd: string | null;
	recording: string | null;
	shellScripts: string | null;
}

function openerOf(this spec: PtySpec): OpenPty {
	const recording = spec.recording;
	if (recording !== null) {
		const replay = Replay.ofText(recording);
		return (cols: int32, rows: int32): Result<Pty, PtyError> => {
			return Result.ok(replay.toPty());
		};
	}
	const command = spec.command;
	const cwd = spec.cwd;
	const scripts = spec.shellScripts;
	return (
		cols: int32,
		rows: int32,
		cellWidth: int32,
		cellHeight: int32,
	): Result<Pty, PtyError> => {
		return NativePty.spawn(command, cols, rows, cwd, cellWidth, cellHeight, scripts);
	};
}

function openerOf(this remote: RemotePty): OpenPty {
	return (cols: int32, rows: int32): Result<Pty, PtyError> => {
		return Result.ok(remote.asPty());
	};
}

export actor Shell {
	private io: Io | null = null;
	private refused: TermError | null = null;
	private remote: RemotePty | null = null;

	constructor(spec: PtySpec, teed: boolean = false, seed: Seed | null = null) {
		const remote = seed === null ? null : RemotePty.empty();
		const opened = openTerm(remote === null ? spec.openerOf() : remote.openerOf());
		if (opened.ok) {
			if (teed) { opened.value.tee = Tee.fresh(); }
			opened.value.seed = seed;
			this.io = Io.open(opened.value);
			this.remote = remote;
		} else {
			this.refused = opened.error;
		}
	}

	openError(): TermError | null { return this.refused; }
	configure(settings: Settings): void { this.io?.configure(settings); }
	fit(cols: int32, rows: int32, cellWidth: int32, cellHeight: int32): void {
		this.io?.fit(cols, rows, cellWidth, cellHeight);
	}
	settleSize(): void { this.io?.settleSize(); }
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
	act(action: Action): void { this.io?.act(action); }
	closeKey(): void { this.io?.closeKey(); }
	closeWindow(): void { this.io?.closeWindow(); }
	confirmDialog(): void { this.io?.confirmDialog(); }
	cancelDialog(): void { this.io?.cancelDialog(); }
	pasted(clipboard: string): void { this.io?.pasted(clipboard); }
	decorate(d: Decoration): void { this.io?.decorate(d); }
	undecorate(id: int32): void { this.io?.undecorate(id); }
	annotate(a: Annotation): void { this.io?.annotate(a); }
	unannotate(id: int32): void { this.io?.unannotate(id); }
	write(bytes: Vec<uint8>): void { this.io?.write(bytes); }

	feed(first: uint64, last: uint64, bytes: Vec<uint8>): void {
		const remote = this.remote;
		const io = this.io;
		if (remote === null || io === null) { return; }
		if (!remote.feed(first, last, bytes)) { io.outOfOrder(); }
	}

	reseed(seed: Seed): void {
		const remote = this.remote;
		const io = this.io;
		if (remote === null || io === null) { return; }
		remote.dropInbound();
		const t = io.term;
		const s = t.session;
		if (s === null) {
			t.seed = seed;
			return;
		}
		const next = s.reseeded(seed, t.cols, t.rows, t.cellWidth, t.cellHeight);
		if (!next.ok) {
			io.failures.push({ where: Where.Output, error: TermError.VtFailed, started: true });
			return;
		}
		t.session = next.value;
		const settings = io.settings;
		if (settings !== null) { io.configure(settings); }
	}

	typed(): Vec<uint8> {
		const remote = this.remote;
		if (remote === null) { return []; }
		let got = remote.takeTyped();
		return move got;
	}

	keyTyped(k: KeyEvent, time: float64): Vec<uint8> {
		this.io?.key(k, time);
		const remote = this.remote;
		if (remote === null) { return []; }
		let got = remote.takeTyped();
		return move got;
	}

	textTyped(typed: string, time: float64): Vec<uint8> {
		this.io?.text(typed, time);
		const remote = this.remote;
		if (remote === null) { return []; }
		let got = remote.takeTyped();
		return move got;
	}

	output(): Drained | null {
		const io = this.io;
		if (io === null) { return null; }
		let got = io.drainOutput();
		return move got;
	}

	title(): string | null {
		const io = this.io;
		if (io === null) { return null; }
		const vt = io.term.vtOf();
		if (vt === null) { return null; }
		const got = vt.title();
		return got.ok ? got.value : null;
	}

	snapshot(native: boolean = false): Vec<uint8> | null {
		const io = this.io;
		if (io === null) { return null; }
		const vt = io.term.vtOf();
		if (vt === null) { return null; }
		let got = native ? vt.nativeSnapshot() : vt.snapshot();
		if (!got.ok) { return null; }
		return move got.value;
	}

	frame(): IoFrame | null {
		const io = this.io;
		if (io === null) { return null; }
		let got = io.frame();
		return move got;
	}

	compress(): number | null {
		const io = this.io;
		if (io === null) { return null; }
		return io.compress();
	}

	relight(ink: CellInk | null): FrameRows {
		const io = this.io;
		if (io === null) { return FrameRows.none(); }
		let got = io.relight(ink);
		return move got;
	}

	busy(): boolean {
		const io = this.io;
		return io !== null && io.term.busy();
	}

	pwd(): string | null {
		const io = this.io;
		if (io === null) { return null; }
		const vt = io.term.vtOf();
		if (vt === null) { return null; }
		const got = vt.pwd();
		return got.ok && got.value != "" ? got.value : null;
	}

	shutdown(): boolean {
		const io = this.io;
		if (io === null) { return false; }
		io.shutdown();
		this.io = null;
		return true;
	}
}

function framed(
	shell: Shell,
	done: (got: IoFrame) => void,
	failed: (error: string) => void,
): void {
	shell.frame().then((got: IoFrame | null): void => {
		if (got !== null) { done(got); }
	}).catch((e: Error): void => { failed(`${e}`); });
}

function compressed(
	shell: Shell,
	done: (nextMs: number | null) => void,
	failed: (error: string) => void,
): void {
	shell.compress().then(done).catch((e: Error): void => { failed(`${e}`); });
}

function relit(
	shell: Shell,
	ink: CellInk | null,
	done: (rows: FrameRows) => void,
	failed: (error: string) => void,
): void {
	shell.relight(ink).then(done).catch((e: Error): void => { failed(`${e}`); });
}

export async function closed(shell: Shell): Promise<void> {
	await shell.shutdown();
}

export async function closeThen(shell: Shell, then: () => void): Promise<void> {
	await closed(shell);
	then();
}

export async function localCwd(shell: Shell): Promise<string | null> {
	const uri = await shell.pwd();
	if (uri === null) { return null; }
	const parsed = fileUri(uri);
	if (!parsed.ok || !isLocalHost(parsed.value.host, hostname())) { return null; }
	return isDir(parsed.value.path) ? parsed.value.path : null;
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
		settleSize: (): void => { shell.settleSize(); },
		drain: (): void => { shell.drain(); },
		key: (k: KeyEvent, time: float64): void => { shell.key(k, time); },
		keyReleased: (k: KeyEvent): void => { shell.keyReleased(k); },
		text: (typed: string, time: float64): void => { shell.text(typed, time); },
		focus: (gained: boolean): void => { shell.focus(gained); },
		press: (button: MouseButton, h: Hit, time: float64): void => {
			shell.press(button, h, time);
		},
		move: (h: Hit, pressed: boolean): void => { shell.move(h, pressed); },
		release: (button: MouseButton, h: Hit): void => { shell.release(button, h); },
		wheel: (notches: float64, h: Hit): void => { shell.wheel(notches, h); },
		autoscroll: (): void => { shell.autoscroll(); },
		act: (action: Action): void => { shell.act(action); },
		closeKey: (): void => { shell.closeKey(); },
		closeWindow: (): void => { shell.closeWindow(); },
		confirmDialog: (): void => { shell.confirmDialog(); },
		cancelDialog: (): void => { shell.cancelDialog(); },
		pasted: (clipboard: string): void => { shell.pasted(clipboard); },
		decorate: (d: Decoration): void => { shell.decorate(d); },
		undecorate: (id: int32): void => { shell.undecorate(id); },
		annotate: (a: Annotation): void => { shell.annotate(a); },
		unannotate: (id: int32): void => { shell.unannotate(id); },
		compress: (done: (nextMs: number | null) => void, failed: (error: string) => void): void => {
			compressed(shell, done, failed);
		},
		frame: (done: (got: IoFrame) => void, failed: (error: string) => void): void => {
			framed(shell, done, failed);
		},
		relight: (
			ink: CellInk | null,
			done: (rows: FrameRows) => void,
			failed: (error: string) => void,
		): void => {
			relit(shell, ink, done, failed);
		},
	};
}
