import { element } from "../../../neon/src/macros/ui/element";
import { NeonNode } from "../../../neon/src/render/node";
import { Accessor, Setter, createSignal } from "../../../neon/src/core/signal";
import { List, createList } from "../../../neon/src/core/list";
import { ForList, Show } from "../../../neon/src/macros/ui/flow";
import { TextSpan } from "../../../neon/src/render/hostTypes";
import { Style } from "../../../neon/src/render/style";
import { Pressable, Text, View } from "../../../neon/src/components/primitives";
import { Held, Line, Tone, Warning, dialogOf } from "../input/paste";

export struct Shown {
	spans: TextSpan[];
}

export interface PasteView {
	open: Accessor<boolean>;
	cols: Accessor<number>;
	setOpen: Setter<boolean>;
	setCols: Setter<number>;
	top: List<Shown>;
	code: List<Shown>;
	shownFor: Held | null;
}

export interface Look {
	cellWidth: Accessor<number>;
	rowHeight: Accessor<number>;
	fontSize: number;
	onConfirm: () => void;
	onCancel: () => void;
}

const MARGIN: number = 24;
const PADDING: number = 16;
const MIN_COLS: int32 = 16;
const MAX_COLS: int32 = 88;
const PREVIEW_ROWS: int32 = 8;

const SCRIM = "#000000";
const FRAME = "#3f3f3f";
const CARD = "#1c1c1c";
const WELL = "#0c0c0c";
const ACCENT = "#c19c00";
const TEXT = "#cccccc";
const WARNING = "#f9f1a5";
const DIM = "#7a7a7a";
const PRIMARY = "#cccccc";
const PRIMARY_HELD = "#ffffff";
const SECONDARY = "#2d2d2d";
const SECONDARY_HELD = "#454545";
const ON_PRIMARY = "#0c0c0c";

const TITLE_STYLE: Style = { color: WARNING, fontWeight: "bold" };
const BODY_STYLE: Style = { color: TEXT };
const DIM_STYLE: Style = { color: DIM };
const CANCEL_STYLE: Style = { color: TEXT };
const CONFIRM_STYLE: Style = { color: ON_PRIMARY, fontWeight: "bold" };

const CANCEL_LABEL = "Cancel (Esc)";
const CONFIRM_LABEL = "Paste anyway (Enter)";

export function dialogCols(viewWidth: number, cellWidth: number): int32 {
	if (cellWidth <= 0) { return MIN_COLS; }
	const room = viewWidth - 2 * MARGIN - 2 * PADDING - 2;
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

function shown(line: Line): Shown {
	return { spans: [{ text: line.text, style: styleOf(line.tone) }] };
}

function fill(list: List<Shown>, lines: Vec<Line>): void {
	while (list.length() > 0) { list.remove(0); }
	for (const line of lines) { list.push(shown(line)); }
}

export function open(this typeof PasteView): PasteView {
	const [isOpen, setOpen] = createSignal<boolean>(false);
	const [cols, setCols] = createSignal<number>(MIN_COLS as number);
	return {
		open: isOpen, cols: cols, setOpen: setOpen, setCols: setCols,
		top: createList<Shown>([]), code: createList<Shown>([]), shownFor: null,
	};
}

export function show(this v: PasteView, held: Held | null, cellWidth: number, viewWidth: number): void {
	if (held === null) {
		v.shownFor = null;
		v.setOpen(false);
		return;
	}
	if (v.shownFor === held) { return; }
	const cols = dialogCols(viewWidth, cellWidth);
	const d = dialogOf(held.warning, held.text, cols, PREVIEW_ROWS);
	fill(v.top, d.top);
	fill(v.code, d.code);
	v.setCols(cols as number);
	v.shownFor = held;
	v.setOpen(true);
}

export function PasteDialog(v: PasteView, look: Look): NeonNode {
	const [confirmHeld, setConfirmHeld] = createSignal<boolean>(false);
	const [cancelHeld, setCancelHeld] = createSignal<boolean>(false);

	const row = (item: Accessor<Shown>): NeonNode => {
		return element(
			<Text
				style={{ fontSize: look.fontSize, height: look.rowHeight() }}
				cellWidth={look.cellWidth()}
				spans={item().spans}
			/>
		);
	};

	const label = (text: string, style: Style): NeonNode => {
		return element(
			<Text
				style={{ fontSize: look.fontSize, height: look.rowHeight(), width: text.length * look.cellWidth() }}
				cellWidth={look.cellWidth()}
				spans={[{ text: text, style: style }]}
			/>
		);
	};

	return Show({
		when: v.open,
		children: element(
			<View style={{ position: "absolute", left: 0, top: 0, right: 0, bottom: 0 }}>
				<View
					style={{
						position: "absolute", left: 0, top: 0, right: 0, bottom: 0,
						backgroundColor: SCRIM, opacity: 0.62,
					}}
				/>
				<View
					style={{
						position: "absolute", left: 0, top: 0, right: 0, bottom: 0,
						alignItems: "center", justifyContent: "center",
					}}>
					<View style={{ backgroundColor: FRAME, padding: 1 }}>
						<View style={{ backgroundColor: ACCENT, height: 3 }} />
						<View
							style={{
								backgroundColor: CARD, padding: PADDING, gap: 12,
								width: v.cols() * look.cellWidth() + 2 * PADDING,
							}}>
							{ForList<Shown>({ each: v.top, children: row })}
							<View style={{ backgroundColor: FRAME, padding: 1 }}>
								<View style={{ backgroundColor: WELL, padding: 8 }}>
									{ForList<Shown>({ each: v.code, children: row })}
								</View>
							</View>
							<View style={{ flexDirection: "row", justifyContent: "flex-end", gap: 12 }}>
								<Pressable
									style={{
										backgroundColor: cancelHeld() ? SECONDARY_HELD : SECONDARY,
										paddingLeft: 16, paddingRight: 16, paddingTop: 6, paddingBottom: 6,
									}}
									onPressIn={(): void => { setCancelHeld(true); }}
									onPressOut={(): void => { setCancelHeld(false); }}
									onPress={(): void => { look.onCancel(); }}>
									{label(CANCEL_LABEL, CANCEL_STYLE)}
								</Pressable>
								<Pressable
									style={{
										backgroundColor: confirmHeld() ? PRIMARY_HELD : PRIMARY,
										paddingLeft: 16, paddingRight: 16, paddingTop: 6, paddingBottom: 6,
									}}
									onPressIn={(): void => { setConfirmHeld(true); }}
									onPressOut={(): void => { setConfirmHeld(false); }}
									onPress={(): void => { look.onConfirm(); }}>
									{label(CONFIRM_LABEL, CONFIRM_STYLE)}
								</Pressable>
							</View>
						</View>
					</View>
				</View>
			</View>
		),
	});
}

test "the card is as wide as the window leaves room for, between sixteen and eighty-eight columns" {
	assert dialogCols(960, 8.4) == 88;
	assert dialogCols(500, 8.4) == 49;
	assert dialogCols(100, 8.4) == 16;
	assert dialogCols(960, 0) == 16;
}

test "a held paste opens the view with its lines and cancelling closes it" {
	const v = PasteView.open();
	assert !v.open();
	const held: Held = { text: "ls\ncd ..\nrm x", warning: Warning.MultiLine };
	v.show(held, 8.4, 960);
	assert v.open();
	assert v.cols() == 88;
	assert v.code.length() == 3;
	assert v.top.length() >= 3;
	assert v.top.at(0).spans[0].text == "Warning: potentially unsafe paste";
	assert v.code.at(1).spans[0].text == "cd ..";
	v.show(held, 8.4, 960);
	assert v.code.length() == 3;
	const next: Held = { text: "a\nb", warning: Warning.MultiLine };
	v.show(next, 8.4, 400);
	assert v.code.length() == 2;
	assert v.cols() == 37;
	v.show(null, 8.4, 960);
	assert !v.open();
}
