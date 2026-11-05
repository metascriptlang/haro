import { NeonNode } from "../../../neon/src/render/node";
import { NeonEvent } from "../../../neon/src/render/event";
import { For, Show } from "../../../neon/src/macros/ui/flow";
import { Accessor, untrack } from "../../../neon/src/core/signal";
import { createEffect } from "../../../neon/src/core/effect";
import { Cleanup } from "../../../neon/src/core/types";
import { PixelRatio } from "../../../neon/src/api/pixelRatio";
import { View, Void } from "../../../neon/src/components/primitives";
import { Axis, PaneId, Placed, TabId } from "../workspace/tree";
import { HostId, HostPane } from "../workspace/hosted";
import { CommandKind, WorkspaceCommand } from "../workspace/workspace";
import { Notice } from "./components/features/notice/notice";
import { PasteDialog } from "./components/features/paste/pasteDialog";
import { cancelDialog, confirmDialog } from "./components/features/terminal/paneEvents";
import { TerminalPane } from "./components/features/terminal/terminalPane";
import { PaneFrame } from "./components/features/workspace/paneFrame";
import { Sidebar } from "./components/features/sidebar/sidebar";
import { ConfirmClose } from "./components/features/confirm/confirmClose";
import { HostDialog } from "./components/features/hosts/hostDialog";
import { CursorTrail } from "./components/content/cursor";
import {
	WorkspaceView,
	addHost,
	askClosePane,
	begin,
	cancelled,
	confirmed,
	connect,
	focusPane,
	hostDialogShut,
	hostPicked,
	hostOf,
	laidOut,
	newTabOn,
	paneAt,
	relayout,
	selectTab,
	sendTo,
} from "./workspaceView";

function PaneView(props: { view: WorkspaceView; at: HostPane }): NeonNode {
	const v = props.view;
	const id = props.at.pane;
	const laidOutAndRunning = (): boolean =>
		v.layout().panes.some((p: Placed): boolean => p.pane.id == id) && v.paneAt(props.at) !== null;
	return <View style={{ flexGrow: 1 }}>
		<Show when={laidOutAndRunning()}>
			<RunningPaneView view={v} at={props.at} />
		</Show>
	</View>;
}

function RunningPaneView(props: { view: WorkspaceView; at: HostPane }): NeonNode {
	const v = props.view;
	const id = props.at.pane;
	const running = v.paneAt(props.at);
	if (running === null) { throw new Error(`internal: pane ${id as int32} is shown before it runs`); }
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
		hosts={v.tabs()}
		cols={v.chrome().sidebarCols}
		metrics={v.font.metrics}
		foreground={v.chrome().foreground}
		background={v.chrome().background}
		accent={v.chrome().accent}
		dim={v.chrome().dim}
		onHost={(host: int32): void => { v.newTabOn(host as HostId); }}
		onSelectTab={(host: int32, id: int32): void => {
			v.selectTab({ host: host as HostId, tab: id as TabId });
		}}
		onFocusPane={(host: int32, id: int32): void => {
			v.focusPane({ host: host as HostId, pane: id as PaneId });
		}}
		onClosePane={(host: int32, id: int32): void => {
			v.askClosePane({ host: host as HostId, pane: id as PaneId });
		}}
	/>;
}

function HostFrame(props: { view: WorkspaceView; host: HostId }): NeonNode {
	const v = props.view;
	const host = props.host;
	const send = (c: WorkspaceCommand): void => {
		const h = v.hostOf(host);
		if (h !== null) { v.sendTo(h, c); }
	};
	return <PaneFrame
		layout={v.layout()}
		metrics={v.font.metrics}
		inset={v.inset()}
		look={v.look()}
		pane={(id: PaneId): NeonNode => <PaneView view={v} at={{ host: host, pane: id }} />}
		onFocusPane={(id: PaneId): void => { v.focusPane({ host: host, pane: id }); }}
		onMoveDivider={(before: PaneId, axis: Axis, by: int32): void => {
			send({ kind: CommandKind.MoveDivider, pane: before, axis: axis, by: by });
		}}
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
				<For each={[v.shown()]} keyed={(h: HostId): number => h as int32}>
					{(shown: Accessor<HostId>): NeonNode => <HostFrame view={v} host={untrack((): HostId => shown())} />}
				</For>
			</View>
			<Show when={v.sidebarShown() && !v.chrome().sidebarLeft}>
				<SidebarOf view={v} />
			</Show>
		</View>
		<HostDialog
			model={v.hostDialog}
			metrics={v.font.metrics}
			onPick={(id: int32): void => { v.hostPicked(id as HostId); }}
			onAdd={(label: string, address: string): string => {
				const refusal = v.addHost(label, address);
				if (refusal == "") { v.hostDialogShut(); }
				return refusal;
			}}
			onClose={(): void => { v.hostDialogShut(); }}
		/>
		<ConfirmClose
			model={v.confirm}
			metrics={v.font.metrics}
			onConfirm={(): void => { v.confirmed(); }}
			onCancel={(): void => { v.cancelled(); }}
		/>
	</Void>;
}
