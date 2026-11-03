import { Accessor, Setter, createSignal } from "../../../../../../neon/src/core/signal";
import { flush } from "../../../../../../neon/src/core/runtime";
import { List, createList } from "../../../../../../neon/src/core/list";
import { ForList, Show } from "../../../../../../neon/src/macros/ui/flow";
import { NeonNode } from "../../../../../../neon/src/render/node";
import { NeonEvent, neonEvent } from "../../../../../../neon/src/render/event";
import { View, ViewHandle } from "../../../../../../neon/src/components/primitives";
import { Line, Reply, Tone, replyToClose, visible, wrap } from "../../../../input/paste";
import { modsOf } from "../../../../keys/keys";
import {
	ButtonLook,
	DIALOG_BORDER,
	DIALOG_CARD,
	DIALOG_GAP,
	DIALOG_PADDING,
	PRIMARY_BUTTON,
	SECONDARY_BUTTON,
} from "../../../theme";
import { Button } from "../../ui/button";
import { CellMetrics, CellText } from "../../ui/cellText";
import { ModalLayer } from "../../layout/modalLayer";
import {
	CLOSE_CANCEL,
	CLOSE_CONFIRM,
	ShownLine,
	dialogCols,
	fill,
} from "../paste/pasteDialog";

export enum Closing {
	Pane,
	Tab,
	Window,
}

export struct CloseAsk {
	what: Closing;
	program: string;
	count: int32;
}

const SQUARE_PRIMARY: ButtonLook = { ...PRIMARY_BUTTON, radius: 0 };
const SQUARE_SECONDARY: ButtonLook = { ...SECONDARY_BUTTON, radius: 0 };

export function closeNeedsConfirm(
	foregroundIsShell: boolean,
	confirmClose: boolean,
): boolean {
	return confirmClose && !foregroundIsShell;
}

function titleOf(program: string): string {
	return program == "" ? "A program is still running" : `${program} is still running`;
}

function bodyOf(what: Closing, count: int32): string {
	return match (what) {
		Closing.Pane => "Close this pane and end it?",
		Closing.Tab when count > 1 => `Close this tab and its ${count} panes?`,
		Closing.Tab => "Close this tab and end it?",
		Closing.Window when count > 1 => `Close the window and its ${count} panes?`,
		Closing.Window => "Close the window and end it?",
	};
}

export function closeLines(ask: CloseAsk, cols: int32): Vec<Line> {
	let lines: Vec<Line> = [{ text: visible(titleOf(ask.program), cols), tone: Tone.Title }];
	for (const row of wrap(bodyOf(ask.what, ask.count), cols)) {
		lines.push({ text: row, tone: Tone.Body });
	}
	return lines;
}

export function keyReply(e: NeonEvent): Reply {
	const mods = modsOf(e.mods);
	if (!mods.ok) { return Reply.Ignore; }
	return replyToClose(e.code, mods.value);
}

export interface ConfirmModel {
	visible: Accessor<boolean>;
	setVisible: Setter<boolean>;
	cols: Accessor<int32>;
	setCols: Setter<int32>;
	lines: List<ShownLine>;
}

export function open(this typeof ConfirmModel): ConfirmModel {
	const [shown, setShown] = createSignal<boolean>(false);
	const [cols, setCols] = createSignal<int32>(dialogCols(0, 0));
	return {
		visible: shown, setVisible: setShown, cols: cols, setCols: setCols,
		lines: createList<ShownLine>([]),
	};
}

export function ask(
	this c: ConfirmModel,
	what: CloseAsk,
	cellWidth: float64,
	viewWidth: float64,
): void {
	const cols = dialogCols(viewWidth, cellWidth);
	fill(c.lines, closeLines(what, cols));
	c.setCols(cols);
	c.setVisible(true);
}

export function dismiss(this c: ConfirmModel): void {
	c.setVisible(false);
}

export function ConfirmClose(props: {
	model: ConfirmModel;
	metrics: CellMetrics;
	onConfirm: () => void;
	onCancel: () => void;
}): NeonNode {
	const c = props.model;
	const m = props.metrics;
	const confirm = (): void => {
		c.dismiss();
		props.onConfirm();
	};
	const cancel = (): void => {
		c.dismiss();
		props.onCancel();
	};
	const row = (item: Accessor<ShownLine>): NeonNode =>
		<CellText metrics={m} spans={item().spans} widths={[]} />;
	return <Show when={c.visible()}>
		<ModalLayer>
			<View
				style={{
					backgroundColor: DIALOG_CARD, padding: DIALOG_PADDING, gap: DIALOG_GAP,
					width: (c.cols() as float64) * m.cellWidth() + 2 * DIALOG_PADDING + 2,
					borderWidth: 1, borderColor: DIALOG_BORDER,
				}}
				focusable
				ref={(h: ViewHandle): void => { h.focus(); }}
				onKeyDown={(e: NeonEvent): void => {
					match (keyReply(e)) {
						Reply.Confirm => confirm(),
						Reply.Cancel => cancel(),
						Reply.Ignore => {},
					}
				}}>
				<ForList each={c.lines}>{row}</ForList>
				<View style={{ flexDirection: "row", justifyContent: "flex-end", gap: DIALOG_GAP }}>
					<Button look={SQUARE_SECONDARY} label={CLOSE_CANCEL} metrics={m} onPress={cancel} />
					<Button look={SQUARE_PRIMARY} label={CLOSE_CONFIRM} metrics={m} onPress={confirm} />
				</View>
			</View>
		</ModalLayer>
	</Show>;
}

test "a close asks only when confirmation is on and the shell is not in the foreground" {
	assert closeNeedsConfirm(false, true);
	assert !closeNeedsConfirm(true, true);
	assert !closeNeedsConfirm(false, false);
	assert !closeNeedsConfirm(true, false);
}

test "the dialog names the running program and what closing ends" {
	const pane = closeLines({ what: Closing.Pane, program: "vim", count: 1 }, 40);
	assert pane.length == 2;
	assert pane[0] == ({ text: "vim is still running", tone: Tone.Title } as Line);
	assert pane[1] == ({ text: "Close this pane and end it?", tone: Tone.Body } as Line);
	const tab = closeLines({ what: Closing.Tab, program: "htop", count: 3 }, 40);
	assert tab[1].text == "Close this tab and its 3 panes?";
	assert closeLines({ what: Closing.Tab, program: "a", count: 1 }, 40)[1].text ==
		"Close this tab and end it?";
	const window = closeLines({ what: Closing.Window, program: "", count: 1 }, 40);
	assert window[0].text == "A program is still running";
	assert window[1].text == "Close the window and end it?";
	assert closeLines({ what: Closing.Window, program: "a", count: 2 }, 40)[1].text ==
		"Close the window and its 2 panes?";
}

test "a long program name is cut and the question wraps at the dialog's width" {
	const lines = closeLines(
		{ what: Closing.Window, program: "a-very-long-program-name", count: 12 },
		16,
	);
	assert lines[0].text.length <= 16;
	assert lines.length == 4;
	assert lines[1].text == "Close the window";
	assert lines[2].text == "and its 12";
	assert lines[3].text == "panes?";
}

function keyed(code: string, mask: number): NeonEvent {
	const e = neonEvent("keydown");
	e.code = code;
	e.mods = mask;
	return e;
}

test "enter alone confirms, escape alone cancels, other keys and bad masks are ignored" {
	assert keyReply(keyed("Enter", 0)) == Reply.Confirm;
	assert keyReply(keyed("NumpadEnter", 0)) == Reply.Confirm;
	assert keyReply(keyed("Escape", 0)) == Reply.Cancel;
	assert keyReply(keyed("Enter", 1)) == Reply.Ignore;
	assert keyReply(keyed("KeyW", 0)) == Reply.Ignore;
	assert keyReply(keyed("Enter", -1)) == Reply.Ignore;
}

test "asking shows the lines at the window's width and dismissing hides them" {
	const c = ConfirmModel.open();
	assert !c.visible();
	c.ask({ what: Closing.Pane, program: "vim", count: 1 }, 8.4, 960);
	flush();
	assert c.visible();
	assert c.cols() == 88;
	assert c.lines.length() == 2;
	assert c.lines.at(0).spans[0].text == "vim is still running";
	c.ask({ what: Closing.Tab, program: "top", count: 2 }, 8.4, 400);
	flush();
	assert c.cols() == 37;
	assert c.lines.at(1).spans[0].text == "Close this tab and its 2 panes?";
	c.dismiss();
	flush();
	assert !c.visible();
}
