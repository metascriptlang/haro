import { NativePty } from "../src/pty/pty";
import { argv, exit } from "std/process";
import { writeFile } from "std/fs";

function main(): int32 {
	if (argv.length < 5) {
		console.log("usage: recordPty <out> <cols> <rows> <command line...>");
		return 2;
	}
	const cols = argv[2].parseInt() as int32;
	const rows = argv[3].parseInt() as int32;
	let command = argv[4];
	for (let i = 5; i < argv.length; i++) { command += " " + argv[i]; }
	const spawned = NativePty.spawn(command, cols, rows);
	if (!spawned.ok) {
		console.log("recordPty: the command did not start");
		return 1;
	}
	const pty = spawned.value;
	let buf: Vec<uint8> = new Array(4096);
	const recorded: uint8[] = [];
	while (true) {
		const ready = pty.wait(10000);
		if (!ready.ok || !ready.value) { break; }
		const r = pty.read(buf);
		if (!r.ok) { break; }
		for (let i = 0; i < r.value; i++) { recorded.push(buf[i]); }
	}
	pty.close();
	const written = writeFile(argv[1], recorded.asString());
	if (!written.ok) {
		console.log("recordPty: the recording did not write");
		return 1;
	}
	console.log(`recordPty: ${recorded.length} bytes from ${command} at ${cols}x${rows}`);
	return 0;
}

exit(main());
