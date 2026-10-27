import { NeonNode } from "../../../neon/src/render/node";
import { Void } from "../../../neon/src/components/primitives";
import { Config } from "../config/config";
import { Notice, createNotice } from "./components/features/notice/notice";
import { PasteDialog, createPasteDialog } from "./components/features/paste/pasteDialog";
import { IoPort } from "./components/features/terminal/io";
import { View } from "./frame";
import { Stats } from "./stats";
import { AppHost, connectHost, createPane } from "./components/features/terminal/paneModel";
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
	const notice = createNotice();
	const dialog = createPasteDialog();
	const pane = createPane(
		io,
		view,
		host.desktop,
		host.report,
		host.timing,
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
