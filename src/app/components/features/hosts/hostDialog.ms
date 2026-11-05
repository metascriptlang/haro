import { Accessor, Setter, createSignal, untrack } from "../../../../../../neon/src/core/signal";
import { For, Show } from "../../../../../../neon/src/macros/ui/flow";
import { NeonNode } from "../../../../../../neon/src/render/node";
import { NeonEvent } from "../../../../../../neon/src/render/event";
import { Style } from "../../../../../../neon/src/render/style";
import {
	TextInput,
	TextInputHandle,
	View,
	ViewHandle,
} from "../../../../../../neon/src/components/primitives";
import {
	BODY_STYLE,
	ButtonLook,
	DIALOG_BORDER,
	DIALOG_CARD,
	DIALOG_GAP,
	DIALOG_PADDING,
	DIALOG_WELL,
	DIM_STYLE,
	PRIMARY_BUTTON,
	SECONDARY_BUTTON,
	TITLE_STYLE,
} from "../../../theme";
import { Button } from "../../ui/button";
import { CellMetrics, CellText } from "../../ui/cellText";
import { ModalLayer } from "../../layout/modalLayer";

const DIALOG_COLS: int32 = 48;
const PICK_TITLE = "New tab on host";
const ADD_TITLE = "Add remote host";
const FORGET_TITLE = "Remove remote host";
const ADDRESS_HINT = "an ssh alias, user@host or tailnet name";
const SQUARE_PRIMARY: ButtonLook = { ...PRIMARY_BUTTON, radius: 0 };
const SQUARE_SECONDARY: ButtonLook = { ...SECONDARY_BUTTON, radius: 0 };

export enum HostAsk {
	Closed,
	Pick,
	Add,
	Forget,
}

export struct HostChoice {
	id: int32;
	label: string;
	state: string;
}

export interface HostDialogModel {
	ask: Accessor<HostAsk>;
	setAsk: Setter<HostAsk>;
	choices: Accessor<HostChoice[]>;
	setChoices: Setter<HostChoice[]>;
	picked: Accessor<int32>;
	setPicked: Setter<int32>;
	error: Accessor<string>;
	setError: Setter<string>;
	label: string;
	address: string;
}

export function open(this typeof HostDialogModel): HostDialogModel {
	const [ask, setAsk] = createSignal<HostAsk>(HostAsk.Closed);
	const [choices, setChoices] = createSignal<HostChoice[]>([]);
	const [picked, setPicked] = createSignal<int32>(0);
	const [error, setError] = createSignal<string>("");
	return {
		ask: ask, setAsk: setAsk, choices: choices, setChoices: setChoices,
		picked: picked, setPicked: setPicked, error: error, setError: setError,
		label: "", address: "",
	};
}

export function visible(this d: HostDialogModel): boolean {
	return d.ask() != HostAsk.Closed;
}

export function askPick(this d: HostDialogModel, choices: HostChoice[]): void {
	d.setChoices(choices);
	d.setPicked(0);
	d.setAsk(HostAsk.Pick);
}

export function askForget(this d: HostDialogModel, choices: HostChoice[]): void {
	d.askPick(choices);
	d.setAsk(HostAsk.Forget);
}

export function askAdd(this d: HostDialogModel): void {
	d.label = "";
	d.address = "";
	d.setError("");
	d.setAsk(HostAsk.Add);
}

export function shut(this d: HostDialogModel): void {
	d.setAsk(HostAsk.Closed);
}

export function choiceText(c: HostChoice, picked: boolean): string {
	const mark = picked ? ">" : " ";
	return c.state == "" ? `${mark} ${c.label}` : `${mark} ${c.label} (${c.state})`;
}

export function steppedPick(picked: int32, by: int32, count: int32): int32 {
	if (count <= 0) { return 0; }
	return (((picked + by) % count) + count) % count;
}

function Line(props: { metrics: CellMetrics; text: string; dim: boolean }): NeonNode {
	return <CellText
		metrics={props.metrics}
		spans={[{ text: props.text, style: props.dim ? DIM_STYLE : BODY_STYLE }]}
		widths={[]}
	/>;
}

export function HostDialog(props: {
	model: HostDialogModel;
	metrics: CellMetrics;
	onPick: (id: int32) => void;
	onAdd: (label: string, address: string) => string;
	onClose: () => void;
}): NeonNode {
	const d = props.model;
	const m = props.metrics;
	let addressField: TextInputHandle | null = null;
	const width = (): float64 => (DIALOG_COLS as float64) * m.cellWidth() + 2 * DIALOG_PADDING + 2;
	const pick = (): void => {
		const all = d.choices();
		if (all.length == 0) { return; }
		const chosen = all[d.picked()].id;
		props.onPick(chosen);
	};
	const add = (): void => {
		const refusal = props.onAdd(d.label, d.address);
		d.setError(refusal);
	};
	const pickKey = (e: NeonEvent): void => {
		const count = d.choices().length as int32;
		match (e.code) {
			"ArrowUp" => { d.setPicked(steppedPick(d.picked(), -1, count)); },
			"ArrowDown" => { d.setPicked(steppedPick(d.picked(), 1, count)); },
			"Enter" | "NumpadEnter" => { pick(); },
			"Escape" => { props.onClose(); },
			_ => {},
		}
	};
	const addKey = (e: NeonEvent): void => {
		if (e.code == "Escape") { props.onClose(); }
	};
	const card = {
		backgroundColor: DIALOG_CARD,
		padding: DIALOG_PADDING,
		gap: DIALOG_GAP,
		borderWidth: 1,
		borderColor: DIALOG_BORDER,
	};
	const field: Style = untrack((): Style => ({
		backgroundColor: DIALOG_WELL,
		color: BODY_STYLE.color,
		fontFamily: m.fontFamily(),
		fontSize: m.fontSize(),
		height: m.rowHeight() + 8,
		paddingLeft: 4,
	}));
	return <Show when={d.visible()}>
		<ModalLayer>
			<Show when={d.ask() == HostAsk.Pick || d.ask() == HostAsk.Forget}>
				<View
					style={{ ...card, width: width() }}
					focusable
					ref={(h: ViewHandle): void => { h.focus(); }}
					onKeyDown={pickKey}>
					<CellText
						metrics={m}
						spans={[{ text: d.ask() == HostAsk.Forget ? FORGET_TITLE : PICK_TITLE, style: TITLE_STYLE }]}
						widths={[]}
					/>
					<For each={d.choices()} keyed={(c: HostChoice): number => c.id}>
						{(c: Accessor<HostChoice>): NeonNode => <View
							onPointerDown={(e: NeonEvent): void => { props.onPick(c().id); }}>
							<Line
								metrics={m}
								text={choiceText(c(), d.choices()[d.picked()]?.id == c().id)}
								dim={c().state != ""}
							/>
						</View>}
					</For>
				</View>
			</Show>
			<Show when={d.ask() == HostAsk.Add}>
				<View style={{ ...card, width: width() }} onKeyDown={addKey}>
					<CellText metrics={m} spans={[{ text: ADD_TITLE, style: TITLE_STYLE }]} widths={[]} />
					<Line metrics={m} text="Label" dim={true} />
					<TextInput
						style={field}
						autoFocus={true}
						onChangeText={(t: string): void => { d.label = t; }}
						onSubmitEditing={(e: NeonEvent): void => { addressField?.focus(); }}
					/>
					<Line metrics={m} text={`Address: ${ADDRESS_HINT}`} dim={true} />
					<TextInput
						style={field}
						ref={(h: TextInputHandle): void => { addressField = h; }}
						onChangeText={(t: string): void => { d.address = t; }}
						onSubmitEditing={(e: NeonEvent): void => { add(); }}
					/>
					<Show when={d.error() != ""}>
						<CellText metrics={m} spans={[{ text: d.error(), style: TITLE_STYLE }]} widths={[]} />
					</Show>
					<View style={{ flexDirection: "row", justifyContent: "flex-end", gap: DIALOG_GAP }}>
						<Button look={SQUARE_SECONDARY} label="Cancel" metrics={m} onPress={props.onClose} />
						<Button look={SQUARE_PRIMARY} label="Add" metrics={m} onPress={add} />
					</View>
				</View>
			</Show>
		</ModalLayer>
	</Show>;
}

test "a host choice shows its label, its state when it is not connected, and the pick mark" {
	assert choiceText({ id: 0, label: "local", state: "" }, true) == "> local";
	assert choiceText({ id: 1, label: "build", state: "offline" }, false) == "  build (offline)";
}

test "the pick moves up and down and wraps at either end" {
	assert steppedPick(0, 1, 3) == 1;
	assert steppedPick(2, 1, 3) == 0;
	assert steppedPick(0, -1, 3) == 2;
	assert steppedPick(0, 1, 0) == 0;
}
