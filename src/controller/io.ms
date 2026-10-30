import { MouseButton } from "./mouseButton";
import { Rgb, setDefaultColors, setPalette, setScrollback } from "../vt/vt";
import { Action, Keybind } from "../input/bindings";
import { Reply } from "../input/paste";
import { Pending, pendingOf } from "./pending";
import { KeyEvent, OptionAsAlt, modifierKey } from "../keys/keys";
import { Link } from "../screen/linksGrid";
import { CellInk } from "../grid/lines";
import { Config } from "../config/config";
import {
	Annotation,
	Decoration,
	FrameRows,
	annotate as annotateRow,
	decorate as decorateRows,
	none,
	unannotate as unannotateRow,
	undecorate as undecorateRows,
} from "./rows";
import { Mark } from "./mark";
import { Asks, Controls, Hit, holding, refit, takeAsks, typed, vtOf } from "./controls";
import { cancel, clipboardAsked, clipboardText, confirm } from "./clipboard";
import { act, answerClose, closeKey, closeWindow, keyDown, keyUp } from "./keyboard";
import {
	autoscrollTick,
	endDrag,
	pointerDown,
	pointerMove,
	pointerUp,
	rehover,
	roll,
	syncSelection,
} from "./mouse";
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

export function settingsOf(this c: Config): Settings {
	return {
		foreground: c.foreground,
		background: c.background,
		palette: c.palette,
		scrollback: c.scrollback,
		keybinds: c.keybinds,
		optionAsAlt: c.optionAsAlt,
	};
}

export enum Where {
	Settings,
	Fit,
	Font,
	Key,
	Text,
	Typed,
	Focus,
	Press,
	Move,
	Release,
	Wheel,
	Autoscroll,
	CloseKey,
	Paste,
	Clipboard,
	Output,
	Selection,
	Cursor,
	Action,
}

export function label(this w: Where): string {
	return match (w) {
		Where.Settings => "settings",
		Where.Fit => "fit",
		Where.Font => "font",
		Where.Key => "key",
		Where.Text => "text",
		Where.Typed => "typed",
		Where.Focus => "focus",
		Where.Press => "press",
		Where.Move => "move",
		Where.Release => "release",
		Where.Wheel => "wheel",
		Where.Autoscroll => "autoscroll",
		Where.CloseKey => "close key",
		Where.Paste => "paste",
		Where.Clipboard => "clipboard",
		Where.Output => "output",
		Where.Selection => "selection",
		Where.Cursor => "cursor",
		Where.Action => "action",
	};
}

export struct Failure {
	where: Where;
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
	hover: Link | null;
	hoverChanged: boolean;
}

export interface Io {
	term: Term;
	controls: Controls;
	settings: Settings | null;
	failures: Vec<Failure>;
	keyAt: float64;
	hoverSent: Link | null;
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
	act: (action: Action) => void;
	closeKey: () => void;
	closeWindow: () => void;
	confirmDialog: () => void;
	cancelDialog: () => void;
	pasted: (clipboard: string) => void;
	decorate: (d: Decoration) => void;
	undecorate: (id: int32) => void;
	annotate: (a: Annotation) => void;
	unannotate: (id: int32) => void;
	frame: (done: (got: IoFrame) => void, failed: (error: string) => void) => void;
	relight: (
		ink: CellInk | null,
		done: (rows: FrameRows) => void,
		failed: (error: string) => void,
	) => void;
}

export function open(this typeof Io, t: Term): Io {
	return { term: t, controls: Controls.open(), settings: null, failures: [], keyAt: -1, hoverSent: null };
}

export function started(this io: Io): boolean {
	return io.term.session !== null;
}

function fail(this io: Io, where: Where, error: TermError): void {
	io.failures.push({ where: where, error: error, started: io.started() });
}

function check(this io: Io, where: Where, r: Result<boolean, TermError>): void {
	if (!r.ok) { io.fail(where, r.error); }
}

function apply(this io: Io): void {
	const s = io.term.session;
	const settings = io.settings;
	if (s === null || settings === null) { return; }
	const vt = s.vt;
	if (!vt.setDefaultColors(settings.foreground, settings.background).ok ||
		!vt.setPalette(settings.palette).ok ||
		!vt.setScrollback(settings.scrollback).ok) {
		io.fail(Where.Settings, TermError.SettingsRefused);
	}
}

export function configure(this io: Io, settings: Settings): void {
	io.settings = settings;
	io.controls.keybinds = settings.keybinds;
	io.term.keys.optionAsAlt = settings.optionAsAlt;
	io.apply();
}

export function fit(
	this io: Io,
	cols: int32,
	rows: int32,
	cellWidth: int32,
	cellHeight: int32,
): void {
	const started = io.term.session !== null;
	const fitted = io.controls.refit(io.term, cols, rows, cellWidth, cellHeight);
	if (!fitted.ok) {
		io.fail(Where.Fit, fitted.error);
		return;
	}
	if (!started) { io.apply(); }
}

function input(this io: Io, sent: Result<boolean, TermError>, where: Where, time: float64): void {
	if (!sent.ok) {
		io.fail(where, sent.error);
		return;
	}
	if (!sent.value) { return; }
	if (io.keyAt < 0) { io.keyAt = time; }
	io.check(Where.Typed, io.controls.typed(io.term));
}

function rehover(this io: Io, k: KeyEvent): void {
	if (!modifierKey(k.key)) { return; }
	io.check(Where.Move, io.controls.rehover(io.term, k.mods));
}

export function key(this io: Io, k: KeyEvent, time: float64): void {
	if (io.controls.ended) { return; }
	io.rehover(k);
	const handled = io.controls.keyDown(io.term, k);
	if (!handled.ok) {
		io.fail(Where.Key, handled.error);
		return;
	}
	if (handled.value) { return; }
	io.input(io.term.sendKey(k), Where.Key, time);
}

export function keyReleased(this io: Io, k: KeyEvent): void {
	io.rehover(k);
	if (io.controls.keyUp(k)) { return; }
	const sent = io.term.sendKey(k);
	if (!sent.ok) { io.fail(Where.Key, sent.error); }
}

export function text(this io: Io, typed: string, time: float64): void {
	if (io.controls.holding()) { return; }
	io.input(io.term.sendText(typed), Where.Text, time);
}

export function focus(this io: Io, gained: boolean): void {
	if (io.controls.ended) { return; }
	if (!gained) {
		io.controls.endDrag();
		const released = io.term.releaseHeldKey();
		if (!released.ok) { io.fail(Where.Focus, released.error); }
	}
	const sent = io.term.sendFocus(gained);
	if (!sent.ok) { io.fail(Where.Focus, sent.error); }
}

export function press(this io: Io, button: MouseButton, h: Hit, time: float64): void {
	io.check(Where.Press, io.controls.pointerDown(io.term, button, h, time));
}

export function move(this io: Io, h: Hit, pressed: boolean): void {
	io.check(Where.Move, io.controls.pointerMove(io.term, h, pressed));
}

export function release(this io: Io, button: MouseButton, h: Hit): void {
	io.check(Where.Release, io.controls.pointerUp(io.term, button, h));
}

export function wheel(this io: Io, notches: float64, h: Hit): void {
	io.check(Where.Wheel, io.controls.roll(io.term, notches, h));
}

export function autoscroll(this io: Io): void {
	io.check(Where.Autoscroll, io.controls.autoscrollTick(io.term));
}

export function act(this io: Io, action: Action): void {
	io.check(Where.Action, io.controls.act(io.term, action));
}

export function closeKey(this io: Io): void {
	io.check(Where.CloseKey, io.controls.closeKey(io.term));
}

export function closeWindow(this io: Io): void {
	io.controls.closeWindow(io.term);
}

export function confirmDialog(this io: Io): void {
	if (io.controls.closing) {
		io.controls.answerClose(Reply.Confirm);
		return;
	}
	io.check(Where.Paste, io.controls.confirm(io.term));
}

export function cancelDialog(this io: Io): void {
	if (io.controls.closing) {
		io.controls.answerClose(Reply.Cancel);
		return;
	}
	io.check(Where.Clipboard, io.controls.cancel(io.term));
}

export function pasted(this io: Io, clipboard: string): void {
	io.check(Where.Clipboard, io.controls.clipboardText(io.term, clipboard));
}

export function decorate(this io: Io, d: Decoration): void {
	io.term.decor.decorateRows(d);
}

export function undecorate(this io: Io, id: int32): void {
	io.term.decor.undecorateRows(id);
}

export function annotate(this io: Io, a: Annotation): void {
	io.term.decor.annotateRow(a);
}

export function unannotate(this io: Io, id: int32): void {
	io.term.decor.unannotateRow(id);
}

export function drain(this io: Io): void {
	const drained = io.term.drain();
	if (!drained.ok) { io.fail(Where.Output, drained.error); }
}

export function shutdown(this io: Io): void {
	io.term.shutdown();
}

export function relight(this io: Io, ink: CellInk | null): FrameRows {
	const relit = io.term.inkCursor(ink);
	if (!relit.ok) {
		io.fail(Where.Cursor, relit.error);
		return FrameRows.none();
	}
	return relit.value;
}

function exitOf(this io: Io): Exit {
	const t = io.term;
	const exit: Exit = {
		code: t.shellExitCode() ?? 0,
		signal: t.shellExitSignal() ?? 0,
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
		io.fail(Where.Output, pumped.error);
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
				io.fail(Where.Selection, dropped.error);
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
	const hover = c.pointer.hover;
	const hoverChanged = hover != io.hoverSent;
	io.hoverSent = hover;
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
		hover: hover,
		hoverChanged: hoverChanged,
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
		act: (action: Action): void => { io.act(action); },
		closeKey: (): void => { io.closeKey(); },
		closeWindow: (): void => { io.closeWindow(); },
		confirmDialog: (): void => { io.confirmDialog(); },
		cancelDialog: (): void => { io.cancelDialog(); },
		pasted: (clipboard: string): void => { io.pasted(clipboard); },
		decorate: (d: Decoration): void => { io.decorate(d); },
		undecorate: (id: int32): void => { io.undecorate(id); },
		annotate: (a: Annotation): void => { io.annotate(a); },
		unannotate: (id: int32): void => { io.unannotate(id); },
		frame: (done: (got: IoFrame) => void, failed: (error: string) => void): void => {
			done(io.frame());
		},
		relight: (
			ink: CellInk | null,
			done: (rows: FrameRows) => void,
			failed: (error: string) => void,
		): void => {
			done(io.relight(ink));
		},
	};
}
