// Probe: can msc import libghostty-vt's header directly and drive a terminal?

@passC("-I../vendor/ghostty/include");
@passC("-DGHOSTTY_STATIC");
@link("../vendor/ghostty/zig-out/lib/ghostty-vt-static.lib");

import { ghostty_terminal_new, ghostty_terminal_vt_write, ghostty_terminal_free, GhosttyTerminal } from "../vendor/ghostty/include/ghostty/vt.h";

function main(): int32 {
	let term = null as unknown as GhosttyTerminal;
	const r = ghostty_terminal_new(null, term, 80, 24);
	console.log(`new: ${r as int32}`);
	const text = "hello\r\n";
	ghostty_terminal_vt_write(term, text, text.length);
	ghostty_terminal_free(term);
	return 0;
}

process.exit(main());
