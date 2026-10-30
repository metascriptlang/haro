import { flush } from "../../../../../../neon/src/core/runtime";
import { NeonEvent, neonEvent } from "../../../../../../neon/src/render/event";
import { installClipboardServices } from "../../../../../../neon/src/api/clipboardServices";
import { Config, defaults, pxOf } from "../../../../config/config";
import { CommandDone, writeText } from "../../../../vt/vt";
import { RowNote, RowTint } from "../../../../grid/lines";
import { open, NoticeModel } from "../notice/notice";
import { open, PasteDialogModel } from "../paste/pasteDialog";
import { Stats, empty } from "../../../stats";
import {
	ConfigChange,
	ConfigOutcome,
	Desktop,
	HostEvents,
	KeyHook,
	PaneModel,
	Report,
	ShellHook,
	Timing,
	connectHost,
	open,
	failed,
	refresh,
} from "./paneModel";
import { Action } from "../../../../input/bindings";
import { HookPane, KeyAnswer, UNHANDLED } from "../../../../config/hooks";
import { KeyEvent } from "../../../../keys/keys";
import { cancelDialog, confirmDialog } from "./paneEvents";
import { Io, Where, open, port } from "../../../../controller/io";
import { Term, TermError } from "../../../../controller/term";
import { View, fitRows, hexOf, open, text } from "../../../frame";
import { holding } from "../../../../controller/controls";
import { MouseButton } from "../../../../controller/mouseButton";
import { Sink, exiting, hitAt, lines, onFresh, onPty, onRefused, onTerm } from "../../../../controller/terminalRig";
import { Replay } from "../../../../pty/replay";
import { Pty, PtyError } from "../../../../pty/transport";

interface Calls {
	fatal: string;
	noted: string;
	title: string;
	titleBelled: boolean;
	notified: string;
	closed: int32;
	attentions: int32;
	opened: int32;
	reloaded: int32;
	exits: string;
}

function noCalls(): Calls {
	return { fatal: "", noted: "", title: "", titleBelled: false, notified: "", closed: 0, attentions: 0, opened: 0, reloaded: 0, exits: "" };
}

function desktopFor(calls: Calls): Desktop {
	return {
		setTitle: (title: string, belled: boolean): void => {
			calls.title = title;
			calls.titleBelled = belled;
		},
		notify: (title: string, body: string): void => { calls.notified += `${title}|${body}\n`; },
		openLink: (uri: string): void => {},
		attention: (): void => { calls.attentions += 1; },
		openConfig: (): void => { calls.opened += 1; },
		reloadConfig: (): void => { calls.reloaded += 1; },
		close: (): void => { calls.closed += 1; },
		exited: (code: int32): void => { calls.exits += `${code} `; },
	};
}

function reportFor(calls: Calls): Report {
	return {
		note: (message: string): void => { calls.noted += `${message}\n`; },
		fail: (message: string): void => { calls.fatal = message; },
	};
}

function timingAt(now: float64): Timing {
	return { clock: (): float64 => now, schedule: (run: () => void): void => {} };
}

const NO_HOOK: KeyHook = {
	answer: (pane: HookPane, k: KeyEvent): Result<KeyAnswer, string> => Result.ok(UNHANDLED),
};

const NO_SHELL_HOOK: ShellHook = {
	prompted: (pane: HookPane, at: int32): Result<void, string> => Result.ok(null),
	commandDone: (pane: HookPane, done: CommandDone): Result<void, string> => Result.ok(null),
};

function paneWith(
	io: Io,
	calls: Calls,
	timing: Timing = timingAt(0),
	keyHook: KeyHook = NO_HOOK,
	shellHook: ShellHook = NO_SHELL_HOOK,
): PaneModel {
	const view = View.open();
	view.fitRows(io.term.shown.length as int32);
	return PaneModel.open(
		io.port(),
		view,
		desktopFor(calls),
		reportFor(calls),
		timing,
		keyHook,
		shellHook,
		"",
		defaults(),
		NoticeModel.open(),
		PasteDialogModel.open(),
		Stats.empty(),
	);
}

function paneOf(t: Term, calls: Calls): PaneModel {
	return paneWith(Io.open(t), calls);
}

interface Scheduled {
	runs: Vec<() => void>;
}

function timingCounting(scheduled: Scheduled): Timing {
	return { clock: (): float64 => 0, schedule: (run: () => void): void => { scheduled.runs.push(run); } };
}

interface Host {
	config: ((change: ConfigChange) => void) | null;
	menu: ((id: string) => void) | null;
	closeRequest: (() => void) | null;
	wake: (() => void) | null;
}

function hostOf(host: Host): HostEvents {
	return {
		onConfig: (handler: (change: ConfigChange) => void): void => { host.config = handler; },
		onMenu: (handler: (id: string) => void): void => { host.menu = handler; },
		onCloseRequest: (handler: () => void): void => { host.closeRequest = handler; },
		onWake: (handler: () => void): void => { host.wake = handler; },
	};
}

function loaded(c: Config, error: string = ""): ConfigChange {
	return { outcome: ConfigOutcome.Loaded, config: c, family: "", error: error };
}

interface Board {
	copied: Vec<string>;
	offer: string;
	reads: int32;
}

function withClipboard(board: Board, body: () => void): void {
	installClipboardServices({
		getClipboard: async (): Promise<string> => {
			board.reads += 1;
			return board.offer;
		},
		setClipboard: (text: string): void => { board.copied.push(text); },
	});
	body();
	installClipboardServices(null);
}

function pressed(code: string): NeonEvent {
	const e = neonEvent("keydown");
	e.code = code;
	return e;
}

function lifted(code: string): NeonEvent {
	const e = neonEvent("keyup");
	e.code = code;
	return e;
}

test "an applied frame is stamped by the host's clock into the stats the pane was given" {
	assert onFresh("abc", (t: Term, sink: Sink): void => {
		const calls = noCalls();
		const stats = Stats.empty();
		stats.recording = true;
		stats.noteKey(10);
		const view = View.open();
		view.fitRows(t.shown.length as int32);
		const m = PaneModel.open(
			Io.open(t).port(),
			view,
			desktopFor(calls),
			reportFor(calls),
			timingAt(15.5),
			NO_HOOK,
			NO_SHELL_HOOK,
			"",
			defaults(),
			NoticeModel.open(),
			PasteDialogModel.open(),
			stats,
		);
		m.refresh();
		assert stats.line().includes("echo n=1 p50=5.5 max=5.5");
	}).ok;
}

test "a program's title reaches the window" {
	assert onFresh("\x1b]2;vim\x07", (t: Term, sink: Sink): void => {
		const calls = noCalls();
		const m = paneOf(t, calls);
		m.refresh();
		assert calls.title == "vim";
	}).ok;
}

test "a bell while the window is unfocused asks for attention once per frame and marks the title until focus returns" {
	assert onFresh("\x07\x07\x1b]2;vim\x07", (t: Term, sink: Sink): void => {
		const calls = noCalls();
		const m = paneOf(t, calls);
		m.cursor.focused = false;
		m.refresh();
		assert calls.attentions == 1, `${calls.attentions}`;
		assert calls.title == "vim";
		assert calls.titleBelled;
		m.refresh();
		assert calls.attentions == 1, `${calls.attentions}`;
		assert calls.titleBelled;
		m.cursor.focused = true;
		m.refresh();
		assert !calls.titleBelled;
		assert calls.title == "vim";
	}).ok;
}

test "a bell while the window is focused neither asks for attention nor marks the title" {
	assert onFresh("\x07", (t: Term, sink: Sink): void => {
		const calls = noCalls();
		const m = paneOf(t, calls);
		m.refresh();
		assert calls.attentions == 0;
		assert !calls.titleBelled;
		assert calls.title == "";
	}).ok;
}

test "a program's notification reaches the host only while the window is unfocused" {
	assert onFresh("\x1b]9;saved\x07", (t: Term, sink: Sink): void => {
		const calls = noCalls();
		const m = paneOf(t, calls);
		m.refresh();
		assert calls.notified == "";
		const s = t.session;
		assert s !== null;
		if (s !== null) { s.vt.writeText("\x1b]777;notify;make;done\x07"); }
		m.cursor.focused = false;
		m.refresh();
		assert calls.notified == "make|done\n";
	}).ok;
}

test "an internal failure while the shell runs is a notice logged once, and the shell keeps running" {
	assert onTerm("ready", (t: Term, sink: Sink): void => {
		const calls = noCalls();
		const m = paneOf(t, calls);
		m.refresh();
		m.failed(Where.Key, "EncodeFailed");
		m.failed(Where.Key, "EncodeFailed");
		assert calls.fatal == "";
		assert calls.noted == "key: EncodeFailed\n";
		assert m.notice.text.endsWith("key: EncodeFailed");
		assert t.session !== null;
	}).ok;
}

test "a key event with a modifier bit outside KeyMod is dropped and reported once, and the shell keeps running" {
	assert onTerm("ready", (t: Term, sink: Sink): void => {
		const calls = noCalls();
		const m = paneOf(t, calls);
		m.refresh();
		const stray = pressed("KeyA");
		stray.mods = 4096;
		m.keyed(stray);
		m.keyed(stray);
		assert calls.noted == "key: modifier mask 4096 is not a whole number below 1024\n";
		assert m.notice.text.endsWith("key: modifier mask 4096 is not a whole number below 1024");
		assert t.session !== null;
	}).ok;
}

test "a shell that did not start because its command is blank says so" {
	assert onRefused(PtyError.OpenBlankCommand, (t: Term): void => {
		const calls = noCalls();
		const m = paneOf(t, calls);
		m.io.fit(20, 3, 0, 0);
		m.refresh();
		assert m.notice.text.includes("command is blank"), m.notice.text;
		assert calls.fatal == "";
	}).ok;
}

test "an internal failure before the shell started is fatal" {
	assert onFresh("", (t: Term, sink: Sink): void => {
		const calls = noCalls();
		const m = paneOf(t, calls);
		m.failed(Where.Fit, "SessionStartFailed");
		assert calls.fatal == "fit: SessionStartFailed";
		assert calls.noted == "";
	}).ok;
}

function closeAsked(this m: PaneModel): boolean {
	m.io.closeKey();
	m.refresh();
	flush();
	return m.dialog.visible();
}

test "closing while a program runs shows the dialog: cancel keeps the window, confirm closes it" {
	assert onTerm("$ ", (t: Term, sink: Sink): void => {
		const calls = noCalls();
		const m = paneOf(t, calls);
		sink.busy = true;
		assert m.closeAsked();
		assert m.dialog.confirmLabel() == "Close (Enter)";
		assert calls.closed == 0;
		m.cancelDialog();
		flush();
		assert !m.dialog.visible();
		assert calls.closed == 0;
		assert m.closeAsked();
		m.confirmDialog();
		assert calls.closed == 1;
	}).ok;
}

test "closing while only the shell runs closes at once with no dialog" {
	assert onTerm("$ ", (t: Term, sink: Sink): void => {
		const calls = noCalls();
		const m = paneOf(t, calls);
		assert !m.closeAsked();
		assert calls.closed == 1;
	}).ok;
}

function afterExit(
	code: int32,
	signal: int32,
	lateMs: float64,
	body: (m: PaneModel, calls: Calls, io: Io) => void,
): Result<void, TermError> {
	let at: float64 = 0;
	return onPty(exiting("last output", code, signal), (): float64 => { return at; }, 20, 3, (t: Term): void => {
		at = lateMs;
		const calls = noCalls();
		const io = Io.open(t);
		const m = paneWith(io, calls);
		m.refresh();
		body(m, calls, io);
	});
}

test "a shell killed by a signal keeps the window and names the signal; a key closes it" {
	assert afterExit(137, 9, 1000, (m: PaneModel, calls: Calls): void => {
		assert calls.exits == "";
		assert m.notice.text == "the shell was killed by signal 9, press any key to close";
		assert m.view.text(0) == "last output";
		m.keyed(pressed("ShiftLeft"));
		m.keyed(pressed("MetaRight"));
		assert calls.exits == "";
		m.keyed(pressed("KeyA"));
		assert calls.exits == "137 ";
	}).ok;
}

test "a shell that exits with a status, a failed last command's or a signal-like one, closes at once" {
	assert afterExit(1, 0, 1000, (m: PaneModel, calls: Calls): void => {
		assert calls.exits == "1 ";
		assert m.notice.text == "";
	}).ok;
	assert afterExit(130, 0, 1000, (m: PaneModel, calls: Calls): void => {
		assert calls.exits == "130 ";
	}).ok;
}

test "a shell that exits with zero closes the window at once" {
	assert afterExit(0, 0, 1000, (m: PaneModel, calls: Calls): void => {
		assert calls.exits == "0 ";
		assert m.notice.text == "";
	}).ok;
}

test "a shell that fails as it starts keeps its own notice and also closes on a key" {
	assert afterExit(127, 0, 0, (m: PaneModel, calls: Calls): void => {
		assert m.notice.text.startsWith("the shell exited with code 127 as it started: check command in config.ms");
		assert m.notice.text.endsWith("press any key to close");
		assert calls.exits == "";
		m.keyed(pressed("Enter"));
		assert calls.exits == "127 ";
	}).ok;
}

test "the close window command closes a dead shell at once, with no confirmation" {
	assert afterExit(137, 9, 1000, (m: PaneModel, calls: Calls): void => {
		assert !m.closeAsked();
		assert calls.closed == 1;
	}).ok;
}

test "a dead shell takes no typed text, key release or focus change, and keeps its notice" {
	assert afterExit(137, 9, 1000, (m: PaneModel, calls: Calls, io: Io): void => {
		const text = m.notice.text;
		m.focusChanged(false);
		m.keyReleased(lifted("KeyA"));
		assert m.notice.text == text;
		assert io.controls.holding();
		assert calls.fatal == "";
		assert calls.noted == "";
	}).ok;
}

test "refreshes are counted, and a frame that has more output waiting is followed by a scheduled refresh" {
	assert onFresh(lines(120000), (t: Term, sink: Sink): void => {
		const scheduled: Scheduled = { runs: [] };
		const m = paneWith(Io.open(t), noCalls(), timingCounting(scheduled));
		m.refresh();
		assert m.stats.line().startsWith("refreshes=1 more=1 held=0");
		assert scheduled.runs.length == 1;
		scheduled.runs[0]();
		assert m.stats.tally.refreshes == 2;
	}).ok;
}

test "a frame held by synchronized output is counted each time, and its recheck timer is not doubled" {
	assert onFresh("abc\x1b[?2026h", (t: Term, sink: Sink): void => {
		const m = paneOf(t, noCalls());
		m.refresh();
		assert m.stats.line().startsWith("refreshes=1 more=0 held=1");
		const timer = m.holdTimer;
		assert timer !== null;
		m.refresh();
		assert m.stats.tally.held == 2;
		assert m.holdTimer == timer;
		clearTimeout(timer);
	}).ok;
}

test "dragging above the grid keeps a refresh timer running for the autoscroll, one at a time" {
	assert onTerm(lines(30), (t: Term, sink: Sink): void => {
		const m = paneOf(t, noCalls());
		assert m.scrollTimer === null;
		m.io.press(MouseButton.Left, hitAt(3, 2), 0);
		m.io.move({ ...hitAt(3, 0), y: -12 }, true);
		m.refresh();
		assert m.autoscrolling;
		const timer = m.scrollTimer;
		assert timer !== null;
		m.refresh();
		// The local stands in for card 2026-10-30-equality-of-a-field-narrowed-to-null-crashes-lowering
		const again = m.scrollTimer;
		assert again !== null && timer !== null && again == timer;
		clearTimeout(timer);
	}).ok;
}

test "a program's clipboard write reaches the system clipboard" {
	assert onFresh("\x1b]52;c;aGk=\x07", (t: Term, sink: Sink): void => {
		const board: Board = { copied: [], offer: "", reads: 0 };
		withClipboard(board, (): void => {
			paneOf(t, noCalls()).refresh();
		});
		assert board.copied.length == 1;
		assert board.copied[0] == "hi";
	}).ok;
}

test "a clipboard write the OS refuses is told to the user" {
	assert onFresh("\x1b]52;c;aGk=\x07", (t: Term, sink: Sink): void => {
		const m = paneOf(t, noCalls());
		installClipboardServices({
			getClipboard: async (): Promise<string> => "",
			setClipboard: (text: string): void => { throw new Error("refused"); },
		});
		m.refresh();
		installClipboardServices(null);
		assert m.notice.text.startsWith("Haro could not copy to the clipboard");
	}).ok;
}

test "a clipboard read the program asks for goes to the system clipboard, once per ask" {
	assert onFresh("\x1b]52;c;?\x07", (t: Term, sink: Sink): void => {
		const board: Board = { copied: [], offer: "x", reads: 0 };
		withClipboard(board, (): void => {
			const m = paneOf(t, noCalls());
			m.refresh();
			m.refresh();
		});
		assert board.reads == 1;
	}).ok;
}

test "a clipboard read the OS refuses is told to the user" {
	const panes: PaneModel[] = [];
	installClipboardServices({
		getClipboard: async (): Promise<string> => { throw new Error("refused"); },
		setClipboard: (text: string): void => {},
	});
	assert onFresh("\x1b]52;c;?\x07", (t: Term, sink: Sink): void => {
		const m = paneOf(t, noCalls());
		panes.push(m);
		m.refresh();
	}).ok;
	for (let i = 0; i < 4; i++) { await Promise.resolve(0); }
	installClipboardServices(null);
	assert panes[0].notice.text.startsWith("Haro could not read the clipboard");
}

test "a config change applies live except the shell it starts, which asks for a restart" {
	assert onFresh("", (t: Term, sink: Sink): void => {
		const m = paneOf(t, noCalls());
		const host: Host = { config: null, menu: null, closeRequest: null, wake: null };
		m.connectHost(hostOf(host));
		const onConfig = host.config;
		assert onConfig !== null;
		if (onConfig !== null) {
			onConfig(loaded({ ...defaults(), padding: 6, background: { r: 1, g: 2, b: 3 } }));
			assert m.padding() == 6;
			assert m.notice.text == "";
			flush();
			assert m.background() == hexOf({ r: 1, g: 2, b: 3 });
			const restart = "config.ms: command, workingDirectory and shellIntegration apply " +
				"when Haro restarts";
			onConfig(loaded({ ...defaults(), command: "other" }));
			assert m.notice.text == restart;
			onConfig(loaded({ ...defaults(), shellIntegration: false }));
			assert m.notice.text == restart;
			onConfig(loaded(defaults(), "bad key"));
			assert m.notice.text == "config.ms: bad key";
			onConfig({ outcome: ConfigOutcome.Refused, error: "syntax error" });
			assert m.notice.text == "config.ms: syntax error";
			assert m.padding() == 0;
		}
	}).ok;
}

test "the font size steps by a point, resets to the config's, and survives a reload until reset" {
	assert onFresh("", (t: Term, sink: Sink): void => {
		const m = paneOf(t, noCalls());
		const host: Host = { config: null, menu: null, closeRequest: null, wake: null };
		m.connectHost(hostOf(host));
		const onConfig = host.config;
		assert onConfig !== null;
		const base = defaults().fontSize;
		assert m.metrics.fontSize() == pxOf(base);
		m.hosted(Action.IncreaseFontSize);
		m.hosted(Action.IncreaseFontSize);
		assert m.metrics.fontSize() == pxOf(base + 2);
		m.hosted(Action.DecreaseFontSize);
		assert m.metrics.fontSize() == pxOf(base + 1);
		if (onConfig !== null) {
			onConfig(loaded({ ...defaults(), fontSize: 30 }));
			assert m.metrics.fontSize() == pxOf(base + 1);
			m.hosted(Action.ResetFontSize);
			assert m.metrics.fontSize() == pxOf(30);
			onConfig(loaded({ ...defaults(), fontSize: 20 }));
			assert m.metrics.fontSize() == pxOf(20);
		}
		for (let i = 0; i < 400; i++) { m.hosted(Action.DecreaseFontSize); }
		assert m.metrics.fontSize() == pxOf(1);
	}).ok;
}

test "the open and reload config actions reach the host, and an action the window does not run is reported" {
	assert onFresh("", (t: Term, sink: Sink): void => {
		const calls = noCalls();
		const m = paneOf(t, calls);
		m.hosted(Action.OpenConfig);
		m.hosted(Action.ReloadConfig);
		m.hosted(Action.ReloadConfig);
		assert calls.opened == 1;
		assert calls.reloaded == 2;
		assert calls.fatal == "";
		m.hosted(Action.Copy);
		assert calls.fatal.includes("the window does not run Copy");
	}).ok;
}

test "a menu item runs the action it is named for, and one that names no action is reported" {
	assert onFresh("", (t: Term, sink: Sink): void => {
		const calls = noCalls();
		const m = paneOf(t, calls);
		const host: Host = { config: null, menu: null, closeRequest: null, wake: null };
		m.connectHost(hostOf(host));
		const menu = host.menu;
		assert menu !== null;
		if (menu !== null) {
			menu("increase_font_size");
			assert m.metrics.fontSize() == pxOf(defaults().fontSize + 1);
			menu("open_config");
			menu("reload_config");
			assert calls.opened == 1 && calls.reloaded == 1;
			assert calls.fatal == "";
			menu("quit_everything");
			assert m.notice.text.includes("names no action");
		}
	}).ok;
}

test "the host's wake drains the shell and refreshes on the scheduler; its close window menu item and close request ask to close" {
	assert onTerm("$ ", (t: Term, sink: Sink): void => {
		const scheduled: Scheduled = { runs: [] };
		const calls = noCalls();
		const m = paneWith(Io.open(t), calls, timingCounting(scheduled));
		const host: Host = { config: null, menu: null, closeRequest: null, wake: null };
		m.connectHost(hostOf(host));
		const wake = host.wake;
		const menu = host.menu;
		assert wake !== null && menu !== null;
		if (wake !== null && menu !== null) {
			wake();
			assert scheduled.runs.length == 1;
			assert m.stats.tally.refreshes == 0;
			scheduled.runs[0]();
			assert m.stats.tally.refreshes == 1;
			assert calls.closed == 0;
			menu("close_window");
			assert calls.closed == 1;
			const closeRequest = host.closeRequest;
			assert closeRequest !== null;
			if (closeRequest !== null) { closeRequest(); }
			assert calls.closed == 2;
		}
	}).ok;
}

test "a key the program has no room for is a notice that says the input was dropped" {
	const pty: Pty = {
		...Replay.ofText("ready").toPty(),
		write: (data: Readonly<Span<uint8>>): Result<void, PtyError> => {
			return Result.err(PtyError.Backlogged);
		},
		exitCode: (): int32 | null => { return null; },
	};
	assert onPty(pty, (): float64 => 0, 80, 24, (t: Term): void => {
		const calls = noCalls();
		const m = paneOf(t, calls);
		m.refresh();
		m.keyed(pressed("Enter"));
		m.refresh();
		assert calls.fatal == "";
		assert m.notice.text == "the program has not read the last 16 MB sent to it, so this input was dropped";
	}).ok;
}

interface Written {
	sent: Vec<string>;
}

function writtenBy(w: Written, shown: string = "ready"): Pty {
	return {
		...Replay.ofText(shown).toPty(),
		write: (data: Readonly<Span<uint8>>): Result<void, PtyError> => {
			w.sent.push(data.asString());
			return Result.ok(null);
		},
		exitCode: (): int32 | null => { return null; },
	};
}

test "a key the config's onKey handles sends its text instead, and the keys it leaves pass through" {
	const w: Written = { sent: [] };
	const hook: KeyHook = {
		answer: (pane: HookPane, k: KeyEvent): Result<KeyAnswer, string> => {
			return Result.ok(k.key == "KeyK" ? { handled: true, send: "hooked" } : UNHANDLED);
		},
	};
	assert onPty(writtenBy(w), (): float64 => 0, 80, 24, (t: Term): void => {
		const m = paneWith(Io.open(t), noCalls(), timingAt(0), hook);
		m.refresh();
		m.keyed(pressed("KeyK"));
		m.keyed(pressed("Enter"));
		m.refresh();
		assert w.sent.join("|") == "hooked|\r", w.sent.join("|");
	}).ok;
}

test "an onKey that fails is a notice, and the key still reaches the program" {
	const w: Written = { sent: [] };
	const hook: KeyHook = {
		answer: (pane: HookPane, k: KeyEvent): Result<KeyAnswer, string> => Result.err("onKey in config.ms failed: boom"),
	};
	assert onPty(writtenBy(w), (): float64 => 0, 80, 24, (t: Term): void => {
		const m = paneWith(Io.open(t), noCalls(), timingAt(0), hook);
		m.refresh();
		m.keyed(pressed("Enter"));
		m.refresh();
		assert m.notice.text == "onKey in config.ms failed: boom";
		assert w.sent.join("|") == "\r", w.sent.join("|");
	}).ok;
}

test "a shell's marks call the config's onCommandDone and onPrompt in order, and a failing hook is a notice" {
	assert onFresh("\x1b]133;C\x07\x1b]133;D;1\x07\x1b]133;A\x07", (t: Term, sink: Sink): void => {
		const heard: Written = { sent: [] };
		const hook: ShellHook = {
			prompted: (pane: HookPane, at: int32): Result<void, string> => {
				heard.sent.push("prompt");
				return Result.err("onPrompt in config.ms failed: boom");
			},
			commandDone: (pane: HookPane, done: CommandDone): Result<void, string> => {
				heard.sent.push(`done ${done.exitCode ?? -1} ${done.durationMs !== null}`);
				return Result.ok(null);
			},
		};
		const m = paneWith(Io.open(t), noCalls(), timingAt(0), NO_HOOK, hook);
		m.refresh();
		assert heard.sent.join("|") == "done 1 true|prompt", heard.sent.join("|");
		assert m.notice.text == "onPrompt in config.ms failed: boom";
	}).ok;
}

test "a hook's send writes to its pane's shell and its notify reaches the desktop" {
	const w: Written = { sent: [] };
	const keyHook: KeyHook = {
		answer: (pane: HookPane, k: KeyEvent): Result<KeyAnswer, string> => {
			pane.send("from onKey");
			return Result.ok(UNHANDLED);
		},
	};
	const shellHook: ShellHook = {
		prompted: (pane: HookPane, at: int32): Result<void, string> => Result.ok(null),
		commandDone: (pane: HookPane, done: CommandDone): Result<void, string> => {
			pane.send(`exit ${done.exitCode ?? -1}`);
			pane.notify("done", `exit ${done.exitCode ?? -1}`);
			return Result.ok(null);
		},
	};
	const marks = "\x1b]133;C\x07\x1b]133;D;3\x07";
	assert onPty(writtenBy(w, marks), (): float64 => 0, 80, 24, (t: Term): void => {
		const calls = noCalls();
		const m = paneWith(Io.open(t), calls, timingAt(0), keyHook, shellHook);
		m.refresh();
		m.keyed(pressed("Enter"));
		assert w.sent.join("|") == "exit 3|from onKey|\r", w.sent.join("|");
		assert calls.notified == "done|exit 3\n", calls.notified;
	}).ok;
}

test "a command-done mark whose hook decorates posts the decoration to the shell and schedules a refresh" {
	const ran = "\x1b]133;A\x07$ false\r\n\x1b]133;C\x07oops\r\n\x1b]133;D;1\x07\x1b]133;A\x07$ ";
	assert onFresh(ran, (t: Term, sink: Sink): void => {
		let ids: Vec<int32> = [];
		const hook: ShellHook = {
			prompted: (pane: HookPane, at: int32): Result<void, string> => Result.ok(null),
			commandDone: (pane: HookPane, done: CommandDone): Result<void, string> => {
				const prompt = done.prompt;
				const tint: RowTint = { fg: null, bg: { r: 58, g: 28, b: 36 } };
				if (prompt !== null) { ids.push(pane.decorate(prompt, done.end, tint)); }
				return Result.ok(null);
			},
		};
		const scheduled: Scheduled = { runs: [] };
		const io = Io.open(t);
		const m = paneWith(io, noCalls(), timingCounting(scheduled), NO_HOOK, hook);
		m.refresh();
		assert ids.length == 1 && ids[0] == 1;
		assert t.decor.decorations.length == 1;
		assert t.decor.decorations[0].id == 1;
		assert scheduled.runs.length >= 1;
		for (const run of scheduled.runs) { run(); }
		assert m.view.grid.at(0).line.runs[0].bg.r == 58;
		assert m.view.grid.at(2).line.runs[0].bg.r != 58;
	}).ok;
}

test "a command-done mark whose hook annotates posts the annotation to the shell and schedules a refresh" {
	const ran = "\x1b]133;A\x07$ false\r\n\x1b]133;C\x07oops\r\n\x1b]133;D;1\x07\x1b]133;A\x07$ ";
	assert onFresh(ran, (t: Term, sink: Sink): void => {
		let ids: Vec<int32> = [];
		const hook: ShellHook = {
			prompted: (pane: HookPane, at: int32): Result<void, string> => Result.ok(null),
			commandDone: (pane: HookPane, done: CommandDone): Result<void, string> => {
				const prompt = done.prompt;
				const note: RowNote = { text: "exit 1", fg: null, bg: null };
				if (prompt !== null) {
					ids.push(pane.decorate(prompt, done.end, { fg: null, bg: null }));
					ids.push(pane.annotate(prompt, note));
				}
				return Result.ok(null);
			},
		};
		const scheduled: Scheduled = { runs: [] };
		const io = Io.open(t);
		const m = paneWith(io, noCalls(), timingCounting(scheduled), NO_HOOK, hook);
		m.refresh();
		assert ids.length == 2 && ids[0] == 1 && ids[1] == 2;
		assert t.decor.annotations.length == 1;
		assert t.decor.annotations[0].id == 2;
		assert scheduled.runs.length >= 1;
		for (const run of scheduled.runs) { run(); }
		assert m.view.text(0).endsWith("exit 1"), m.view.text(0);
		assert !m.view.text(1).includes("exit"), m.view.text(1);
	}).ok;
}
