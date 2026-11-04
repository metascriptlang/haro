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

export struct SidebarHost {
	id: int32;
	label: string;
	state: string;
	reason: string;
	header: boolean;
	live: boolean;
	tabs: SidebarTab[];
}

export enum RowKind {
	Host,
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
	host: int32;
	id: int32;
	indent: int32;
	text: string;
	detail: string;
	role: RowRole;
}

const KEYS_PER_HOST: int64 = 68719476736;

function fit(text: string, cols: int32): string {
	return cols <= 0 ? "" : visible(text, cols);
}

function keyOf(host: SidebarHost, kind: RowKind, id: int32): int64 {
	return (host.id as int64) * KEYS_PER_HOST + (id as int64) * 4 + (kind as int64);
}

function hostRow(host: SidebarHost, cols: int32): SidebarRow {
	const text = fit(host.state == "" ? host.label : `${host.label} ${host.state}`, cols);
	const left = cols - text.length - 1;
	const role = host.state == "refused"
		? RowRole.Alert
		: host.live ? RowRole.Normal : RowRole.Dim;
	return {
		key: keyOf(host, RowKind.Host, 0),
		kind: RowKind.Host,
		host: host.id,
		id: host.id,
		indent: 0,
		text: text,
		detail: host.live && host.reason == "" || left <= 0 ? "" : " " + fit(host.reason, left),
		role: role,
	};
}

function tabRow(host: SidebarHost, tab: SidebarTab, index: int32, cols: int32): SidebarRow {
	const number = index < NUMBERED_TABS ? `${index + 1}` : " ";
	const mark = tab.attention ? "!" : " ";
	const plain = host.live ? RowRole.Normal : RowRole.Dim;
	const role = tab.active
		? RowRole.Selected
		: tab.attention ? RowRole.Alert : plain;
	return {
		key: keyOf(host, RowKind.Tab, tab.id),
		kind: RowKind.Tab,
		host: host.id,
		id: tab.id,
		indent: 0,
		text: fit(`${number}${mark} ${tab.title}`, cols),
		detail: "",
		role: role,
	};
}

function paneRow(host: SidebarHost, pane: SidebarPane, cols: int32): SidebarRow {
	const room = cols - PANE_INDENT;
	const mark = pane.focused ? ">" : " ";
	const badge = pane.badge == "" ? " " : pane.badge;
	const title = pane.title == "" ? pane.cwd : pane.title;
	const text = fit(`${mark}${badge} ${title}`, room);
	const left = room - text.length - 1;
	const showCwd = pane.cwd != "" && pane.cwd != title && left > 0;
	return {
		key: keyOf(host, RowKind.Pane, pane.id),
		kind: RowKind.Pane,
		host: host.id,
		id: pane.id,
		indent: PANE_INDENT,
		text: text,
		detail: showCwd ? " " + fit(pane.cwd, left) : "",
		role: pane.focused && host.live ? RowRole.Normal : RowRole.Dim,
	};
}

export function sidebarRows(hosts: SidebarHost[], cols: int32): SidebarRow[] {
	let rows: SidebarRow[] = [];
	let index: int32 = 0;
	for (const host of hosts) {
		if (host.header) { rows.push(hostRow(host, cols)); }
		for (const tab of host.tabs) {
			rows.push(tabRow(host, tab, index, cols));
			index += 1;
			for (const pane of tab.panes) { rows.push(paneRow(host, pane, cols)); }
		}
	}
	return rows;
}

export function Sidebar(props: {
	hosts: Accessor<SidebarHost[]>;
	cols: Accessor<int32>;
	metrics: CellMetrics;
	foreground: Accessor<string>;
	background: Accessor<string>;
	accent: Accessor<string>;
	dim: Accessor<string>;
	onHost: (host: int32) => void;
	onSelectTab: (host: int32, id: int32) => void;
	onFocusPane: (host: int32, id: int32) => void;
	onClosePane: (host: int32, id: int32) => void;
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
			props.onClosePane(r.host, r.id);
			return;
		}
		if (e.button != LEFT_BUTTON) { return; }
		match (r.kind) {
			RowKind.Host => props.onHost(r.host),
			RowKind.Tab => props.onSelectTab(r.host, r.id),
			RowKind.Pane => props.onFocusPane(r.host, r.id),
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
			each={sidebarRows(props.hosts(), props.cols())}
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

function host(id: int32, label: string, tabs: SidebarTab[]): SidebarHost {
	return { id: id, label: label, state: "", reason: "", header: true, live: true, tabs: tabs };
}

function rowsOf(tabs: SidebarTab[], cols: int32): SidebarRow[] {
	let only = host(0, "", tabs);
	only.header = false;
	return sidebarRows([only], cols);
}

test "tabs list in order, each followed by its panes one cell in" {
	const rows = rowsOf([
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
	const rows = rowsOf([quiet, loud], 20);
	assert rows[0].text == "1  build";
	assert rows[1].text == "2! build";
}

test "tabs past the ninth have no number" {
	let tabs: SidebarTab[] = [];
	for (let i = 0; i < 10; i++) { tabs.push(tab(i, false, [])); }
	const rows = rowsOf(tabs, 20);
	assert rows[8].text == "9  t8";
	assert rows[9].text == "   t9";
}

test "the active tab is selected, an attention tab alerts, others are plain" {
	let alert = tab(2, false, []);
	alert.attention = true;
	let both = tab(3, true, []);
	both.attention = true;
	const rows = rowsOf([tab(1, false, []), alert, both], 20);
	assert rows[0].role == RowRole.Normal;
	assert rows[1].role == RowRole.Alert;
	assert rows[2].role == RowRole.Selected;
}

test "the focused pane is marked and plain, the others dim" {
	const rows = rowsOf([
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
	const rows = rowsOf([tab(1, true, [busy])], 20);
	assert rows[1].text == " * claude";
}

test "a pane's cwd follows its title in what room is left" {
	let p = pane(1, "zsh", true);
	p.cwd = "~/src/haro";
	const rows = rowsOf([tab(1, true, [p])], 20);
	assert rows[1].text == ">  zsh";
	assert rows[1].detail == " ~/src/haro";
	const narrow = rowsOf([tab(1, true, [p])], 12);
	assert narrow[1].detail == " ~/s…";
}

test "a pane without a title shows its cwd once" {
	let p = pane(1, "", true);
	p.cwd = "~/src";
	const rows = rowsOf([tab(1, true, [p])], 20);
	assert rows[1].text == ">  ~/src";
	assert rows[1].detail == "";
}

test "rows are cut to the width, a pane's to the width left of its indent" {
	let long = tab(1, true, [pane(1, "a-very-long-title", true)]);
	long.title = "another-long-title";
	const rows = rowsOf([long], 8);
	assert rows[0].text == "1  anot…";
	assert rows[1].text == ">  a-v…";
	assert rowsOf([long], 0)[0].text == "";
}

test "tab and pane rows sharing an id keep distinct keys" {
	const rows = rowsOf([tab(4, true, [pane(4, "zsh", true)])], 20);
	assert rows[0].key != rows[1].key;
}

test "hosts list in order, each a header row over its tabs, numbered across the window" {
	const rows = sidebarRows([
		host(0, "local", [tab(1, true, [pane(1, "zsh", true)])]),
		host(1, "build", [tab(1, false, [pane(1, "make", true)]), tab(2, false, [])]),
	], 20);
	assert rows.length == 7;
	assert rows[0].kind == RowKind.Host && rows[0].text == "local" && rows[0].host == 0;
	assert rows[1].kind == RowKind.Tab && rows[1].text == "1  t1";
	assert rows[3].kind == RowKind.Host && rows[3].text == "build" && rows[3].host == 1;
	assert rows[4].text == "2  t1" && rows[4].host == 1;
	assert rows[6].text == "3  t2";
}

test "the same tab and pane ids on two hosts keep distinct keys and name their host" {
	const rows = sidebarRows([
		host(0, "local", [tab(1, true, [pane(1, "zsh", true)])]),
		host(1, "build", [tab(1, false, [pane(1, "zsh", true)])]),
	], 20);
	const keys: int64[] = rows.map((r: SidebarRow): int64 => r.key);
	for (let i = 0; i < keys.length; i++) {
		for (let j = 0; j < i; j++) { assert keys[i] != keys[j]; }
	}
	assert rows[2].id == rows[5].id && rows[2].host == 0 && rows[5].host == 1;
}

test "an offline host shows its state and reason and dims its tabs, a refused one alerts" {
	let down = host(1, "build", [tab(1, false, [pane(1, "zsh", true)])]);
	down.state = "offline";
	down.reason = "no route";
	down.live = false;
	const rows = sidebarRows([down], 30);
	assert rows[0].text == "build offline" && rows[0].detail == " no route";
	assert rows[0].role == RowRole.Dim;
	assert rows[1].role == RowRole.Dim && rows[2].role == RowRole.Dim;
	let no = host(2, "gpu", []);
	no.state = "refused";
	no.live = false;
	assert sidebarRows([no], 30)[0].role == RowRole.Alert;
}
