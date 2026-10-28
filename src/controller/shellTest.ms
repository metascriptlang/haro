import { Shell, closeThen, closed, portOf } from "./shell";
import { defaults } from "../config/config";
import { IoFrame, settingsOf } from "./io";
import { KeyMod, NO_MODS, modSet } from "../keys/keys";
import { key } from "./terminalRig";
import { Rgb, ShellStep } from "../vt/vt";

test "a shell actor opens its recording, fits, and hands out the recorded rows in a frame" {
	const shell = new Shell({ command: "", cwd: null, recording: "hello" });
	assert (await shell.openError()) === null;
	const port = portOf(shell);
	port.fit(20, 3, 0, 0);
	port.key({ ...key("KeyA", NO_MODS), unshifted: 0x61, text: "a" }, 1);
	const got = await shell.frame();
	assert got !== null;
	if (got !== null) {
		assert got.started;
		assert got.failures.length == 0;
		const f = got.frame;
		assert f !== null;
		if (f !== null) {
			const rows = f.rows;
			assert rows !== null;
			if (rows !== null) { assert rows.rows[0].line.text.startsWith("hello"); }
		}
	}
	let seen = false;
	port.frame((next: IoFrame): void => { seen = next.started; });
	assert (await shell.openError()) === null;
	assert seen;
	await closed(shell);
	assert (await shell.frame()) === null;
}

function firstChanged(got: IoFrame | null): string {
	if (got === null) { return "unchanged"; }
	const f = got.frame;
	if (f === null) { return "unchanged"; }
	const rows = f.rows;
	if (rows === null || rows.rows.length == 0) { return "unchanged"; }
	return rows.rows[0].line.text;
}

test "a key with modifiers reaches the shell intact and runs the keybind its chord names" {
	const shell = new Shell({ command: "", cwd: null, recording: "l0\r\nl1\r\nl2\r\nl3\r\nl4\r\nl5\r\nl6\r\nl7\r\nl8\r\nl9" });
	const port = portOf(shell);
	port.fit(20, 3, 0, 0);
	const bottom = firstChanged(await shell.frame());
	assert bottom.startsWith("l7");
	port.key(key("PageUp", NO_MODS), 1);
	assert firstChanged(await shell.frame()) == "unchanged";
	port.key(key("PageUp", modSet(KeyMod.Ctrl) | modSet(KeyMod.Shift)), 2);
	const scrolled = firstChanged(await shell.frame());
	assert scrolled.startsWith("l") && !scrolled.startsWith("l7");
	await closed(shell);
}

async function echoed(shell: Shell): Promise<string> {
	const start: float64 = performance.now();
	while (performance.now() - start < 5000) {
		const changed = firstChanged(await shell.frame());
		if (changed.startsWith("hi")) { return changed; }
	}
	return "";
}

when (!windows) {
	test "a typed key's text reaches the program and its echo reaches the frame" {
		const shell = new Shell({ command: "cat", cwd: null, recording: null });
		const port = portOf(shell);
		port.fit(20, 3, 0, 0);
		port.text("hi", 7);
		assert (await echoed(shell)).startsWith("hi");
		await closed(shell);
	}
}

test "configure gives the next frame the configured colours" {
	const shell = new Shell({ command: "", cwd: null, recording: "x" });
	const port = portOf(shell);
	port.configure({ ...settingsOf(defaults()), background: { r: 1, g: 2, b: 3 } });
	port.fit(20, 3, 0, 0);
	const got = await shell.frame();
	assert got !== null;
	if (got !== null) {
		const f = got.frame;
		assert f !== null;
		if (f !== null) {
			const colors = f.colors;
			assert colors !== null;
			if (colors !== null) { assert colors.bg.r == 1 && colors.bg.g == 2 && colors.bg.b == 3; }
		}
	}
	await closed(shell);
}

test "relight repaints the cursor's row in the ink it is given" {
	const shell = new Shell({ command: "", cwd: null, recording: "hello" });
	portOf(shell).fit(20, 3, 0, 0);
	const _first = await shell.frame();
	const rows = await shell.relight({ fg: null, bg: { r: 9, g: 9, b: 9 } });
	assert rows.rows.length == 1;
	assert rows.rows[0].y == 0;
	assert rows.rows[0].line.text.startsWith("hello");
	await closed(shell);
}

test "closeThen runs its continuation once, after the shell is shut down" {
	const shell = new Shell({ command: "", cwd: null, recording: "x" });
	portOf(shell).fit(20, 3, 0, 0);
	let ran = 0;
	await closeThen(shell, (): void => { ran += 1; });
	assert ran == 1;
	assert (await shell.frame()) === null;
}

test "a shell shut down twice is closed once, and every call after it does nothing" {
	const shell = new Shell({ command: "", cwd: null, recording: "x" });
	const port = portOf(shell);
	port.fit(20, 3, 0, 0);
	assert await shell.shutdown();
	assert !(await shell.shutdown());
	port.key({ ...key("KeyA", NO_MODS), unshifted: 0x61, text: "a" }, 1);
	port.text("b", 2);
	port.fit(30, 5, 0, 0);
	port.autoscroll();
	port.closeKey();
	assert (await shell.frame()) === null;
	assert (await shell.relight(null)).rows.length == 0;
}

const TINT: Rgb = { r: 58, g: 28, b: 36 };

test "a decoration sent through the shell's port tints the next frame's rows" {
	const ran = "\x1b]133;A\x07$ false\r\n\x1b]133;C\x07oops\r\n\x1b]133;D;1\x07\x1b]133;A\x07$ ";
	const shell = new Shell({ command: "", cwd: null, recording: ran });
	const port = portOf(shell);
	port.fit(20, 3, 0, 0);
	const first = await shell.frame();
	let from = -1;
	let to = -1;
	if (first !== null && first.frame !== null) {
		for (const m of first.frame.shell) {
			if (m.step === ShellStep.CommandDone) {
				from = m.done.prompt ?? -1;
				to = m.done.end;
			}
		}
	}
	port.decorate({ id: 7, from: from, to: to, tint: { fg: null, bg: TINT } });
	const next = await shell.frame();
	let tinted: string[] = [];
	if (next !== null && next.frame !== null && next.frame.rows !== null) {
		for (const r of next.frame.rows.rows) {
			if (r.line.runs.length > 0 && r.line.runs[0].bg == TINT) { tinted.push(`${r.y}`); }
		}
	}
	assert tinted.join(",") == "0,1";
	port.undecorate(7);
	assert firstChanged(await shell.frame()) == "$ false";
	await closed(shell);
}

test "an annotation sent through the shell's port shows on the next frame's prompt row" {
	const ran = "\x1b]133;A\x07$ false\r\n\x1b]133;C\x07oops\r\n\x1b]133;D;1\x07\x1b]133;A\x07$ ";
	const shell = new Shell({ command: "", cwd: null, recording: ran });
	const port = portOf(shell);
	port.fit(20, 3, 0, 0);
	const first = await shell.frame();
	let at = -1;
	if (first !== null && first.frame !== null) {
		for (const m of first.frame.shell) {
			if (m.step === ShellStep.CommandDone) { at = m.done.prompt ?? -1; }
		}
	}
	port.annotate({ id: 3, at: at, note: { text: "exit 1", fg: null, bg: null } });
	assert firstChanged(await shell.frame()) == "$ false       exit 1";
	port.unannotate(3);
	assert firstChanged(await shell.frame()) == "$ false";
	await closed(shell);
}
