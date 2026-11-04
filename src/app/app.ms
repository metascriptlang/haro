import { NeonNode } from "../../../neon/src/render/node";
import { NeonEvent } from "../../../neon/src/render/event";
import { Show } from "../../../neon/src/macros/ui/flow";
import { createEffect } from "../../../neon/src/core/effect";
import { Cleanup } from "../../../neon/src/core/types";
import { PixelRatio } from "../../../neon/src/api/pixelRatio";
import { View, Void } from "../../../neon/src/components/primitives";
import { Axis, PaneId, TabId } from "../workspace/tree";
import { CommandKind } from "../workspace/workspace";
import { Notice } from "./components/features/notice/notice";
import { PasteDialog } from "./components/features/paste/pasteDialog";
import { cancelDialog, confirmDialog } from "./components/features/terminal/paneEvents";
import { TerminalPane } from "./components/features/terminal/terminalPane";
import { PaneFrame } from "./components/features/workspace/paneFrame";
import { Sidebar } from "./components/features/sidebar/sidebar";
import { ConfirmClose } from "./components/features/confirm/confirmClose";
import { CursorTrail } from "./components/content/cursor";
import { paneOf } from "./panes";
import {
	WorkspaceView,
	askClosePane,
	begin,
	cancelled,
	confirmed,
	connect,
	laidOut,
	relayout,
	selectTab,
	send,
} from "./workspaceView";

function PaneView(props: { view: WorkspaceView; id: PaneId }): NeonNode {
	const v = props.view;
	const id = props.id;
	const running = v.panes.paneOf(id);
	if (running === null) { return <View style={{ flexGrow: 1 }} />; }
	const m = running.model;
	return <View style={{ flexGrow: 1 }}>
		<TerminalPane model={m} focused={v.layout().focused == id} />
		<CursorTrail model={m.cursor} />
		<PasteDialog
			model={m.dialog}
			metrics={m.metrics}
			onConfirm={(): void => { m.confirmDialog(); }}
			onCancel={(): void => { m.cancelDialog(); }}
		/>
		<Notice model={m.notice} metrics={m.metrics} inset={0} />
	</View>;
}

function SidebarOf(props: { view: WorkspaceView }): NeonNode {
	const v = props.view;
	return <Sidebar
		tabs={v.tabs()}
		cols={v.chrome().sidebarCols}
		metrics={v.font.metrics}
		foreground={v.chrome().foreground}
		background={v.chrome().background}
		accent={v.chrome().accent}
		dim={v.chrome().dim}
		onSelectTab={(id: int32): void => { v.selectTab(id as TabId); }}
		onFocusPane={(id: int32): void => {
			v.send({ kind: CommandKind.FocusPane, pane: id as PaneId });
		}}
		onClosePane={(id: int32): void => { v.askClosePane(id as PaneId); }}
	/>;
}

export function App(v: WorkspaceView): NeonNode {
	v.connect();
	createEffect(
		(): number => PixelRatio.get(),
		(ratio: number, was: number | null): Cleanup | null => {
			if (was !== null) { v.relayout(); }
			return null;
		},
	);
	v.begin();
	return <Void style={{ backgroundColor: v.chrome().background }}>
		<View style={{ flexGrow: 1, flexDirection: "row" }}>
			<Show when={v.sidebarShown() && v.chrome().sidebarLeft}>
				<SidebarOf view={v} />
			</Show>
			<View
				style={{ flexGrow: 1, flexShrink: 1, flexBasis: 0 }}
				onLayout={(e: NeonEvent): void => { v.laidOut(e); }}>
				<PaneFrame
					layout={v.layout()}
					metrics={v.font.metrics}
					inset={v.inset()}
					look={v.look()}
					pane={(id: PaneId): NeonNode => <PaneView view={v} id={id} />}
					onFocusPane={(id: PaneId): void => {
						v.send({ kind: CommandKind.FocusPane, pane: id });
					}}
					onMoveDivider={(before: PaneId, axis: Axis, by: int32): void => {
						v.send({
							kind: CommandKind.MoveDivider,
							pane: before,
							axis: axis,
							by: by,
						});
					}}
				/>
			</View>
			<Show when={v.sidebarShown() && !v.chrome().sidebarLeft}>
				<SidebarOf view={v} />
			</Show>
		</View>
		<ConfirmClose
			model={v.confirm}
			metrics={v.font.metrics}
			onConfirm={(): void => { v.confirmed(); }}
			onCancel={(): void => { v.cancelled(); }}
		/>
	</Void>;
}
