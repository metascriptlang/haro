import { Held, Warning } from "../input/paste";

export enum PendingKind {
	None,
	Close,
	Paste,
	Read,
}

export struct Pending = match (kind: PendingKind) {
	PendingKind.None => {},
	PendingKind.Close => {},
	PendingKind.Paste => { held: Held },
	PendingKind.Read => { text: string },
};

export function pendingOf(held: Held | null, reading: string | null, closing: boolean): Pending {
	if (closing) { return { kind: PendingKind.Close }; }
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
		PendingKind.None | PendingKind.Close => a.kind === b.kind,
	};
}

test "a close outranks a held paste, which outranks a clipboard read" {
	const held: Held = { text: "a", warning: Warning.MultiLine };
	assert pendingOf(held, "r", true).kind == PendingKind.Close;
	assert pendingOf(held, "r", false).kind == PendingKind.Paste;
	assert pendingOf(null, "r", false).kind == PendingKind.Read;
	assert pendingOf(null, null, false).kind == PendingKind.None;
}

test "two pendings are the same when their kind and what they show are" {
	const held: Held = { text: "a", warning: Warning.MultiLine };
	assert samePending(pendingOf(held, null, false), pendingOf({ ...held }, "x", false));
	assert !samePending(pendingOf(held, null, false), pendingOf({ text: "b", warning: Warning.MultiLine }, null, false));
	assert !samePending(pendingOf(null, "a", false), pendingOf(null, "b", false));
	assert samePending(pendingOf(null, null, true), pendingOf(held, null, true));
}
