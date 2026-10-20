import { NeonNode } from "../../../neon/src/render/node";
import { Void } from "../../../neon/src/components/primitives";
import { Config } from "../config/config";
import { Notice, createNotice } from "./components/features/notice/notice";
import { PasteDialog, createPasteDialog } from "./components/features/paste/pasteDialog";
import { Term } from "./components/features/terminal/term";
import { AppHost, connectHost, createPane } from "./components/features/terminal/paneModel";
import { cancelPaste, confirmPaste } from "./components/features/terminal/paneEvents";
import { TerminalPane } from "./components/features/terminal/terminalPane";

export function App(t: Term, host: AppHost, started: Config): NeonNode {
	const notice = createNotice();
	const dialog = createPasteDialog();
	const pane = createPane(t, host, started, notice, dialog);
	pane.connectHost();
	return <Void style={{ backgroundColor: pane.background(), padding: pane.padding() }}>
		<TerminalPane model={pane} />
		<PasteDialog
			model={dialog}
			metrics={pane.metrics}
			onConfirm={(): void => { pane.confirmPaste(); }}
			onCancel={(): void => { pane.cancelPaste(); }}
		/>
		<Notice model={notice} metrics={pane.metrics} inset={pane.padding()} />
	</Void>;
}
