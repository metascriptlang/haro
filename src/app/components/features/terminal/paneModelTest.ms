import { Config, defaults } from "../../../../config/config";
import { Pty, PtyError } from "../../../../pty/transport";
import { Replay } from "../../../../pty/replay";
import { writeText } from "../../../../vt/vt";
import { createNotice } from "../notice/notice";
import { createPasteDialog } from "../paste/pasteDialog";
import { AppHost, PaneModel, createPane, failed, refresh } from "./paneModel";
import { Term, openTerm, shutdown } from "./term";
import { Sink, onFresh, onTerm } from "./terminalRig";

interface Calls {
	fatal: string;
	noted: string;
	title: string;
	notified: string;
}

function noCalls(): Calls {
	return { fatal: "", noted: "", title: "", notified: "" };
}

function hostFor(calls: Calls): AppHost {
	return {
		onWake: (handler: () => void, failed: (what: string, error: string) => void): void => {},
		schedule: (run: () => void): void => {},
		exited: (code: int32): void => {},
		fail: (message: string): void => { calls.fatal = message; },
		note: (message: string): void => { calls.noted += `${message}\n`; },
		setTitle: (title: string): void => { calls.title = title; },
		notify: (title: string, body: string): void => { calls.notified += `${title}|${body}\n`; },
		openLink: (uri: string): void => {},
		close: (): void => {},
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
