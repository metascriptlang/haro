import { Accessor, Setter, createSignal } from "../../../../../../neon/src/core/signal";
import { List, createList } from "../../../../../../neon/src/core/list";
import { ForList, Show } from "../../../../../../neon/src/macros/ui/flow";
import { NeonNode } from "../../../../../../neon/src/render/node";
import { NeonEvent } from "../../../../../../neon/src/render/event";
import { View } from "../../../../../../neon/src/components/primitives";
import { visible } from "../../../../input/paste";
import { NOTICE_BACKGROUND, NOTICE_PADDING, NOTICE_RADIUS, NOTICE_STYLE } from "../../../theme";
import { CellMetrics, CellText } from "../../ui/cellText";

const FALLBACK_COLS: int32 = 80;

export const NOTICE_LINES: int32 = 8;

export function noticeLines(text: string, cols: int32): string[] {
	let out: string[] = [];
	if (text == "") { return out; }
	const all = text.trimEnd().split("\n");
	for (const raw of all) {
		if (out.length == NOTICE_LINES - 1 && all.length > NOTICE_LINES) {
			out.push(`… ${all.length - out.length} more lines`);
			break;
		}
		out.push(visible(raw.trimEnd(), cols));
	}
	return out;
}

export function noticeCols(viewWidth: number, padding: number, cellWidth: number): int32 {
	if (cellWidth <= 0) { return FALLBACK_COLS; }
	const room = viewWidth - 2 * padding - 2 * NOTICE_PADDING;
	return Math.max(1, Math.floor(room / cellWidth)) as int32;
}

export interface NoticeModel {
	text: string;
	shown: Accessor<boolean>;
	setShown: Setter<boolean>;
	rows: List<string>;
}

export function createNotice(): NoticeModel {
	const [shown, setShown] = createSignal<boolean>(false);
	return { text: "", shown: shown, setShown: setShown, rows: createList<string>([]) };
}

export function showNotice(this n: NoticeModel, text: string, cols: int32): void {
	n.text = text;
	n.rows.replaceAll(noticeLines(text, cols));
	n.setShown(text != "");
}

export function dismissNotice(this n: NoticeModel): void {
	n.showNotice("", FALLBACK_COLS);
}

export function Notice(props: {
	model: NoticeModel;
	metrics: CellMetrics;
	inset: Accessor<number>;
}): NeonNode {
	const n = props.model;
	const m = props.metrics;
	const row = (item: Accessor<string>): NeonNode =>
		<CellText metrics={m} spans={[{ text: item(), style: NOTICE_STYLE }]} />;
	return <Show when={n.shown()}>
		<View
			style={{
				position: "absolute",
				left: props.inset(),
				right: props.inset(),
				top: props.inset(),
				padding: NOTICE_PADDING,
				backgroundColor: NOTICE_BACKGROUND,
				borderRadius: NOTICE_RADIUS,
			}}
			onPointerDown={(e: NeonEvent): void => { n.dismissNotice(); }}>
			<ForList each={n.rows}>{row}</ForList>
		</View>
	</Show>;
}

test "no notice has no lines" {
	assert noticeLines("", 40).length == 0;
}

test "each line of a notice is cut to the width, a carriage return dropped" {
	const lines = noticeLines("error: a long message here\r\n  --> config.ms:3:27\r\n", 12);
	assert lines.length == 2;
	assert lines[0] == "error: a lo…";
	assert lines[1] == "  --> confi…";
}

test "a notice past its lines ends by counting what it left out" {
	let text = "";
	for (let i = 0; i < 20; i++) { text += `line ${i}\n`; }
	const lines = noticeLines(text, 40);
	assert lines.length == NOTICE_LINES;
	assert lines[NOTICE_LINES - 2] == "line 6";
	assert lines[NOTICE_LINES - 1] == "… 13 more lines";
}

test "a notice wraps at the cells left inside the window padding, at least one" {
	assert noticeCols(960, 2, 8) == 117;
	assert noticeCols(10, 10, 8) == 1;
	assert noticeCols(960, 2, 0) == 80;
}
