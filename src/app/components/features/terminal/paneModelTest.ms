import { Config, defaults } from "../../../../config/config";
import { writeText } from "../../../../vt/vt";
import { createNotice } from "../notice/notice";
import { createPasteDialog } from "../paste/pasteDialog";
import { AppHost, PaneModel, createPane, refresh } from "./paneModel";
import { Term } from "./term";
import { Sink, onFresh } from "./terminalRig";

interface Calls {
	fatal: string;
	title: string;
	notified: string;
}

function noCalls(): Calls {
	return { fatal: "", title: "", notified: "" };
}

function hostFor(calls: Calls): AppHost {
	return {
		onWake: (handler: () => void): void => {},
		schedule: (run: () => void): void => {},
		exited: (code: int32): void => {},
		fail: (message: string): void => { calls.fatal = message; },
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
