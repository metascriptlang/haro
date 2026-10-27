import { MouseButton } from "../../../mouseButton";
import { Rgb, setDefaultColors, setPalette, setScrollback } from "../../../../vt/vt";
import { Keybind } from "../../../../input/bindings";
import { Reply } from "../../../../input/paste";
import { Pending, pendingOf } from "../../../pending";
import { KeyEvent, OptionAsAlt } from "../../../../keys/keys";
import { CellInk } from "../../../../grid/lines";
import { Config } from "../../../../config/config";
import { FrameRows, none } from "../../../rows";
import { Mark } from "../../../mark";
import { Asks, Controls, Hit, holding, refit, takeAsks, typed, vtOf } from "./controls";
import { cancel, clipboardAsked, clipboardText, confirm } from "./clipboard";
import { answerClose, closeKey, keyDown, keyUp } from "./keyboard";
import { autoscrollTick, endDrag, pointerDown, pointerMove, pointerUp, roll, syncSelection } from "./mouse";
import {
	Frame,
	Term,
	TermError,
	exitedAbnormally,
	drain,
	inkCursor,
	pumpFrame,
	releaseHeldKey,
	sendFocus,
	sendKey,
	sendText,
	shellExitCode,
	shellExitSignal,
	shutdown,
} from "./term";

export struct Settings {
	foreground: Rgb;
	background: Rgb;
	palette: Vec<Rgb>;
	scrollback: int64;
	keybinds: Vec<Keybind>;
	optionAsAlt: OptionAsAlt;
}

export function settingsOf(c: Config): Settings {
	return {
		foreground: c.foreground,
		background: c.background,
		palette: c.palette,
		scrollback: c.scrollback,
		keybinds: c.keybinds,
		optionAsAlt: c.optionAsAlt,
	};
}

export struct Failure {
	what: string;
	error: TermError;
	started: boolean;
}

export struct Exit {
	code: int32;
	signal: int32;
	abnormal: boolean;
}

export struct IoFrame {
	frame: Frame | null;
	asks: Asks;
	pending: Pending;
	exit: Exit | null;
	autoscroll: boolean;
	again: boolean;
	started: boolean;
	failures: Vec<Failure>;
	keyAt: float64;
	marks: Vec<Mark>;
}

export interface Io {
	term: Term;
	controls: Controls;
	settings: Settings | null;
	failures: Vec<Failure>;
	keyAt: float64;
}

export interface IoPort {
	configure: (settings: Settings) => void;
	fit: (cols: int32, rows: int32, cellWidth: int32, cellHeight: int32) => void;
	drain: () => void;
	key: (k: KeyEvent, time: float64) => void;
	keyReleased: (k: KeyEvent) => void;
	text: (typed: string, time: float64) => void;
	focus: (gained: boolean) => void;
	press: (button: MouseButton, h: Hit, time: float64) => void;
	move: (h: Hit, pressed: boolean) => void;
	release: (button: MouseButton, h: Hit) => void;
	wheel: (notches: float64, h: Hit) => void;
	autoscroll: () => void;
	closeKey: () => void;
	confirmDialog: () => void;
	cancelDialog: () => void;
	pasted: (clipboard: string) => void;
	frame: (done: (got: IoFrame) => void) => void;
	relight: (ink: CellInk | null, done: (rows: FrameRows) => void) => void;
}

export function open(this typeof Io, t: Term): Io {
	return { term: t, controls: Controls.open(), settings: null, failures: [], keyAt: -1 };
}

export function started(this io: Io): boolean {
	return io.term.session !== null;
}

function fail(this io: Io, what: string, error: TermError): void {
	io.failures.push({ what: what, error: error, started: io.started() });
}

function check(this io: Io, what: string, r: Result<boolean, TermError>): void {
	if (!r.ok) { io.fail(what, r.error); }
}

function apply(this io: Io): void {
	const s = io.term.session;
	const settings = io.settings;
	if (s === null || settings === null) { return; }
	const vt = s.vt;
	if (!vt.setDefaultColors(settings.foreground, settings.background).ok ||
		!vt.setPalette(settings.palette).ok ||
		!vt.setScrollback(settings.scrollback).ok) {
		io.fail("settings", TermError.SettingsRefused);
	}
}

export function configure(this io: Io, settings: Settings): void {
	io.settings = settings;
	io.controls.keybinds = settings.keybinds;
	io.term.keys.optionAsAlt = settings.optionAsAlt;
	io.apply();
}

export function fit(this io: Io, cols: int32, rows: int32, cellWidth: int32, cellHeight: int32): void {
	const started = io.term.session !== null;
	const fitted = io.controls.refit(io.term, cols, rows, cellWidth, cellHeight);
	if (!fitted.ok) {
		io.fail("fit", fitted.error);
		return;
	}
	if (!started) { io.apply(); }
}

function input(this io: Io, sent: Result<int32, TermError>, what: string, time: float64): void {
	if (!sent.ok) {
		io.fail(what, sent.error);
		return;
	}
	if (sent.value == 0) { return; }
	if (io.keyAt < 0) { io.keyAt = time; }
	io.check("typed", io.controls.typed(io.term));
}

export function key(this io: Io, k: KeyEvent, time: float64): void {
	if (io.controls.ended) { return; }
	const handled = io.controls.keyDown(io.term, k);
	if (!handled.ok) {
		io.fail("key", handled.error);
		return;
	}
	if (handled.value) { return; }
	io.input(io.term.sendKey(k), "key", time);
}

export function keyReleased(this io: Io, k: KeyEvent): void {
	if (io.controls.keyUp(k)) { return; }
	const sent = io.term.sendKey(k);
	if (!sent.ok) { io.fail("key", sent.error); }
}

export function text(this io: Io, typed: string, time: float64): void {
	if (io.controls.holding()) { return; }
	io.input(io.term.sendText(typed), "text", time);
}

export function focus(this io: Io, gained: boolean): void {
	if (io.controls.ended) { return; }
	if (!gained) {
		io.controls.endDrag();
		const released = io.term.releaseHeldKey();
		if (!released.ok) { io.fail("focus", released.error); }
	}
	const sent = io.term.sendFocus(gained);
	if (!sent.ok) { io.fail("focus", sent.error); }
}

export function press(this io: Io, button: MouseButton, h: Hit, time: float64): void {
	io.check("press", io.controls.pointerDown(io.term, button, h, time));
}

export function move(this io: Io, h: Hit, pressed: boolean): void {
	io.check("move", io.controls.pointerMove(io.term, h, pressed));
}

export function release(this io: Io, button: MouseButton, h: Hit): void {
	io.check("release", io.controls.pointerUp(io.term, button, h));
}

export function wheel(this io: Io, notches: float64, h: Hit): void {
	io.check("wheel", io.controls.roll(io.term, notches, h));
}

export function autoscroll(this io: Io): void {
	io.check("autoscroll", io.controls.autoscrollTick(io.term));
}

export function closeKey(this io: Io): void {
	io.check("close key", io.controls.closeKey(io.term));
}

export function confirmDialog(this io: Io): void {
	if (io.controls.closing) {
		io.controls.answerClose(Reply.Confirm);
		return;
	}
	io.check("paste", io.controls.confirm(io.term));
}

export function cancelDialog(this io: Io): void {
	if (io.controls.closing) {
		io.controls.answerClose(Reply.Cancel);
		return;
	}
	io.check("clipboard", io.controls.cancel(io.term));
}

export function pasted(this io: Io, clipboard: string): void {
	io.check("clipboard", io.controls.clipboardText(io.term, clipboard));
}

export function drain(this io: Io): void {
	const drained = io.term.drain();
	if (!drained.ok) { io.fail("output", drained.error); }
}

export function shutdown(this io: Io): void {
	io.term.shutdown();
}

export function relight(this io: Io, ink: CellInk | null): FrameRows {
	const relit = io.term.inkCursor(ink);
	if (!relit.ok) {
		io.fail("cursor", relit.error);
		return FrameRows.none();
	}
	return relit.value;
}

function exitOf(this io: Io): Exit {
	const t = io.term;
	const exit: Exit = {
		code: t.shellExitCode(),
		signal: t.shellExitSignal(),
		abnormal: t.exitedAbnormally(),
	};
	if (exit.abnormal || exit.signal != 0) { io.controls.ended = true; }
	return exit;
}

export function frame(this io: Io): IoFrame {
	const pumped = io.term.pumpFrame();
	let frame: Frame | null = null;
	let again = false;
	let exit: Exit | null = null;
	if (!pumped.ok) {
		io.fail("output", pumped.error);
	} else {
		const asked = pumped.value.asked;
		const held = pumped.value.held;
		const ended = pumped.value.ended;
		frame = move pumped.value;
		if (asked) { io.controls.clipboardAsked(); }
		const vt = vtOf(io.term);
		if (!held && vt !== null) {
			const dropped = io.controls.syncSelection(vt);
			if (!dropped.ok) {
				io.fail("selection", dropped.error);
			} else {
				again = dropped.value;
			}
		}
		if (ended) { exit = io.exitOf(); }
	}
	const c = io.controls;
	const failures = io.failures;
	io.failures = [];
	const keyAt = io.keyAt;
	io.keyAt = -1;
	const marks = io.term.marks;
	io.term.marks = [];
	return {
		frame: frame,
		asks: c.takeAsks(),
		pending: pendingOf(c.held, c.reading, c.closing),
		exit: exit,
		autoscroll: c.autoscroll != 0,
		again: again,
		started: io.started(),
		failures: failures,
		keyAt: keyAt,
		marks: marks,
	};
}

export function port(this io: Io): IoPort {
	return {
		configure: (settings: Settings): void => { io.configure(settings); },
		fit: (cols: int32, rows: int32, cellWidth: int32, cellHeight: int32): void => {
			io.fit(cols, rows, cellWidth, cellHeight);
		},
		drain: (): void => { io.drain(); },
		key: (k: KeyEvent, time: float64): void => { io.key(k, time); },
		keyReleased: (k: KeyEvent): void => { io.keyReleased(k); },
		text: (typed: string, time: float64): void => { io.text(typed, time); },
		focus: (gained: boolean): void => { io.focus(gained); },
		press: (button: MouseButton, h: Hit, time: float64): void => { io.press(button, h, time); },
		move: (h: Hit, pressed: boolean): void => { io.move(h, pressed); },
		release: (button: MouseButton, h: Hit): void => { io.release(button, h); },
		wheel: (notches: float64, h: Hit): void => { io.wheel(notches, h); },
		autoscroll: (): void => { io.autoscroll(); },
		closeKey: (): void => { io.closeKey(); },
		confirmDialog: (): void => { io.confirmDialog(); },
		cancelDialog: (): void => { io.cancelDialog(); },
		pasted: (clipboard: string): void => { io.pasted(clipboard); },
		frame: (done: (got: IoFrame) => void): void => { done(io.frame()); },
		relight: (ink: CellInk | null, done: (rows: FrameRows) => void): void => { done(io.relight(ink)); },
	};
}
