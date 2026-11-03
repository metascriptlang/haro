import { Held, Warning } from "../input/paste";

export enum PendingKind {
	None,
	Paste,
	Read,
}

export struct Pending = match (kind: PendingKind) {
	PendingKind.None => {},
	PendingKind.Paste => { held: Held },
	PendingKind.Read => { text: string },
};

export function pendingOf(held: Held | null, reading: string | null): Pending {
	if (held !== null) { return { kind: PendingKind.Paste, held: held }; }
	if (reading !== null) { return { kind: PendingKind.Read, text: reading }; }
	return { kind: PendingKind.None };
}

export function samePending(a: Pending, b: Pending): boolean {
	return match (a.kind) {
		PendingKind.Paste => b.kind === PendingKind.Paste
			&& a.held.text == b.held.text
			&& a.held.warning == b.held.warning,
		PendingKind.Read => b.kind === PendingKind.Read && a.text == b.text,
		PendingKind.None => a.kind === b.kind,
	};
}

test "a held paste outranks a clipboard read" {
	const held: Held = { text: "a", warning: Warning.MultiLine };
	assert pendingOf(held, "r").kind == PendingKind.Paste;
	assert pendingOf(null, "r").kind == PendingKind.Read;
	assert pendingOf(null, null).kind == PendingKind.None;
}

test "two pendings are the same when their kind and what they show are" {
	const held: Held = { text: "a", warning: Warning.MultiLine };
	assert samePending(pendingOf(held, null), pendingOf({ ...held }, "x"));
	const other: Held = { text: "b", warning: Warning.MultiLine };
	assert !samePending(pendingOf(held, null), pendingOf(other, null));
	assert !samePending(pendingOf(null, "a"), pendingOf(null, "b"));
	assert samePending(pendingOf(null, null), pendingOf(null, null));
}
