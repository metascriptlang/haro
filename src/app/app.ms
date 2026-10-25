import { NeonNode } from "../../../neon/src/render/node";
import { Void } from "../../../neon/src/components/primitives";
import { Config } from "../config/config";
import { Notice, createNotice } from "./components/features/notice/notice";
import { PasteDialog, createPasteDialog } from "./components/features/paste/pasteDialog";
import { Term } from "./components/features/terminal/term";
import { AppHost, connectHost, createPane } from "./components/features/terminal/paneModel";
import { cancelDialog, confirmDialog } from "./components/features/terminal/paneEvents";
import { TerminalPane } from "./components/features/terminal/terminalPane";
import { CursorTrail } from "./components/content/cursor";

export function App(t: Term, host: AppHost, started: Config): NeonNode {
	const notice = createNotice();
	const dialog = createPasteDialog();
	const pane = createPane(t, host, started, notice, dialog);
	pane.connectHost();
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
