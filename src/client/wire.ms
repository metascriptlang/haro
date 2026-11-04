import {
	Message,
	MessageKind,
	PaneScreen,
	ScreenFormat,
} from "../server/protocol";
import { Seed } from "../pty/remote";
import { PaneId, TabId } from "../workspace/tree";
import { Tab } from "../workspace/workspace";

export struct Layout {
	tabs: Tab[];
	active: TabId | null;
}

export struct Screen {
	pane: PaneId;
	seed: Seed;
}

export struct ScreenParts {
	layout: Layout | null;
	screens: Screen[];
}

function screenOf(p: PaneScreen): Screen {
	return {
		pane: p.pane,
		seed: {
			native: p.format == ScreenFormat.Native,
			cols: p.cols,
			rows: p.rows,
			bytes: [...p.screen],
		},
	};
}

export function screenParts(m: Message): ScreenParts | null {
	if (m.kind != MessageKind.Snapshot) { return null; }
	return {
		layout: { tabs: m.tabs, active: m.active },
		screens: m.panes.map(screenOf),
	};
}

function paneScreenOf(s: Screen): PaneScreen {
	return {
		pane: s.pane,
		cols: s.seed.cols,
		rows: s.seed.rows,
		format: s.seed.native ? ScreenFormat.Native : ScreenFormat.VtBytes,
		screen: [...s.seed.bytes],
	};
}

export function screenMessages(layout: Layout, screens: Screen[]): Message[] {
	return [{
		kind: MessageKind.Snapshot,
		tabs: layout.tabs,
		active: layout.active,
		panes: screens.map(paneScreenOf),
	}];
}
