import { PaneId, TabId } from "./tree";

export type HostId = distinct int32;
@delegate export function `==`(this a: HostId, b: HostId): boolean;

export struct HostPane {
	host: HostId;
	pane: PaneId;
}

export struct HostTab {
	host: HostId;
	tab: TabId;
}

export function `==`(this a: HostPane, b: HostPane): boolean {
	return a.host == b.host && a.pane == b.pane;
}

export function `==`(this a: HostTab, b: HostTab): boolean {
	return a.host == b.host && a.tab == b.tab;
}

test "a pane or tab is the same only on the same host" {
	const one = 1 as PaneId;
	const local: HostPane = { host: 0 as HostId, pane: one };
	const remote: HostPane = { host: 1 as HostId, pane: one };
	assert local == local;
	assert !(local == remote);
	const tab = 1 as TabId;
	const here: HostTab = { host: 0 as HostId, tab: tab };
	const there: HostTab = { host: 1 as HostId, tab: tab };
	assert !(here == there);
}
