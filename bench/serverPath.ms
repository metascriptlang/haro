import { removeAll } from "std/fs";
import { join } from "std/fs/path";
import { hostname, tmpDir } from "std/os";
import {
	ChildProcess,
	ChildStream,
	argv,
	env,
	execPath,
	exit,
	spawn as spawnProcess,
} from "std/process";
import { NativePty, spawn } from "../src/pty/pty";
import { Pty, PtyError } from "../src/pty/transport";
import { RemotePty, Seed, asPty, empty, feed, seededVt } from "../src/pty/remote";
import { Term, drain, fit, openTerm, sendInput, settleSize, shutdown } from "../src/controller/term";
import { free, vtBuild } from "../src/vt/vt";
import { MAX_SCREEN_BYTES, Message, MessageKind } from "../src/server/protocol";
import { Server, start } from "../src/server/serve";
import { askStop } from "../src/server/control";
import { connectToUnix, socketPath } from "../src/server/transport";
import { ServerLink, attach } from "../src/client/link";
import { Axis, CellRect, PaneId, panes } from "../src/workspace/tree";
import { CommandKind, EventKind, Tab, Workspace, apply, create } from "../src/workspace/workspace";

when (!windows) {
	@include("sys/resource.h");

	extern struct TimeVal from "struct timeval" {
		tv_sec: int64;
		tv_usec: int64;
	}
	extern struct Usage from "struct rusage" {
		ru_utime: TimeVal;
		ru_stime: TimeVal;
	}
	extern function getrusage(who: int32, ref usage: Usage): int32;
}

const COLS: int32 = 120;
const ROWS: int32 = 40;
const DIVIDER_CELLS: int32 = 1;
const PROMPT = "PR> ";
const SHELL_COMMAND = "exec env PS1='PR> ' ENV= BASH_SILENCE_DEPRECATION_WARNING=1 /bin/sh -i";
const DONE_MARK = "#DONE#";
const DONE_PRINT = "printf '#DO%s\\n' 'NE#'";
const LINE = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" +
	"0123456789abcdefg";
const TAIL_BYTES: int32 = 64;
const ECHO_KEYS: int32 = 500;
const KEY_GAP_MS: float64 = 5;
const KEY_TIMEOUT_MS: float64 = 5000;
const FLOOD_LEAD_MS: float64 = 500;
const SETUP_TIMEOUT_MS: float64 = 20000;
const FLOOD_TIMEOUT_MS: float64 = 600000;
const ATTACH_TIMEOUT_MS: int32 = 30000;
const SERVER_START_MS: float64 = 10000;
const SCROLLBACK_LINES: int32 = 50000;
const MB: float64 = 1000000.0;
const INTERRUPT: uint8 = 0x03;
const RUSAGE_SELF: int32 = 0;

function cpuMs(): float64 {
	when (windows) {
		return 0;
	} else {
		let u: Usage = {};
		const _got = getrusage(RUSAGE_SELF, u);
		const user = (u.ru_utime.tv_sec as float64) * 1000.0 + (u.ru_utime.tv_usec as float64) / 1000.0;
		const sys = (u.ru_stime.tv_sec as float64) * 1000.0 + (u.ru_stime.tv_usec as float64) / 1000.0;
		return user + sys;
	}
}

function bytesOf(text: string): Vec<uint8> {
	return [...text.asBytes()];
}

class Watch {
	bytes: int64 = 0;
	pattern: Vec<uint8> = [];
	matched: int32 = 0;
	found: boolean = false;
	heldAt: float64 = -1;
}

function expect(this w: Watch, pattern: Vec<uint8>): void {
	w.pattern = pattern;
	w.matched = 0;
	w.found = false;
	w.heldAt = -1;
}

function scan(this w: Watch, buf: Span<uint8>, n: int32): void {
	w.bytes += n as int64;
	if (w.found || w.pattern.length == 0) { return; }
	const from = Math.max(0, n - TAIL_BYTES);
	if (from > 0) { w.matched = 0; }
	for (let i = from; i < n; i++) {
		const b = buf[i];
		if (b == w.pattern[w.matched]) {
			w.matched += 1;
		} else {
			w.matched = b == w.pattern[0] ? 1 : 0;
		}
		if (w.matched == w.pattern.length) {
			w.found = true;
			return;
		}
	}
}

function settle(this w: Watch): void {
	if (w.found && w.heldAt < 0) { w.heldAt = performance.now(); }
}

function watched(pty: Pty, w: Watch): Pty {
	return {
		...pty,
		read: (buf: Span<uint8>): Result<int32, PtyError> => {
			const got = pty.read(buf);
			if (got.ok && got.value > 0) { w.scan(buf, got.value); }
			return got;
		},
	};
}

class BenchPane {
	id: PaneId;
	term: Term;
	watch: Watch;
	remote: RemotePty | null;

	constructor(id: PaneId, term: Term, watch: Watch, remote: RemotePty | null) {
		this.id = id;
		this.term = term;
		this.watch = watch;
		this.remote = remote;
	}
}

function localPane(id: PaneId, rect: CellRect): Result<BenchPane, string> {
	const w = new Watch();
	const opened = openTerm((cols: int32, rows: int32): Result<Pty, PtyError> => {
		const native = NativePty.spawn(SHELL_COMMAND, cols, rows);
		if (!native.ok) { return Result.err(native.error); }
		return Result.ok(watched(native.value, w));
	});
	if (!opened.ok) { return Result.err(`open: ${opened.error.toString()}`); }
	const fitted = opened.value.fit(rect.cols, rect.rows);
	if (!fitted.ok) { return Result.err(`fit: ${fitted.error.toString()}`); }
	return Result.ok(new BenchPane(id, opened.value, w, null));
}

function remotePane(id: PaneId, seed: Seed, rect: CellRect): Result<BenchPane, string> {
	const w = new Watch();
	const remote = RemotePty.empty();
	const opened = openTerm((cols: int32, rows: int32): Result<Pty, PtyError> => {
		return Result.ok(watched(remote.asPty(), w));
	});
	if (!opened.ok) { return Result.err(`open: ${opened.error.toString()}`); }
	opened.value.seed = seed;
	const fitted = opened.value.fit(rect.cols, rect.rows);
	if (!fitted.ok) { return Result.err(`fit: ${fitted.error.toString()}`); }
	return Result.ok(new BenchPane(id, opened.value, w, remote));
}

function rectOf(tabs: Tab[], id: PaneId): CellRect | null {
	for (const tab of tabs) {
		for (const p of tab.root.panes()) {
			if (p.id == id) { return p.rect; }
		}
	}
	return null;
}

interface Driver {
	panes: BenchPane[];
	input: (p: BenchPane, bytes: Vec<uint8>) => void;
	poll: (focus: BenchPane) => Promise<Result<void, string>>;
	split: () => Promise<Result<BenchPane, string>>;
	close: () => Promise<Result<float64, string>>;
}

function drainOnce(p: BenchPane): Result<boolean, string> {
	const drained = p.term.drain();
	if (!drained.ok) { return Result.err(`drain: ${drained.error.toString()}`); }
	p.watch.settle();
	return Result.ok(drained.value);
}

function localDriver(): Result<Driver, string> {
	const made = Workspace.create(DIVIDER_CELLS);
	if (!made.ok) { return Result.err(`workspace: ${made.error.toString()}`); }
	const ws = made.value;
	const tabbed = ws.apply({ kind: CommandKind.NewTab }, COLS, ROWS);
	if (!tabbed.ok) { return Result.err(`new tab: ${tabbed.error.toString()}`); }
	const first = ws.tabs[0].root.panes()[0];
	const opened = try localPane(first.id, first.rect);
	const all: BenchPane[] = [opened];
	const split = async (): Promise<Result<BenchPane, string>> => {
		const events = ws.apply(
			{ kind: CommandKind.Split, pane: first.id, axis: Axis.SideBySide },
			COLS,
			ROWS,
		);
		if (!events.ok) { return Result.err(`split: ${events.error.toString()}`); }
		const placed = ws.tabs[0].root.panes();
		const kept = rectOf(ws.tabs, first.id);
		if (kept === null) { return Result.err("split lost the first pane"); }
		const _fitted = opened.term.fit(kept.cols, kept.rows);
		const _settled = opened.term.settleSize();
		const second = placed[placed.length - 1];
		const p = try localPane(second.id, second.rect);
		all.push(p);
		return Result.ok(p);
	};
	return Result.ok({
		panes: all,
		input: (p: BenchPane, bytes: Vec<uint8>): void => {
			const _sent = p.term.sendInput(bytes);
		},
		poll: async (focus: BenchPane): Promise<Result<void, string>> => {
			let any = false;
			for (const p of all) {
				const s = p.term.session;
				if (s === null) { continue; }
				const ready = s.pty.wait(0);
				if (ready.ok && ready.value) {
					const _more = try drainOnce(p);
					any = true;
				}
			}
			const s = focus.term.session;
			if (!any && s !== null) { const _ready = s.pty.wait(1); }
			return Result.ok(null);
		},
		split: split,
		close: async (): Promise<Result<float64, string>> => {
			for (const p of all) { p.term.shutdown(); }
			return Result.ok(0);
		},
	});
}

class ServerProc {
	readonly dir: string;
	readonly path: string;
	readonly child: ChildProcess;

	constructor(dir: string, path: string, child: ChildProcess) {
		this.dir = dir;
		this.path = path;
		this.child = child;
	}
}

let servers: int32 = 0;

async function startServer(): Promise<Result<ServerProc, string>> {
	servers += 1;
	const dir = join(tmpDir(), `haro-bench-${Date.now()}-${servers}`);
	const path = join(dir, "s.sock");
	const launched = spawnProcess("/usr/bin/env", [`HARO_SOCKET=${path}`, execPath, "--serve"]);
	if (!launched.ok) { return Result.err(`server spawn: ${launched.error.message}`); }
	const deadline = performance.now() + SERVER_START_MS;
	while (performance.now() < deadline) {
		const probe = await connectToUnix(path, 1000);
		if (probe.ok) {
			probe.value.close();
			return Result.ok(new ServerProc(dir, path, launched.value));
		}
		await sleepAsync(20);
	}
	launched.value.close();
	return Result.err(`the server never answered at ${path}`);
}

async function stopServer(s: ServerProc): Promise<Result<float64, string>> {
	const stopped = await askStop(s.path);
	let said = "";
	const deadline = performance.now() + 10000;
	while (performance.now() < deadline) {
		const got = s.child.read(ChildStream.Stdout, 10000);
		if (!got.ok || got.value.ended) { break; }
		said += got.value.data;
	}
	const _waited = s.child.wait(5000);
	for (const line of s.child.takeStderr().split("\n")) {
		if (line != "" && !line.includes("serving") && !line.includes("stop asked")) {
			console.log(`SERVER LOG ${line}`);
		}
	}
	s.child.close();
	const _removed = removeAll(s.dir);
	if (!stopped.ok) { return Result.err(stopped.error); }
	for (const line of said.split("\n")) {
		if (line.startsWith("cpu ")) { return Result.ok(parseFloat(line.slice(4))); }
	}
	return Result.err(`the server reported no cpu line: ${said}`);
}

class Client {
	readonly link: ServerLink;
	panes: BenchPane[] = [];
	tabs: Tab[] = [];
	opened: PaneId[] = [];
	failure: string = "";

	constructor(link: ServerLink) { this.link = link; }
}

function paneOf(this c: Client, id: PaneId): BenchPane | null {
	for (const p of c.panes) {
		if (p.id == id) { return p; }
	}
	return null;
}

function output(this c: Client, id: PaneId, seq: uint64, bytes: Vec<uint8>): void {
	const p = c.paneOf(id);
	const remote = p?.remote ?? null;
	if (p === null || remote === null) { return; }
	if (!remote.feed(seq, bytes)) {
		c.failure = `pane ${id as int32} output out of order at ${seq}`;
		return;
	}
	let more = true;
	while (more) {
		const drained = drainOnce(p);
		if (!drained.ok) {
			c.failure = drained.error;
			return;
		}
		more = drained.value;
	}
}

function laidOut(this c: Client, tabs: Tab[]): void {
	c.tabs = tabs;
	for (const p of c.panes) {
		const rect = rectOf(tabs, p.id);
		if (rect !== null) { const _fitted = p.term.fit(rect.cols, rect.rows); }
	}
}

function paneOpened(this c: Client, id: PaneId): void {
	const rect = rectOf(c.tabs, id);
	if (rect === null) {
		c.failure = `pane ${id as int32} opened outside the layout`;
		return;
	}
	const seed: Seed = { native: false, cols: rect.cols, rows: rect.rows, bytes: [] };
	const made = remotePane(id, seed, rect);
	if (!made.ok) {
		c.failure = made.error;
		return;
	}
	c.panes.push(made.value);
	c.opened.push(id);
}

function received(this c: Client, m: Message): void {
	if (m.kind == MessageKind.Output) {
		c.output(m.pane, m.seq, [...m.bytes]);
	} else if (m.kind == MessageKind.Layout) {
		c.laidOut(m.tabs);
	} else if (m.kind == MessageKind.Event) {
		const e = m.event;
		if (e.kind == EventKind.PaneOpened) { c.paneOpened(e.pane); }
	} else if (m.kind == MessageKind.Failed) {
		c.failure = `pane ${m.pane as int32} failed: ${m.reason}`;
	}
}

async function linked(path: string): Promise<Result<ServerLink, string>> {
	const got = await connectToUnix(path, 2000);
	if (!got.ok) { return Result.err(`connect: ${got.error.toString()}`); }
	const link = new ServerLink(got.value);
	link.begin();
	return Result.ok(link);
}

async function attachClient(s: ServerProc): Promise<Result<Client, string>> {
	const link = try await linked(s.path);
	const got = await attach(link, vtBuild(), COLS, ROWS, ATTACH_TIMEOUT_MS);
	if (!got.ok) { return Result.err(`attach: ${got.error.why}`); }
	const c = new Client(link);
	c.tabs = got.value.layout.tabs;
	for (const screen of got.value.screens) {
		const rect = rectOf(c.tabs, screen.pane);
		if (rect === null) { return Result.err(`screen for unknown pane ${screen.pane as int32}`); }
		c.panes.push(try remotePane(screen.pane, screen.seed, rect));
	}
	link.listen((m: Message): void => { c.received(m); }, (why: string): void => {
		if (c.failure == "") { c.failure = `link ended: ${why}`; }
	});
	return Result.ok(c);
}

function detachClient(c: Client): void {
	c.link.detach();
	for (const p of c.panes) { p.term.shutdown(); }
}

async function clientDriver(): Promise<Result<Driver, string>> {
	const s = try await startServer();
	const attached = await attachClient(s);
	if (!attached.ok) {
		const _stopped = await stopServer(s);
		return Result.err(attached.error);
	}
	const c = attached.value;
	return Result.ok({
		panes: c.panes,
		input: (p: BenchPane, bytes: Vec<uint8>): void => { c.link.input(p.id, bytes); },
		poll: async (focus: BenchPane): Promise<Result<void, string>> => {
			if (c.failure != "") { return Result.err(c.failure); }
			await sleepAsync(1);
			return Result.ok(null);
		},
		split: async (): Promise<Result<BenchPane, string>> => {
			const before = c.opened.length;
			c.link.command({ kind: CommandKind.Split, pane: c.panes[0].id, axis: Axis.SideBySide });
			const deadline = performance.now() + SETUP_TIMEOUT_MS;
			while (c.opened.length == before) {
				if (c.failure != "") { return Result.err(c.failure); }
				if (performance.now() > deadline) { return Result.err("the split never opened"); }
				await sleepAsync(1);
			}
			const p = c.paneOf(c.opened[c.opened.length - 1]);
			if (p === null) { return Result.err("the opened pane has no client term"); }
			return Result.ok(p);
		},
		close: async (): Promise<Result<float64, string>> => {
			detachClient(c);
			return await stopServer(s);
		},
	});
}

async function waitFor(
	d: Driver,
	focus: BenchPane,
	done: () => boolean,
	timeoutMs: float64,
): Promise<Result<boolean, string>> {
	const deadline = performance.now() + timeoutMs;
	while (!done()) {
		if (performance.now() > deadline) { return Result.ok(false); }
		try await d.poll(focus);
	}
	return Result.ok(true);
}

async function pause(d: Driver, focus: BenchPane, ms: float64): Promise<Result<void, string>> {
	const until = performance.now() + ms;
	const _waited = try await waitFor(d, focus, (): boolean => performance.now() >= until, ms + 1000);
	return Result.ok(null);
}

async function run(
	d: Driver,
	p: BenchPane,
	command: string,
	mark: string,
	timeoutMs: float64,
): Promise<Result<float64, string>> {
	p.watch.expect(bytesOf(mark));
	const at = performance.now();
	d.input(p, bytesOf(command));
	const seen = try await waitFor(d, p, (): boolean => p.watch.heldAt >= 0, timeoutMs);
	if (!seen) { return Result.err(`no ${mark} after ${command.trim()}`); }
	return Result.ok(p.watch.heldAt - at);
}

async function prompted(d: Driver, p: BenchPane): Promise<Result<void, string>> {
	p.watch.expect(bytesOf(PROMPT));
	const seen = try await waitFor(d, p, (): boolean => p.watch.heldAt >= 0, SETUP_TIMEOUT_MS);
	if (!seen) { return Result.err("no prompt"); }
	return Result.ok(null);
}

struct Echoes {
	latencies: Vec<float64>;
	failure: string;
}

async function echoes(d: Driver, p: BenchPane): Promise<Echoes> {
	let latencies: Vec<float64> = [];
	for (let i: int32 = 0; i < ECHO_KEYS; i++) {
		const key = (97 + i % 26) as uint8;
		p.watch.expect([key]);
		const at = performance.now();
		d.input(p, [key]);
		const seen = await waitFor(d, p, (): boolean => p.watch.heldAt >= 0, KEY_TIMEOUT_MS);
		if (!seen.ok) { return { latencies: latencies, failure: seen.error }; }
		if (!seen.value) { return { latencies: latencies, failure: `key ${i} never echoed` }; }
		latencies.push(p.watch.heldAt - at);
		const paused = await pause(d, p, KEY_GAP_MS);
		if (!paused.ok) { return { latencies: latencies, failure: paused.error }; }
	}
	return { latencies: latencies, failure: "" };
}

struct Pair {
	key: string;
	value: float64;
}

struct Row {
	mode: string;
	measure: string;
	rep: int32;
	pairs: Vec<Pair>;
}

let header = "";
let rows: Vec<Row> = [];

function record(mode: string, measure: string, rep: int32, pairs: Vec<Pair>): void {
	rows.push({ mode: mode, measure: measure, rep: rep, pairs: pairs });
	const fields = pairs.map((p: Pair): string => `${p.key}=${p.value.toFixed(3)}`).join(" ");
	const repText = rep < 0 ? "all" : `${rep}`;
	console.log(`RESULT ${header} mode=${mode} measure=${measure} rep=${repText} ${fields}`);
}

function failed(mode: string, measure: string, rep: int32, done: Pair, why: string): void {
	record(mode, measure, rep, [done]);
	console.log(`FAILED ${header} mode=${mode} measure=${measure} rep=${rep} why=${why}`);
}

function percentile(values: Vec<float64>, p: float64): float64 {
	if (values.length == 0) { return 0; }
	let sorted = values.slice();
	sorted.sort((a: float64, b: float64): number => a - b);
	const at = Math.min(sorted.length - 1, (p * sorted.length as float64) as int32);
	return sorted[at];
}

function spread(values: Vec<float64>): Vec<Pair> {
	return [
		{ key: "p50_ms", value: percentile(values, 0.5) },
		{ key: "p99_ms", value: percentile(values, 0.99) },
		{ key: "p999_ms", value: percentile(values, 0.999) },
		{ key: "max_ms", value: percentile(values, 1.0) },
		{ key: "n", value: values.length as float64 },
	];
}

struct Pool {
	mode: string;
	measure: string;
	values: Vec<float64>;
}

let pools: Vec<Pool> = [];

function pool(mode: string, measure: string, values: Vec<float64>): void {
	for (let i = 0; i < pools.length; i++) {
		if (pools[i].mode == mode && pools[i].measure == measure) {
			for (const v of values) { pools[i].values.push(v); }
			return;
		}
	}
	pools.push({ mode: mode, measure: measure, values: [...values] });
}

function keysDone(e: Echoes): Pair {
	return { key: "failed_after_keys", value: e.latencies.length as float64 };
}

async function stopped(d: Driver, flood: BenchPane): Promise<Result<float64, string>> {
	flood.watch.expect(bytesOf(PROMPT));
	const at = performance.now();
	d.input(flood, [INTERRUPT]);
	const back = try await waitFor(d, flood, (): boolean => flood.watch.heldAt >= 0, FLOOD_TIMEOUT_MS);
	if (!back) { return Result.err("^C never brought the prompt back"); }
	return Result.ok(flood.watch.heldAt - at);
}

async function measuredEcho(
	mode: string,
	measure: string,
	rep: int32,
	d: Driver,
	echo: BenchPane,
): Promise<boolean> {
	const got = await echoes(d, echo);
	pool(mode, measure, got.latencies);
	if (got.failure != "") {
		failed(mode, measure, rep, keysDone(got), got.failure);
		return false;
	}
	record(mode, measure, rep, spread(got.latencies));
	return true;
}

async function loadedEcho(
	mode: string,
	measure: string,
	rep: int32,
	d: Driver,
	echo: BenchPane,
	flood: BenchPane,
	load: string,
): Promise<Result<boolean, string>> {
	d.input(flood, bytesOf(load));
	try await pause(d, flood, FLOOD_LEAD_MS);
	if (!(await measuredEcho(mode, measure, rep, d, echo))) { return Result.ok(false); }
	const _back = try await stopped(d, flood);
	return Result.ok(true);
}

async function session(
	mode: string,
	rep: int32,
	d: Driver,
	file: string,
): Promise<Result<void, string>> {
	const echo = d.panes[0];
	try await prompted(d, echo);
	const flood = try await d.split();
	try await prompted(d, flood);
	const _raw = try await run(d, echo, "stty raw -echo; echo R''EADY; exec cat\n", "READY", SETUP_TIMEOUT_MS);
	try await pause(d, echo, 200);
	if (!(await measuredEcho(mode, "echo_idle", rep, d, echo))) { return Result.ok(null); }
	const catLoad = `while :; do cat '${file}'; done\n`;
	if (!(try await loadedEcho(mode, "echo_loaded_cat", rep, d, echo, flood, catLoad))) {
		return Result.ok(null);
	}
	d.input(flood, bytesOf("yes\n"));
	try await pause(d, flood, FLOOD_LEAD_MS);
	const stopMs = await stopped(d, flood);
	if (!stopMs.ok) {
		failed(mode, "ctrl_c_yes", rep, { key: "failed", value: 1 }, stopMs.error);
		return Result.ok(null);
	}
	record(mode, "ctrl_c_yes", rep, [{ key: "ms", value: stopMs.value }]);
	const _yes = try await loadedEcho(mode, "echo_loaded_yes", rep, d, echo, flood, "yes\n");
	return Result.ok(null);
}

async function floodOnce(
	mode: string,
	rep: int32,
	d: Driver,
	file: string,
	fileBytes: float64,
): Promise<Result<float64, string>> {
	const p = d.panes[0];
	try await prompted(d, p);
	const cpuBefore = cpuMs();
	const at = performance.now();
	const ran = await run(d, p, `cat '${file}'; ${DONE_PRINT}\n`, DONE_MARK, FLOOD_TIMEOUT_MS);
	const clientCpu = cpuMs() - cpuBefore;
	const serverCpu = await d.close();
	if (!ran.ok) {
		const mbDone = (p.watch.bytes as float64) / MB;
		failed(mode, "flood", rep, { key: "failed_after_mb", value: mbDone }, `${ran.error} after ${mbDone.toFixed(1)} MB`);
		return Result.ok(-1);
	}
	const ms = ran.value;
	const mb = fileBytes / MB;
	record(mode, "flood", rep, [
		{ key: "mb_s", value: mb / (ms / 1000.0) },
		{ key: "ms", value: ms },
		{ key: "client_cpu_ms_per_mb", value: clientCpu / mb },
	]);
	return serverCpu;
}

async function idleServerCpu(): Promise<Result<float64, string>> {
	const d = try await clientDriver();
	try await prompted(d, d.panes[0]);
	return await d.close();
}

function ceiling(rep: int32, file: string, fileBytes: float64): Result<void, string> {
	const at = performance.now();
	const opened = NativePty.spawn(`cat '${file}'`, COLS, ROWS);
	if (!opened.ok) { return Result.err(`ceiling spawn: ${opened.error.toString()}`); }
	const pty = opened.value;
	let buf: Vec<uint8> = new Array(65536);
	let total: int64 = 0;
	while (true) {
		const ready = pty.wait(100);
		if (!ready.ok) { break; }
		if (!ready.value) {
			if (pty.exitCode() !== null) { break; }
			continue;
		}
		const got = pty.read(buf[0..buf.length]);
		if (!got.ok) { break; }
		total += got.value as int64;
	}
	const ms = performance.now() - at;
	pty.close();
	record("pty_only", "flood", rep, [
		{ key: "mb_s", value: fileBytes / MB / (ms / 1000.0) },
		{ key: "ms", value: ms },
		{ key: "pty_bytes", value: total as float64 },
	]);
	return Result.ok(null);
}

async function attachOnce(path: string, build: string): Promise<Result<Vec<Pair>, string>> {
	const at = performance.now();
	const link = try await linked(path);
	const got = await attach(link, build, COLS, ROWS, ATTACH_TIMEOUT_MS);
	if (!got.ok) { return Result.err(`attach: ${got.error.why}`); }
	const attachedAt = performance.now();
	let bytes = 0;
	for (const screen of got.value.screens) {
		bytes += screen.seed.bytes.length;
		const vt = screen.seed.seededVt();
		if (!vt.ok) { return Result.err(`seed: ${vt.error.toString()}`); }
		vt.value.free();
	}
	const seededAt = performance.now();
	link.detach();
	await sleepAsync(50);
	return Result.ok([
		{ key: "attach_ms", value: attachedAt - at },
		{ key: "seed_ms", value: seededAt - attachedAt },
		{ key: "total_ms", value: seededAt - at },
		{ key: "bytes", value: bytes as float64 },
	]);
}

async function attaches(s: ServerProc, label: string, reps: int32): Promise<Result<void, string>> {
	for (let rep: int32 = 1; rep <= reps; rep++) {
		record("client", `attach_${label}_native`, rep, try await attachOnce(s.path, vtBuild()));
		record("client", `attach_${label}_vtbytes`, rep, try await attachOnce(s.path, "bench-other-build"));
	}
	return Result.ok(null);
}

async function attachRun(reps: int32): Promise<Result<void, string>> {
	const s = try await startServer();
	const first = try await attachClient(s);
	const firstDriver: Driver = {
		panes: first.panes,
		input: (p: BenchPane, bytes: Vec<uint8>): void => { first.link.input(p.id, bytes); },
		poll: async (focus: BenchPane): Promise<Result<void, string>> => {
			if (first.failure != "") { return Result.err(first.failure); }
			await sleepAsync(1);
			return Result.ok(null);
		},
		split: async (): Promise<Result<BenchPane, string>> => Result.err("no split here"),
		close: async (): Promise<Result<float64, string>> => Result.ok(0),
	};
	const p = first.panes[0];
	try await prompted(firstDriver, p);
	detachClient(first);
	try await attaches(s, "empty", reps);
	const second = try await attachClient(s);
	const secondDriver: Driver = { ...firstDriver, panes: second.panes, input: (q: BenchPane, bytes: Vec<uint8>): void => {
		second.link.input(q.id, bytes);
	}, poll: async (focus: BenchPane): Promise<Result<void, string>> => {
		if (second.failure != "") { return Result.err(second.failure); }
		await sleepAsync(1);
		return Result.ok(null);
	} };
	const _filled = try await run(
		secondDriver,
		second.panes[0],
		`seq 1 ${SCROLLBACK_LINES}; ${DONE_PRINT}\n`,
		DONE_MARK,
		SETUP_TIMEOUT_MS,
	);
	detachClient(second);
	try await attaches(s, "50k", reps);
	const _cpu = try await stopServer(s);
	return Result.ok(null);
}

function makeFile(path: string, megabytes: int32): Result<float64, string> {
	const bytes = (megabytes as int64) * 1048576;
	const made = spawnProcess("/bin/sh", ["-c", `yes ${LINE} | head -c ${bytes} > '${path}'`]);
	if (!made.ok) { return Result.err(`flood file: ${made.error.message}`); }
	const done = made.value.wait(300000);
	made.value.close();
	if (!done.ok) { return Result.err(`flood file: ${done.error.message}`); }
	return Result.ok(bytes as float64);
}

function flagNumber(flag: string, fallback: int32): int32 {
	for (let i = 1; i + 1 < argv.length; i++) {
		if (argv[i] == flag) { return parseInt(argv[i + 1]) as int32; }
	}
	return fallback;
}

function hasFlag(flag: string): boolean {
	for (let i = 1; i < argv.length; i++) {
		if (argv[i] == flag) { return true; }
	}
	return false;
}

function osName(): string {
	when (macos) {
		return "macos";
	} else when (windows) {
		return "windows";
	} else {
		return "linux";
	}
}

function valuesOf(mode: string, measure: string, key: string): Vec<float64> {
	let out: Vec<float64> = [];
	for (const r of rows) {
		if (r.mode != mode || r.measure != measure || r.rep < 0) { continue; }
		for (const p of r.pairs) {
			if (p.key == key) { out.push(p.value); }
		}
	}
	return out;
}

function pooledValue(mode: string, measure: string, key: string): float64 | null {
	for (const r of rows) {
		if (r.mode != mode || r.measure != measure || r.rep >= 0) { continue; }
		for (const p of r.pairs) {
			if (p.key == key) { return p.value; }
		}
	}
	return null;
}

function cell(values: Vec<float64>): string {
	if (values.length == 0) { return "-"; }
	const mid = percentile(values, 0.5);
	const low = percentile(values, 0.0);
	const high = percentile(values, 1.0);
	return `${mid.toFixed(2)} [${low.toFixed(2)}..${high.toFixed(2)}]`;
}

function table(): void {
	let lines: Vec<string> = [];
	lines.push(`## ${header}`);
	lines.push("median [min..max] over reps; echo pooled = all keys of all reps");
	lines.push("| measure | key | in-process | client/server |");
	lines.push("|---|---|---|---|");
	let shown: Vec<string> = [];
	for (const r of rows) {
		if (r.rep < 0 || r.mode == "pty_only") { continue; }
		for (const p of r.pairs) {
			const id = `${r.measure} ${p.key}`;
			if (shown.includes(id) || p.key == "n") { continue; }
			shown.push(id);
			const local = cell(valuesOf("inproc", r.measure, p.key));
			const remote = cell(valuesOf("client", r.measure, p.key));
			lines.push(`| ${r.measure} | ${p.key} | ${local} | ${remote} |`);
		}
	}
	for (const measure of ["echo_idle", "echo_loaded_cat", "echo_loaded_yes"]) {
		for (const key of ["p50_ms", "p99_ms", "p999_ms", "max_ms"]) {
			const local = pooledValue("inproc", measure, key);
			const remote = pooledValue("client", measure, key);
			const l = local === null ? "-" : local.toFixed(2);
			const c = remote === null ? "-" : remote.toFixed(2);
			lines.push(`| ${measure} pooled | ${key} | ${l} | ${c} |`);
		}
	}
	lines.push(`| flood ceiling (pty only) | mb_s | ${cell(valuesOf("pty_only", "flood", "mb_s"))} | |`);
	console.log(lines.join("\n"));
}

async function bench(): Promise<Result<void, string>> {
	const reps = flagNumber("--reps", 3);
	const floodMb = flagNumber("--flood-mb", 200);
	const commit = env.get("BENCH_COMMIT");
	const msc = env.get("BENCH_MSC");
	header = `host=${hostname()} os=${osName()} commit=${commit != "" ? commit : "unknown"} ` +
		`msc=${msc != "" ? msc.replaceAll(" ", "_") : "unknown"}`;
	const dir = join(tmpDir(), `haro-bench-file-${Date.now()}`);
	const made = spawnProcess("/bin/mkdir", ["-p", dir]);
	if (made.ok) {
		const _done = made.value.wait(5000);
		made.value.close();
	}
	const file = join(dir, "flood.txt");
	const fileBytes = try makeFile(file, floodMb);
	const modes = ["inproc", "client"];
	for (let rep: int32 = 1; rep <= reps; rep++) {
		for (let m = 0; m < modes.length; m++) {
			const mode = modes[m];
			const d = mode == "client" ? try await clientDriver() : try localDriver();
			const ran = await session(mode, rep, d, file);
			const closed = await d.close();
			if (!ran.ok) { return Result.err(`${mode} rep ${rep}: ${ran.error}`); }
			if (!closed.ok) { return Result.err(`${mode} rep ${rep} close: ${closed.error}`); }
		}
		for (let m = 0; m < modes.length; m++) {
			const mode = modes[m];
			const d = mode == "client" ? try await clientDriver() : try localDriver();
			const serverCpu = try await floodOnce(mode, rep, d, file, fileBytes);
			if (mode == "client" && serverCpu >= 0) {
				const idle = try await idleServerCpu();
				record(mode, "flood_server", rep, [
					{ key: "server_cpu_ms_per_mb", value: (serverCpu - idle) / (fileBytes / MB) },
					{ key: "server_idle_cpu_ms", value: idle },
				]);
			}
		}
		try ceiling(rep, file, fileBytes);
	}
	for (const p of pools) { record(p.mode, p.measure, -1, spread(p.values)); }
	if (!hasFlag("--no-attach")) { try await attachRun(reps); }
	const _removed = removeAll(dir);
	table();
	return Result.ok(null);
}

async function serveBench(): Promise<int32> {
	const started = await Server.start({
		launch: { command: SHELL_COMMAND, shellScripts: null, startIn: null, originCwd: false },
		socket: socketPath(),
		dividerCells: DIVIDER_CELLS,
		tailnet: null,
		screenLimit: MAX_SCREEN_BYTES,
		log: (line: string): void => { console.error(line); },
	});
	if (!started.ok) {
		console.error(`bench server: ${started.error}`);
		return 1;
	}
	const code = await started.value.finished;
	console.log(`cpu ${cpuMs()}`);
	return code;
}

when (!testBuild) {
	if (hasFlag("--serve")) {
		exit(await serveBench());
	}
	const ran = await bench();
	if (!ran.ok) {
		console.log(`serverPath bench failed: ${ran.error}`);
		exit(1);
	}
	exit(0);
}
