import { Message, MessageKind, ScreenFormat } from "../server/protocol";
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

export function screenParts(m: Message): ScreenParts | null {
	if (m.kind == MessageKind.Layout) {
		return { layout: { tabs: m.tabs, active: m.active }, screens: [] };
	}
	if (m.kind != MessageKind.Screen) { return null; }
	return {
		layout: null,
		screens: [{
			pane: m.pane,
			seed: {
				native: m.format == ScreenFormat.Native,
				cols: m.cols,
				rows: m.rows,
				bytes: [...m.bytes],
			},
		}],
	};
}

function screenMessage(s: Screen): Message {
	return {
		kind: MessageKind.Screen,
		pane: s.pane,
		cols: s.seed.cols,
		rows: s.seed.rows,
		format: s.seed.native ? ScreenFormat.Native : ScreenFormat.VtBytes,
		bytes: [...s.seed.bytes],
	};
}

export function screenMessages(layout: Layout, screens: Screen[]): Message[] {
	const out: Message[] = [{ kind: MessageKind.Layout, tabs: layout.tabs, active: layout.active }];
	for (const s of screens) { out.push(screenMessage(s)); }
	return out;
}
