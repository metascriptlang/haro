import { NativePty } from "../src/pty/pty";
import { argv, exit } from "std/process";

function main(): int32 {
	const mb = argv.length > 1 ? argv[1].parseInt() as int32 : 16;
	const spawned = NativePty.spawn("cmd /c ping -n 8 127.0.0.1 >nul", 80, 24);
	if (!spawned.ok) {
		console.log("writeBlock: the command did not start");
		return 1;
	}
	const pty = spawned.value;
	let chunk: Vec<uint8> = new Array(1048576);
	for (let i = 0; i < chunk.length; i++) { chunk[i] = 97 + (i % 26) as uint8; }
	let buf: Vec<uint8> = new Array(65536);
	let worst = 0.0;
	const start = performance.now();
	for (let m = 0; m < mb; m++) {
		const a = performance.now();
		const w = pty.write(chunk[0..chunk.length]);
		const took = performance.now() - a;
		worst = Math.max(worst, took);
		if (!w.ok) { console.log(`writeBlock: write ${m} failed`); break; }
		while (true) {
			const ready = pty.wait(0);
			if (!ready.ok || !ready.value) { break; }
			if (!pty.read(buf).ok) { break; }
		}
	}
	console.log(
		`writeBlock: ${mb} MiB written in ${performance.now() - start} ms, ` +
		`worst 1 MiB write ${worst} ms`,
	);
	pty.close();
	return 0;
}

exit(main());
