import { Shell, closed, portOf } from "./shell";
import { IoFrame } from "./io";
import { KeyMod, NO_MODS, modSet } from "../keys/keys";
import { key } from "./terminalRig";

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
