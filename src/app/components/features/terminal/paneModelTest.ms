import { flush } from "../../../../../../neon/src/core/runtime";
import { Config, defaults } from "../../../../config/config";
import { Pty, PtyError } from "../../../../pty/transport";
import { Replay } from "../../../../pty/replay";
import { writeText } from "../../../../vt/vt";
import { createNotice } from "../notice/notice";
import { createPasteDialog } from "../paste/pasteDialog";
import { AppHost, PaneModel, bridge, createPane, failed, refresh } from "./paneModel";
import { cancelDialog, confirmDialog } from "./paneEvents";
import { closeKey } from "./keyboard";
import { Term, TermError, openTerm, shutdown } from "./term";
import { holding } from "./controls";
import { Sink, key, onFresh, onTerm } from "./terminalRig";

interface Calls {
	fatal: string;
	noted: string;
	title: string;
	notified: string;
	closed: int32;
	exits: string;
}

function noCalls(): Calls {
	return { fatal: "", noted: "", title: "", notified: "", closed: 0, exits: "" };
}

function hostFor(calls: Calls): AppHost {
	return {
		onWake: (handler: () => void, failed: (what: string, error: string) => void): void => {},
		schedule: (run: () => void): void => {},
		exited: (code: int32): void => { calls.exits += `${code} `; },
		fail: (message: string): void => { calls.fatal = message; },
		note: (message: string): void => { calls.noted += `${message}\n`; },
		setTitle: (title: string): void => { calls.title = title; },
		notify: (title: string, body: string): void => { calls.notified += `${title}|${body}\n`; },
		openLink: (uri: string): void => {},
		close: (): void => { calls.closed += 1; },
		onCloseKey: (handler: () => void): void => {},
		onConfig: (handler: (c: Config | null, fontFamily: string, error: string) => void): void => {},
		fontFamily: "",
	};
}

function paneOf(t: Term, calls: Calls): PaneModel {
	return createPane(t, hostFor(calls), defaults(), createNotice(), createPasteDialog());
}

test "a program's title reaches the window" {
	assert onFresh("\x1b]2;vim\x07", (t: Term, sink: Sink): void => {
		const calls = noCalls();
		const m = paneOf(t, calls);
		m.refresh();
		assert calls.title == "vim";
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
		m.failed("key", "EncodeFailed");
		m.failed("key", "EncodeFailed");
		assert calls.fatal == "";
		assert calls.noted == "key: EncodeFailed\n";
		assert m.notice.text.endsWith("key: EncodeFailed");
		assert t.session !== null;
	}).ok;
}

test "an internal failure before the shell started is fatal" {
	const opened = openTerm((cols: int32, rows: int32): Result<Pty, PtyError> => {
		return Result.ok(Replay.ofText("").toPty());
	});
	assert opened.ok;
	if (opened.ok) {
		const calls = noCalls();
		const m = paneOf(opened.value, calls);
		m.failed("fit", "SessionStartFailed");
		assert calls.fatal == "fit: SessionStartFailed";
		assert calls.noted == "";
		opened.value.shutdown();
	}
}

function closeAsked(this m: PaneModel): boolean {
	if (!m.controls.closeKey(m.term, m.bridge()).ok) { return false; }
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
	body: (m: PaneModel, calls: Calls) => void,
): Result<void, TermError> {
	const t = try openTerm((cols: int32, rows: int32): Result<Pty, PtyError> => {
		const base = Replay.ofText("last output").toPty();
		return Result.ok({
			...base,
			exitCode: (): int32 | null => { return code; },
			exitSignal: (): int32 => { return signal; },
		});
	});
	defer t.shutdown();
	const _fit = try t.fit(20, 3);
	t.spawnedAt -= lateMs;
	const calls = noCalls();
	const m = paneOf(t, calls);
	m.refresh();
	body(m, calls);
	return Result.ok(null);
}

test "a shell killed by a signal keeps the window and names the signal; a key closes it" {
	assert afterExit(137, 9, 1000, (m: PaneModel, calls: Calls): void => {
		assert calls.exits == "";
		assert m.notice.text == "the shell was killed by signal 9, press any key to close";
		assert m.term.grid.at(0).line.text.trimEnd() == "last output";
		m.keyed(key("ShiftLeft", 0));
		m.keyed(key("MetaRight", 0));
		assert calls.exits == "";
		m.keyed(key("KeyA", 0));
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
		m.keyed(key("Enter", 0));
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
	assert afterExit(137, 9, 1000, (m: PaneModel, calls: Calls): void => {
		const text = m.notice.text;
		m.focusChanged(false);
		m.keyReleased(key("KeyA", 0));
		assert m.notice.text == text;
		assert m.controls.holding();
		assert calls.fatal == "";
		assert calls.noted == "";
	}).ok;
}
