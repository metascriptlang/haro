import { Accessor } from "../../../../../../neon/src/core/signal";
import { ForKeyedBy } from "../../../../../../neon/src/macros/ui/flow";
import { NeonNode } from "../../../../../../neon/src/render/node";
import { NeonEvent } from "../../../../../../neon/src/render/event";
import { View } from "../../../../../../neon/src/components/primitives";
import { visible } from "../../../../input/paste";
import { CellMetrics, CellText } from "../../ui/cellText";

const NUMBERED_TABS: int32 = 9;
const PANE_INDENT: int32 = 1;
const LEFT_BUTTON = 1;
const MIDDLE_BUTTON = 3;

export struct SidebarPane {
	id: int32;
	title: string;
	cwd: string;
	focused: boolean;
	badge: string;
}

export struct SidebarTab {
	id: int32;
	title: string;
	active: boolean;
	attention: boolean;
	panes: SidebarPane[];
}

export enum RowKind {
	Tab,
	Pane,
}

export enum RowRole {
	Selected,
	Alert,
	Normal,
	Dim,
}

export struct SidebarRow {
	key: int64;
	kind: RowKind;
	id: int32;
	indent: int32;
	text: string;
	detail: string;
	role: RowRole;
}

function fit(text: string, cols: int32): string {
	return cols <= 0 ? "" : visible(text, cols);
}

function tabRow(tab: SidebarTab, index: int32, cols: int32): SidebarRow {
	const number = index < NUMBERED_TABS ? `${index + 1}` : " ";
	const mark = tab.attention ? "!" : " ";
	const role = tab.active
		? RowRole.Selected
		: tab.attention ? RowRole.Alert : RowRole.Normal;
	return {
		key: (tab.id as int64) * 2,
		kind: RowKind.Tab,
		id: tab.id,
		indent: 0,
		text: fit(`${number}${mark} ${tab.title}`, cols),
		detail: "",
		role: role,
	};
}

function paneRow(pane: SidebarPane, cols: int32): SidebarRow {
	const room = cols - PANE_INDENT;
	const mark = pane.focused ? ">" : " ";
	const badge = pane.badge == "" ? " " : pane.badge;
	const title = pane.title == "" ? pane.cwd : pane.title;
	const text = fit(`${mark}${badge} ${title}`, room);
	const left = room - text.length - 1;
	const showCwd = pane.cwd != "" && pane.cwd != title && left > 0;
	return {
		key: (pane.id as int64) * 2 + 1,
		kind: RowKind.Pane,
		id: pane.id,
		indent: PANE_INDENT,
		text: text,
		detail: showCwd ? " " + fit(pane.cwd, left) : "",
		role: pane.focused ? RowRole.Normal : RowRole.Dim,
	};
}

export function sidebarRows(tabs: SidebarTab[], cols: int32): SidebarRow[] {
	let rows: SidebarRow[] = [];
	for (let i = 0; i < tabs.length; i++) {
		const tab = tabs[i];
		rows.push(tabRow(tab, i, cols));
		for (const pane of tab.panes) { rows.push(paneRow(pane, cols)); }
	}
	return rows;
}

export function Sidebar(props: {
	tabs: Accessor<SidebarTab[]>;
	cols: Accessor<int32>;
	metrics: CellMetrics;
	foreground: Accessor<string>;
	background: Accessor<string>;
	accent: Accessor<string>;
	dim: Accessor<string>;
	onSelectTab: (id: int32) => void;
	onFocusPane: (id: int32) => void;
	onClosePane: (id: int32) => void;
}): NeonNode {
	const m = props.metrics;
	const colorOf = (role: RowRole): string => match (role) {
		RowRole.Selected => props.background(),
		RowRole.Alert => props.accent(),
		RowRole.Normal => props.foreground(),
		RowRole.Dim => props.dim(),
	};
	const pressed = (r: SidebarRow, e: NeonEvent): void => {
		if (r.kind == RowKind.Pane && e.button == MIDDLE_BUTTON) {
			props.onClosePane(r.id);
			return;
		}
		if (e.button != LEFT_BUTTON) { return; }
		match (r.kind) {
			RowKind.Tab => props.onSelectTab(r.id),
			RowKind.Pane => props.onFocusPane(r.id),
		};
	};
	const row = (item: Accessor<SidebarRow>, index: Accessor<number>): NeonNode =>
		<View
			style={{
				flexDirection: "row",
				height: m.rowHeight(),
				paddingLeft: item().indent * m.cellWidth(),
				backgroundColor: item().role == RowRole.Selected
					? props.accent()
					: props.background(),
			}}
			onPointerDown={(e: NeonEvent): void => { pressed(item(), e); }}>
			<CellText
				metrics={m}
				spans={[
					{ text: item().text, style: { color: colorOf(item().role) } },
					{ text: item().detail, style: { color: props.dim() } },
				]}
				widths={[]}
			/>
		</View>;
	return <View
		style={{
			flexDirection: "column",
			flexGrow: 0,
			flexShrink: 0,
			flexBasis: props.cols() * m.cellWidth(),
			width: props.cols() * m.cellWidth(),
			overflow: "hidden",
			backgroundColor: props.background(),
		}}>
		<ForKeyedBy
			each={sidebarRows(props.tabs(), props.cols())}
			keyed={(r: SidebarRow): int64 => r.key}
			usesIndex={false}>
			{row}
		</ForKeyedBy>
	</View>;
}

function pane(id: int32, title: string, focused: boolean): SidebarPane {
	return { id: id, title: title, cwd: "", focused: focused, badge: "" };
}

function tab(id: int32, active: boolean, panes: SidebarPane[]): SidebarTab {
	return { id: id, title: `t${id}`, active: active, attention: false, panes: panes };
}

test "tabs list in order, each followed by its panes one cell in" {
	const rows = sidebarRows([
		tab(7, true, [pane(1, "zsh", true), pane(2, "vim", false)]),
		tab(3, false, [pane(4, "top", true)]),
	], 20);
	assert rows.length == 5;
	assert rows[0].kind == RowKind.Tab && rows[0].id == 7 && rows[0].indent == 0;
	assert rows[1].kind == RowKind.Pane && rows[1].id == 1 && rows[1].indent == 1;
	assert rows[2].id == 2;
	assert rows[3].kind == RowKind.Tab && rows[3].id == 3;
	assert rows[4].id == 4;
}

test "a tab row shows its number, then its attention mark, then its title" {
	let quiet = tab(5, false, []);
	quiet.title = "build";
	let loud = quiet;
	loud.attention = true;
	const rows = sidebarRows([quiet, loud], 20);
	assert rows[0].text == "1  build";
	assert rows[1].text == "2! build";
}

test "tabs past the ninth have no number" {
	let tabs: SidebarTab[] = [];
	for (let i = 0; i < 10; i++) { tabs.push(tab(i, false, [])); }
	const rows = sidebarRows(tabs, 20);
	assert rows[8].text == "9  t8";
	assert rows[9].text == "   t9";
}

test "the active tab is selected, an attention tab alerts, others are plain" {
	let alert = tab(2, false, []);
	alert.attention = true;
	let both = tab(3, true, []);
	both.attention = true;
	const rows = sidebarRows([tab(1, false, []), alert, both], 20);
	assert rows[0].role == RowRole.Normal;
	assert rows[1].role == RowRole.Alert;
	assert rows[2].role == RowRole.Selected;
}

test "the focused pane is marked and plain, the others dim" {
	const rows = sidebarRows([
		tab(1, true, [pane(1, "zsh", true), pane(2, "vim", false)]),
	], 20);
	assert rows[1].text == ">  zsh";
	assert rows[1].role == RowRole.Normal;
	assert rows[2].text == "   vim";
	assert rows[2].role == RowRole.Dim;
}

test "a pane's badge takes the cell after its focus mark" {
	let busy = pane(1, "claude", false);
	busy.badge = "*";
	const rows = sidebarRows([tab(1, true, [busy])], 20);
	assert rows[1].text == " * claude";
}

test "a pane's cwd follows its title in what room is left" {
	let p = pane(1, "zsh", true);
	p.cwd = "~/src/haro";
	const rows = sidebarRows([tab(1, true, [p])], 20);
	assert rows[1].text == ">  zsh";
	assert rows[1].detail == " ~/src/haro";
	const narrow = sidebarRows([tab(1, true, [p])], 12);
	assert narrow[1].detail == " ~/s…";
}

test "a pane without a title shows its cwd once" {
	let p = pane(1, "", true);
	p.cwd = "~/src";
	const rows = sidebarRows([tab(1, true, [p])], 20);
	assert rows[1].text == ">  ~/src";
	assert rows[1].detail == "";
}

test "rows are cut to the width, a pane's to the width left of its indent" {
	let long = tab(1, true, [pane(1, "a-very-long-title", true)]);
	long.title = "another-long-title";
	const rows = sidebarRows([long], 8);
	assert rows[0].text == "1  anot…";
	assert rows[1].text == ">  a-v…";
	assert sidebarRows([long], 0)[0].text == "";
}

test "tab and pane rows sharing an id keep distinct keys" {
	const rows = sidebarRows([tab(4, true, [pane(4, "zsh", true)])], 20);
	assert rows[0].key != rows[1].key;
}
