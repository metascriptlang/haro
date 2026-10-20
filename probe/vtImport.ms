@passC("-I../vendor/ghostty/include");
@passC("-DGHOSTTY_STATIC");
@link("../out/ghostty/ghostty-vt-static.lib");

import {
	ghostty_terminal_new,
	ghostty_terminal_vt_write,
	ghostty_terminal_free,
	GhosttyTerminal,
} from "../vendor/ghostty/include/ghostty/vt.h";

function main(): int32 {
	let term: GhosttyTerminal;
	const r = ghostty_terminal_new(null, term, 80, 24);
	console.log(`new: ${r as int32}`);
	const text = "hello\r\n";
	ghostty_terminal_vt_write(term, text, text.length);
	ghostty_terminal_free(term);
	return 0;
}

process.exit(main());
