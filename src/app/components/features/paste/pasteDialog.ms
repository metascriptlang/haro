import { Accessor, Setter, createSignal } from "../../../../../../neon/src/core/signal";
import { flush } from "../../../../../../neon/src/core/runtime";
import { List, createList } from "../../../../../../neon/src/core/list";
import { ForList, Show } from "../../../../../../neon/src/macros/ui/flow";
import { NeonNode } from "../../../../../../neon/src/render/node";
import { TextSpan } from "../../../../../../neon/src/render/hostTypes";
import { Style } from "../../../../../../neon/src/render/style";
import { View } from "../../../../../../neon/src/components/primitives";
import { Dialog, Held, Line, Tone, Warning, askDialogOf, dialogOf } from "../../../../input/paste";
import {
	BODY_STYLE,
	DIALOG_BORDER,
	DIALOG_CARD,
	DIALOG_GAP,
	DIALOG_PADDING,
	DIALOG_RADIUS,
	DIALOG_SHADOW,
	DIALOG_WELL,
	DIALOG_WELL_PADDING,
	DIM_STYLE,
	PRIMARY_BUTTON,
	SECONDARY_BUTTON,
	TITLE_STYLE,
} from "../../../theme";
import { Button } from "../../ui/button";
import { CellMetrics, CellText } from "../../ui/cellText";
import { ModalLayer } from "../../layout/modalLayer";

export struct Shown {
	spans: TextSpan[];
}

export interface PasteDialogModel {
	visible: Accessor<boolean>;
	cols: Accessor<number>;
	setVisible: Setter<boolean>;
	setCols: Setter<number>;
	confirmLabel: Accessor<string>;
	cancelLabel: Accessor<string>;
	setConfirmLabel: Setter<string>;
	setCancelLabel: Setter<string>;
	top: List<Shown>;
	code: List<Shown>;
	shownFor: Held | null;
	shownRead: string | null;
}

const MARGIN: number = 24;
const MIN_COLS: int32 = 16;
const MAX_COLS: int32 = 88;
const PREVIEW_ROWS: int32 = 8;

const PASTE_CANCEL = "Cancel (Esc)";
const PASTE_CONFIRM = "Paste anyway (Enter)";
const READ_CANCEL = "Deny (Esc)";
const READ_CONFIRM = "Allow (Ctrl+Enter)";

export function dialogCols(viewWidth: number, cellWidth: number): int32 {
	if (cellWidth <= 0) { return MIN_COLS; }
	const room = viewWidth - 2 * MARGIN - 2 * DIALOG_PADDING - 2;
	const fit = Math.floor(room / cellWidth) as int32;
	return Math.max(MIN_COLS, Math.min(fit, MAX_COLS));
}

function styleOf(tone: Tone): Style {
	return match (tone) {
		Tone.Title => TITLE_STYLE,
		Tone.Dim => DIM_STYLE,
		_ => BODY_STYLE,
	};
}

function shownLine(line: Line): Shown {
	return { spans: [{ text: line.text, style: styleOf(line.tone) }] };
}

function fill(list: List<Shown>, lines: Vec<Line>): void {
	while (list.length() > 0) { list.remove(0); }
	for (const line of lines) { list.push(shownLine(line)); }
}

export function createPasteDialog(): PasteDialogModel {
	const [visible, setVisible] = createSignal<boolean>(false);
	const [cols, setCols] = createSignal<number>(MIN_COLS as number);
	const [confirmLabel, setConfirmLabel] = createSignal<string>(PASTE_CONFIRM);
	const [cancelLabel, setCancelLabel] = createSignal<string>(PASTE_CANCEL);
	return {
		visible: visible, cols: cols, setVisible: setVisible, setCols: setCols,
		confirmLabel: confirmLabel, cancelLabel: cancelLabel,
		setConfirmLabel: setConfirmLabel, setCancelLabel: setCancelLabel,
		top: createList<Shown>([]), code: createList<Shown>([]), shownFor: null, shownRead: null,
	};
}

export function showPending(
	this d: PasteDialogModel,
	held: Held | null,
	reading: string | null,
	cellWidth: number,
	viewWidth: number,
): void {
	const cols = dialogCols(viewWidth, cellWidth);
	if (held !== null) {
		if (d.shownFor === held) { return; }
		const dialog = dialogOf(held.warning, held.text, cols, PREVIEW_ROWS);
		d.present(dialog, cols, PASTE_CONFIRM, PASTE_CANCEL);
		d.shownFor = held;
		d.shownRead = null;
		return;
	}
	if (reading === null) {
		d.shownFor = null;
		d.shownRead = null;
		d.setVisible(false);
		return;
	}
	if (d.shownRead === reading) { return; }
	d.present(askDialogOf(reading, cols, PREVIEW_ROWS), cols, READ_CONFIRM, READ_CANCEL);
	d.shownRead = reading;
	d.shownFor = null;
}

function present(
	this d: PasteDialogModel,
	dialog: Dialog,
	cols: int32,
	confirm: string,
	cancel: string,
): void {
	fill(d.top, dialog.top);
	fill(d.code, dialog.code);
	d.setCols(cols as number);
	d.setConfirmLabel(confirm);
	d.setCancelLabel(cancel);
	d.setVisible(true);
}

export function PasteDialog(props: {
	model: PasteDialogModel;
	metrics: CellMetrics;
	onConfirm: () => void;
	onCancel: () => void;
}): NeonNode {
	const d = props.model;
	const m = props.metrics;
	const row = (item: Accessor<Shown>): NeonNode => <CellText metrics={m} spans={item().spans} widths={[]} />;
	return <Show when={d.visible()}>
		<ModalLayer>
			<View
				style={{
					backgroundColor: DIALOG_CARD, padding: DIALOG_PADDING, gap: DIALOG_GAP,
					width: d.cols() * m.cellWidth() + 2 * DIALOG_PADDING + 2,
					borderWidth: 1, borderColor: DIALOG_BORDER, borderRadius: DIALOG_RADIUS,
					boxShadow: DIALOG_SHADOW,
				}}>
				<ForList each={d.top}>{row}</ForList>
				<View
					style={{
						backgroundColor: DIALOG_WELL,
						padding: DIALOG_WELL_PADDING,
						borderWidth: 1,
						borderColor: DIALOG_BORDER,
						borderRadius: DIALOG_RADIUS,
					}}>
					<ForList each={d.code}>{row}</ForList>
				</View>
				<View style={{ flexDirection: "row", justifyContent: "flex-end", gap: DIALOG_GAP }}>
					<Button
						look={SECONDARY_BUTTON}
						label={d.cancelLabel()}
						metrics={m}
						onPress={props.onCancel}
					/>
					<Button
						look={PRIMARY_BUTTON}
						label={d.confirmLabel()}
						metrics={m}
						onPress={props.onConfirm}
					/>
				</View>
			</View>
		</ModalLayer>
	</Show>;
}

test "the card is as wide as the window leaves room for, between sixteen and eighty-eight columns" {
	assert dialogCols(960, 8.4) == 88;
	assert dialogCols(500, 8.4) == 49;
	assert dialogCols(100, 8.4) == 16;
	assert dialogCols(960, 0) == 16;
}

test "a held paste opens the view with its lines and cancelling closes it" {
	const v = createPasteDialog();
	assert !v.visible();
	const held: Held = { text: "ls\ncd ..\nrm x", warning: Warning.MultiLine };
	v.showPending(held, null, 8.4, 960);
	flush();
	assert v.visible();
	assert v.cols() == 88;
	assert v.code.length() == 3;
	assert v.top.length() >= 3;
	assert v.top.at(0).spans[0].text == "Warning: potentially unsafe paste";
	assert v.code.at(1).spans[0].text == "cd ..";
	v.showPending(held, null, 8.4, 960);
	flush();
	assert v.code.length() == 3;
	const next: Held = { text: "a\nb", warning: Warning.MultiLine };
	v.showPending(next, null, 8.4, 400);
	flush();
	assert v.code.length() == 2;
	assert v.cols() == 37;
	v.showPending(null, null, 8.4, 960);
	flush();
	assert !v.visible();
}

test "a clipboard read opens the view with its own labels and closes it again" {
	const v = createPasteDialog();
	v.showPending(null, "secret\ntoken", 8.4, 960);
	flush();
	assert v.visible();
	assert v.top.at(0).spans[0].text == "Authorize clipboard access";
	assert v.code.length() == 2;
	assert v.confirmLabel() == "Allow (Ctrl+Enter)";
	assert v.cancelLabel() == "Deny (Esc)";
	const held: Held = { text: "a\nb", warning: Warning.MultiLine };
	v.showPending(held, "secret", 8.4, 960);
	flush();
	assert v.confirmLabel() == "Paste anyway (Enter)";
	v.showPending(null, null, 8.4, 960);
	flush();
	assert !v.visible();
}
