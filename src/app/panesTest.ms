import { ensureDir } from "std/fs";
import { cwd } from "std/process";
import { defaults } from "../config/config";
import { ABNORMAL_EXIT_MS } from "../controller/term";
import { CommandDone } from "../vt/vt";
import { HookPane, KeyAnswer, UNHANDLED } from "../config/hooks";
import { KeyEvent } from "../keys/keys";
import { Stats, empty } from "./stats";
import { Axis, PaneId, TabId } from "../workspace/tree";
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
import { accessor } from "../../../neon/src/core/signal";
import { Action } from "../input/bindings";
import { CellMetrics } from "./components/ui/cellText";
import {
	ConfigChange,
	Desktop,
	HostEvents,
} from "./components/features/terminal/paneModel";
import {
	NewPaneCwd,
	PaneHost,
	Panes,
	RunningPane,
	apply as applyEvent,
	foregroundIsShell,
	open,
	paneOf,
	paneTiming,
	reportedCwd,
} from "./panes";

interface Frames {
	runs: (() => void)[];
}

test "a pane asks the window's frame once and runs only its latest scheduled run" {
	const frames: Frames = { runs: [] };
	const timing = paneTiming({
		clock: (): float64 => 0,
		schedule: (run: () => void): void => { frames.runs.push(run); },
	});
	let ran = "";
	timing.schedule((): void => { ran += "a"; });
	timing.schedule((): void => { ran += "b"; });
	assert frames.runs.length == 1;
	frames.runs[0]();
	assert ran == "b";
	timing.schedule((): void => { ran += "c"; });
	assert frames.runs.length == 2;
	frames.runs[1]();
	assert ran == "bc";
}

when (!windows) {
	const COLS: int32 = 81;
	const ROWS: int32 = 24;
	const WAIT_MS: float64 = 5000;
	const REPORT_PWD = `printf '\\033]7;file://localhost%s\\007' "$PWD"\r`;

	interface Seen {
		exits: string;
		fatal: string;
	}

	function desktopOf(pane: PaneId, seen: Seen): Desktop {
		return {
			setTitle: (title: string, belled: boolean): void => {},
			notify: (title: string, body: string): void => {},
			openLink: (uri: string): void => {},
			attention: (): void => {},
			setHand: (on: boolean): void => {},
			openConfig: (): void => {},
			reloadConfig: (): void => {},
			close: (): void => {},
			exited: (code: int32): void => { seen.exits += `${pane as int32}:${code} `; },
			windowAction: (action: Action): void => {},
		};
	}

	const QUIET: HostEvents = {
		onWake: (handler: () => void): void => {},
		onMenu: (handler: (id: string) => void): void => {},
		onCloseRequest: (handler: () => void): void => {},
		onConfig: (handler: (change: ConfigChange) => void): void => {},
	};

	const METRICS: CellMetrics = {
		fontSize: accessor((): number => 14),
		fontFamily: accessor((): string => ""),
		cellWidth: accessor((): number => 0),
		rowHeight: accessor((): number => 0),
	};

	function hostOf(seen: Seen): PaneHost {
		return {
			desktopFor: (pane: PaneId): Desktop => desktopOf(pane, seen),
			eventsFor: (pane: PaneId): HostEvents => QUIET,
			report: {
				note: (message: string): void => {},
				fail: (message: string): void => { seen.fatal = message; },
			},
			timing: {
				clock: (): float64 => performance.now(),
				schedule: (run: () => void): void => {},
			},
			keyHook: {
				answer: (pane: HookPane, k: KeyEvent): Result<KeyAnswer, string> => Result.ok(UNHANDLED),
			},
			shellHook: {
				prompted: (pane: HookPane, at: int32): Result<void, string> => Result.ok(null),
				commandDone: (pane: HookPane, done: CommandDone): Result<void, string> => Result.ok(null),
			},
			metrics: METRICS,
			started: defaults(),
			stats: Stats.empty(),
		};
	}

	function dirNamed(name: string, seen: Seen): string {
		const dir = `${cwd()}/out/${name}`;
		if (!ensureDir(dir).ok) { seen.fatal += `${dir} was not made\n`; }
		return dir;
	}

	function panesIn(start: string, seen: Seen): Panes {
		return Panes.open(
			{
				command: "sh",
				shellScripts: null,
				startIn: start,
				cwd: NewPaneCwd.Origin,
				recording: null,
			},
			hostOf(seen),
			0,
			0,
		);
	}

	async function ran(
		w: Workspace,
		p: Panes,
		c: WorkspaceCommand,
		seen: Seen,
	): Promise<WorkspaceEvent[]> {
		const events = w.apply(c, COLS, ROWS);
		if (!events.ok) {
			seen.fatal += `${c.kind.toString()}: ${events.error.toString()}\n`;
			return [];
		}
		for (const e of events.value) {
			const refused = await p.applyEvent(e);
			if (refused !== null) { seen.fatal += `${e.kind.toString()}: ${refused.toString()}\n`; }
		}
		return events.value;
	}

	function running(p: Panes, id: int32): RunningPane {
		return p.paneOf(id as PaneId)!;
	}

	async function reportsPwd(this pane: RunningPane, wanted: string): Promise<boolean> {
		const start: float64 = performance.now();
		while (performance.now() - start < WAIT_MS) {
			const _frame = await pane.shell.frame();
			if ((await pane.shell.pwd()) == wanted) { return true; }
		}
		return false;
	}

	async function reportsCwd(this pane: RunningPane, dir: string): Promise<boolean> {
		pane.model.io.text(REPORT_PWD, 0);
		return await reportsPwd(pane, `file://localhost${dir}`);
	}

	function colsOf(events: WorkspaceEvent[], id: int32): int32 {
		for (const e of events) {
			if (e.kind == EventKind.PaneResized && e.pane == (id as PaneId)) { return e.rect.cols; }
		}
		return -1;
	}

	test "panes start a shell per opened pane in the origin's cwd, resize, close, and report a shell's own exit" {
		const seen: Seen = { exits: "", fatal: "" };
		const start = dirNamed("panesStart", seen);
		const moved = dirNamed("panesMoved", seen);
		const w = Workspace.create(1);
		assert w.ok;
		if (!w.ok) { return; }
		const ws = w.value;
		const p = panesIn(start, seen);

		const _tab = await ran(ws, p, { kind: CommandKind.NewTab }, seen);
		const first = running(p, 1);
		assert await first.reportsCwd(start);
		first.model.io.text(`cd ${moved}\r`, 0);
		assert await first.reportsCwd(moved);

		const _split = await ran(ws, p, { kind: CommandKind.Split, pane: 1 as PaneId, axis: Axis.SideBySide }, seen);
		const second = running(p, 2);
		assert await second.reportsCwd(moved);

		const _newTab = await ran(ws, p, { kind: CommandKind.NewTab }, seen);
		assert await running(p, 3).reportsCwd(moved);
		const closedTab = await ran(ws, p, { kind: CommandKind.CloseTab, tab: 2 as TabId }, seen);
		assert closedTab[0].kind == EventKind.PaneClosed;
		assert p.paneOf(3 as PaneId) === null;

		const resized = await ran(ws, p, { kind: CommandKind.Resize, direction: Direction.Left, cells: 5 }, seen);
		const cols = colsOf(resized, 2);
		assert cols == 45, `${cols}`;
		second.model.io.text(`printf '\\033]7;file://localhost/%s\\007' "$(stty size | tr ' ' x)"\r`, 0);
		assert await second.reportsPwd(`file://localhost/${ROWS}x${cols}`);

		const closedPane = await ran(ws, p, { kind: CommandKind.ClosePane, pane: 2 as PaneId }, seen);
		assert closedPane[0].kind == EventKind.PaneClosed;
		assert p.paneOf(2 as PaneId) === null;
		assert colsOf(closedPane, 1) == COLS;

		const quick: float64 = performance.now();
		while (performance.now() - quick <= ABNORMAL_EXIT_MS) { const _frame = await first.shell.frame(); }
		first.model.io.text("exit 3\r", 0);
		const waited: float64 = performance.now();
		while (seen.exits == "" && performance.now() - waited < WAIT_MS) {
			first.model.refresh();
			const _pwd = await first.shell.pwd();
		}
		assert seen.exits == "1:3 ", seen.exits;
		assert seen.fatal == "", seen.fatal;
		const _closed = await ran(ws, p, { kind: CommandKind.ClosePane, pane: 1 as PaneId }, seen);
		assert p.running.length == 0;
	}

	test "a pane's foreground is its shell at the prompt and not while a job holds the terminal" {
		const seen: Seen = { exits: "", fatal: "" };
		const w = Workspace.create(1);
		assert w.ok;
		if (!w.ok) { return; }
		const dir = dirNamed("panesBusy", seen);
		const p = panesIn(dir, seen);
		const _tab = await ran(w.value, p, { kind: CommandKind.NewTab }, seen);
		const pane = running(p, 1);
		assert await pane.reportsCwd(dir);
		assert await pane.foregroundIsShell();
		pane.model.io.text("sleep 3\r", 0);
		const start: float64 = performance.now();
		let busy = false;
		while (!busy && performance.now() - start < WAIT_MS) {
			const _frame = await pane.shell.frame();
			busy = !(await pane.foregroundIsShell());
		}
		assert busy;
		const _closed = await ran(w.value, p, { kind: CommandKind.ClosePane, pane: 1 as PaneId }, seen);
		assert seen.fatal == "", seen.fatal;
	}
}
