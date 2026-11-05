import { append } from "../pty/bytes";
import { PaneId } from "../workspace/tree";

export interface Feed {
	pane: PaneId;
	first: uint64;
	last: uint64;
	bytes: Vec<uint8>;
}

export function add(this feeds: Feed[], pane: PaneId, seq: uint64, bytes: Readonly<Span<uint8>>): void {
	for (let i = feeds.length - 1; i >= 0; i--) {
		const f = feeds[i];
		if (!(f.pane == pane)) { continue; }
		if (seq <= f.last) { break; }
		f.last = seq;
		f.bytes.append(bytes);
		return;
	}
	let copied: Vec<uint8> = [];
	copied.append(bytes);
	feeds.push({ pane: pane, first: seq, last: seq, bytes: move copied });
}

test "a pane's outputs in seq order join into one feed, other panes keep their own" {
	const feeds: Feed[] = [];
	feeds.add(1 as PaneId, 1, [0x61]);
	feeds.add(2 as PaneId, 7, [0x78]);
	feeds.add(1 as PaneId, 2, [0x62, 0x63]);
	feeds.add(1 as PaneId, 3, []);
	assert feeds.length == 2;
	assert feeds[0].first == 1 && feeds[0].last == 3;
	assert feeds[0].bytes.asString() == "abc";
	assert feeds[1].pane == (2 as PaneId) && feeds[1].bytes.asString() == "x";
}

test "an output whose seq does not follow its pane's last starts a feed of its own, so the pane still sees it out of order" {
	const feeds: Feed[] = [];
	feeds.add(1 as PaneId, 5, [0x61]);
	feeds.add(1 as PaneId, 5, [0x62]);
	feeds.add(1 as PaneId, 6, [0x63]);
	assert feeds.length == 2;
	assert feeds[0].first == 5 && feeds[0].last == 5 && feeds[0].bytes.asString() == "a";
	assert feeds[1].first == 5 && feeds[1].last == 6 && feeds[1].bytes.asString() == "bc";
}
