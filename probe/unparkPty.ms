import { Session } from "../src/session/session";
import { NativePty } from "../src/pty/pty";

function main(): int32 {
	const pty = NativePty.spawn("cmd.exe /c echo mutable-buffer-smoke", 40, 5);
	if (!pty.ok) {
		console.log("FAIL: ConPTY did not open");
		return 1;
	}
	const started = Session.start(pty.value, 40, 5);
	if (!started.ok) {
		console.log("FAIL: ConPTY session did not start");
		return 1;
	}
	const s = started.value;
	let buf: Vec<uint8> = new Array(4096);
	while (true) {
		const ready = s.pty.wait(10000);
		if (!ready.ok || !ready.value) {
			s.close();
			console.log("FAIL: ConPTY output wait failed or timed out");
			return 1;
		}
		const alive = s.pump(buf);
		if (!alive.ok) {
			s.close();
			console.log("FAIL: pumping ConPTY output into the VT failed");
			return 1;
		}
		if (!alive.value) { break; }
	}
	const screen = s.screen();
	const code = s.pty.exitCode();
	s.close();
	if (!screen.ok) {
		console.log("FAIL: VT screen read failed");
		return 1;
	}
	if (screen.value.join("\n") != "mutable-buffer-smoke\n\n\n\n" || code !== 0) {
		console.log("FAIL: unexpected VT screen or child exit code");
		console.log(screen.value.join("\n"));
		return 1;
	}
	console.log(
		"PASS: cmd.exe -> ConPTY -> mutable buffer -> VT screen: mutable-buffer-smoke; exit=0",
	);
	return 0;
}

process.exit(main());
