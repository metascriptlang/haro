import { ensureDir } from "std/fs";
import { cwd } from "std/process";
import { Axis, PaneId } from "../workspace/tree";
import {
	CommandKind,
	Direction,
	EventKind,
	Workspace,
	WorkspaceCommand,
	WorkspaceEvent,
	apply,
	create,
} from "../workspace/workspace";
import {
	PaneHost,
	PaneHostError,
	PaneSink,
	apply as applyEvent,
	busy,
	closeAll,
	open,
	paneOf,
	pump,
	pwd,
	snapshot,
	title,
	write,
} from "./paneHost";

when (!windows) {
	const COLS: int32 = 81;
	const ROWS: int32 = 24;
	const WAIT_MS: float64 = 5000;

	interface Seen {
		printed: Map<int32, string>;
		seqs: Map<int32, int64>;
		gaps: string;
		exits: string;
		fatal: string;
	}

	function fresh(): Seen {
		return { printed: new Map(), seqs: new Map(), gaps: "", exits: "", fatal: "" };
	}

	function sinkOf(seen: Seen): PaneSink {
		return {
			output: (pane: PaneId, seq: int64, bytes: Vec<uint8>): void => {
				const id = pane as int32;
				const last = seen.seqs.get(id) ?? 0;
				if (seq != last + 1) { seen.gaps += `${id}:${last}->${seq} `; }
				seen.seqs.set(id, seq);
				seen.printed.set(id, (seen.printed.get(id) ?? "") + bytes.asString());
			},
			exit: (pane: PaneId, code: int32): void => { seen.exits += `${pane as int32}:${code} `; },
			failed: (pane: PaneId, failure: string): void => {
				seen.fatal += `${pane as int32}: ${failure}\n`;
			},
		};
	}

	function dirNamed(name: string, seen: Seen): string {
		const dir = `${cwd()}/out/${name}`;
		if (!ensureDir(dir).ok) { seen.fatal += `${dir} was not made\n`; }
		return dir;
	}

	function hostIn(start: string, seen: Seen): PaneHost {
		return PaneHost.open(
			{ command: "sh", shellScripts: null, startIn: start, originCwd: true },
			sinkOf(seen),
		);
	}

	async function ran(
		w: Workspace,
		h: PaneHost,
		c: WorkspaceCommand,
		seen: Seen,
	): Promise<WorkspaceEvent[]> {
		const events = w.apply(c, COLS, ROWS);
		if (!events.ok) {
			seen.fatal += `${c.kind.toString()}: ${events.error.toString()}\n`;
			return [];
		}
		for (const e of events.value) {
			const refused = await h.applyEvent(e);
			if (refused !== null) { seen.fatal += `${e.kind.toString()}: ${refused.toString()}\n`; }
		}
		return events.value;
	}

	function printedBy(seen: Seen, id: int32): string {
		return seen.printed.get(id) ?? "";
	}

	async function prints(h: PaneHost, seen: Seen, id: int32, wanted: string): Promise<boolean> {
		const start: float64 = performance.now();
		while (performance.now() - start < WAIT_MS) {
			const _more = await h.pump();
			if (printedBy(seen, id).includes(wanted)) { return true; }
		}
		return false;
	}

	function typed(h: PaneHost, id: int32, text: string): boolean {
		return h.write(id as PaneId, [...text.asBytes()]);
	}

	test "two panes each forward their own pty bytes in seq order, take written input, start in the origin's cwd and see a resize" {
		const seen = fresh();
		const start = dirNamed("hostStart", seen);
		const moved = dirNamed("hostMoved", seen);
		const w = Workspace.create(1);
		assert w.ok;
		if (!w.ok) { return; }
		const ws = w.value;
		const h = hostIn(start, seen);

		const _tab = await ran(ws, h, { kind: CommandKind.NewTab }, seen);
		assert typed(h, 1, "printf 'one%sone\\n' -\r");
		assert await prints(h, seen, 1, "one-one");
		assert typed(h, 1, `cd ${moved}; printf '\\033]7;file://localhost%s\\007' "$PWD"\r`);
		const waited: float64 = performance.now();
		while ((await h.pwd(1 as PaneId)) != `file://localhost${moved}` && performance.now() - waited < WAIT_MS) {
			const _more = await h.pump();
		}
		assert (await h.pwd(1 as PaneId)) == `file://localhost${moved}`;

		const _split = await ran(ws, h, { kind: CommandKind.Split, pane: 1 as PaneId, axis: Axis.SideBySide }, seen);
		assert h.paneOf(2 as PaneId) !== null;
		assert typed(h, 2, "printf 'two%stwo\\n' \"$PWD\"\r");
		assert await prints(h, seen, 2, `two${moved}two`);
		assert !printedBy(seen, 1).includes(`two${moved}two`);
		assert !printedBy(seen, 2).includes("one-one");

		const resized = await ran(ws, h, { kind: CommandKind.Resize, direction: Direction.Left, cells: 5 }, seen);
		let cols: int32 = -1;
		for (const e of resized) {
			if (e.kind == EventKind.PaneResized && e.pane == (2 as PaneId)) { cols = e.rect.cols; }
		}
		assert cols > 0;
		assert typed(h, 2, "echo size-$(stty size | tr ' ' x)\r");
		assert await prints(h, seen, 2, `size-${ROWS}x${cols}`);

		assert typed(h, 2, "printf '\\033]2;named\\007'\r");
		const titled: float64 = performance.now();
		while ((await h.title(2 as PaneId)) != "named" && performance.now() - titled < WAIT_MS) {
			const _more = await h.pump();
		}
		assert (await h.title(2 as PaneId)) == "named";

		assert seen.gaps == "", seen.gaps;
		assert (seen.seqs.get(1) ?? 0) > 0 && (seen.seqs.get(2) ?? 0) > 0;
		const _closed = await ran(ws, h, { kind: CommandKind.ClosePane, pane: 2 as PaneId }, seen);
		assert h.paneOf(2 as PaneId) === null;
		assert !h.write(2 as PaneId, [0x61]);
		await h.closeAll();
		assert seen.fatal == "", seen.fatal;
	}

	test "a pane is busy while a job runs, reports its shell's exit code, and has no snapshot yet" {
		const seen = fresh();
		const dir = dirNamed("hostBusy", seen);
		const w = Workspace.create(1);
		assert w.ok;
		if (!w.ok) { return; }
		const h = hostIn(dir, seen);
		const _tab = await ran(w.value, h, { kind: CommandKind.NewTab }, seen);
		const id = 1 as PaneId;
		assert typed(h, 1, "echo ready\r");
		assert await prints(h, seen, 1, "ready");
		assert !(await h.busy(id));
		assert typed(h, 1, "sleep 3\r");
		const start: float64 = performance.now();
		let held = false;
		while (!held && performance.now() - start < WAIT_MS) {
			const _more = await h.pump();
			held = await h.busy(id);
		}
		assert held;
		assert typed(h, 1, "\x03");

		const shot = await h.snapshot(id);
		assert !shot.ok && shot.error == PaneHostError.SnapshotUnavailable;
		const unknown = await h.snapshot(9 as PaneId);
		assert !unknown.ok && unknown.error == PaneHostError.UnknownPane;

		assert typed(h, 1, "exit 3\r");
		const waited: float64 = performance.now();
		while (seen.exits == "" && performance.now() - waited < WAIT_MS) { const _more = await h.pump(); }
		assert seen.exits == "1:3 ", seen.exits;
		await h.closeAll();
		assert seen.gaps == "", seen.gaps;
		assert seen.fatal == "", seen.fatal;
	}
}
