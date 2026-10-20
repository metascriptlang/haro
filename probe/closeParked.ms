import { NativePty } from "../src/pty/pty";
import { writeFile } from "std/fs";
import { env, exit } from "std/process";

const FLOOD_LINES: int32 = 1600000;
const PARK_MS: float64 = 4000.0;
const MAX_HELD_BYTES: int32 = 8 * 1048576;

function main(): int32 {
	const path = `${env.get("TEMP")}/haroPtyFlood.txt`;
	let text = "";
	for (let i = 0; i < FLOOD_LINES; i++) { text += `line ${i}\r\n`; }
	const _w = writeFile(path, text);
	const opened = NativePty.open(`cmd.exe /c type "${path.replaceAll("/", "\\")}"`, 80, 24);
	if (!opened.ok) { return 1; }
	const p = opened.value;
	const parkedAt: float64 = performance.now();
	while (performance.now() - parkedAt < PARK_MS) {}
	let buf: Vec<uint8> = new Array(65536);
	let held = 0;
	while (true) {
		const ready = p.wait(0);
		if (!ready.ok || !ready.value) { break; }
		const r = p.read(buf);
		if (!r.ok || r.value == 0) { break; }
		held += r.value;
		if (held > MAX_HELD_BYTES) { break; }
	}
	const closeStart = performance.now();
	p.close();
	console.log(
		`closeParked: ${held} bytes were waiting, ` +
		`close took ${performance.now() - closeStart} ms, exit ${p.exitCode()}`,
	);
	return 0;
}

exit(main());
