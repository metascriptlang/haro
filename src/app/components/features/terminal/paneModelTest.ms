import { Config, defaults } from "../../../../config/config";
import { createNotice } from "../notice/notice";
import { createPasteDialog } from "../paste/pasteDialog";
import { AppHost, PaneModel, createPane, refresh } from "./paneModel";
import { Term } from "./term";
import { Sink, onFresh } from "./terminalRig";

interface Calls {
	fatal: string;
	title: string;
}

function noCalls(): Calls {
	return { fatal: "", title: "" };
}

function hostFor(calls: Calls): AppHost {
	return {
		onWake: (handler: () => void): void => {},
		schedule: (run: () => void): void => {},
		exited: (code: int32): void => {},
		fail: (message: string): void => { calls.fatal = message; },
		setTitle: (title: string): void => { calls.title = title; },
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
