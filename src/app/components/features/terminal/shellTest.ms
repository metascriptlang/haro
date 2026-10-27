import { Shell, closed, portOf } from "./shell";
import { IoFrame } from "./io";
import { key } from "./terminalRig";

test "a shell actor opens its recording, fits, and hands out the recorded rows in a frame" {
	const shell = new Shell({ command: "", cwd: null, recording: "hello" });
	assert (await shell.openError()) === null;
	const port = portOf(shell);
	port.fit(20, 3, 0, 0);
	port.key({ ...key("KeyA", 0), unshifted: 0x61, text: "a" }, 1);
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
