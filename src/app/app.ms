import { NeonNode } from "../../../neon/src/render/node";
import { Void } from "../../../neon/src/components/primitives";
import { Config } from "../config/config";
import { Notice, NoticeModel, open } from "./components/features/notice/notice";
import { PasteDialog, PasteDialogModel, open } from "./components/features/paste/pasteDialog";
import { IoPort } from "../controller/io";
import { View } from "./frame";
import { Stats } from "./stats";
import { AppHost, PaneModel, connectHost, open } from "./components/features/terminal/paneModel";
import { cancelDialog, confirmDialog } from "./components/features/terminal/paneEvents";
import { TerminalPane } from "./components/features/terminal/terminalPane";
import { CursorTrail } from "./components/content/cursor";

export function App(
	io: IoPort,
	view: View,
	host: AppHost,
	started: Config,
	stats: Stats,
): NeonNode {
	const notice = NoticeModel.open();
	const dialog = PasteDialogModel.open();
	const pane = PaneModel.open(
		io,
		view,
		host.desktop,
		host.report,
		host.timing,
		host.keyHook,
		host.fontFamily,
		started,
		notice,
		dialog,
		stats,
	);
	pane.connectHost(host.events);
	return <Void style={{ backgroundColor: pane.background() }}>
		<TerminalPane model={pane} />
		<CursorTrail model={pane.cursor} />
		<PasteDialog
			model={dialog}
			metrics={pane.metrics}
			onConfirm={(): void => { pane.confirmDialog(); }}
			onCancel={(): void => { pane.cancelDialog(); }}
		/>
		<Notice model={notice} metrics={pane.metrics} inset={pane.padding()} />
	</Void>;
}
