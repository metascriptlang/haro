import { NativePty } from "../src/pty/pty";
import { writeFile } from "std/fs";
import { env, exit } from "std/process";

function main(): int32 {
	const path = `${env.get("TEMP")}/haroPtyFlood.txt`;
	let text = "";
	for (let i = 0; i < 1600000; i++) { text += `line ${i}\r\n`; }
	const _w = writeFile(path, text);
	const opened = NativePty.open(`cmd.exe /c type "${path.replaceAll("/", "\\")}"`, 80, 24);
	if (!opened.ok) { return 1; }
	const p = opened.value;
	const late: float64 = performance.now();
	while (performance.now() - late < 4000) {}
	let buf: Vec<uint8> = new Array(65536);
	let held = 0;
	while (true) {
		const ready = p.wait(0);
		if (!ready.ok || !ready.value) { break; }
		const r = p.read(buf);
		if (!r.ok || r.value == 0) { break; }
		held += r.value;
		if (held > 8388608) { break; }
	}
	const a = performance.now();
	p.close();
	console.log(`closeParked: ${held} bytes were waiting, close took ${performance.now() - a} ms, exit ${p.exitCode()}`);
	return 0;
}

exit(main());
