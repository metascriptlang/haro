// The patched wasm library has no default heap: terminal_new with a NULL allocator must fail.
@passC("-I../../vendor/ghostty/include");
@passC("-DGHOSTTY_STATIC");
@link("../../out/wasm/libghostty-vt.a");

import {
	ghostty_terminal_new,
	GhosttyTerminal,
} from "../../vendor/ghostty/include/ghostty/vt.h";

function main(): int32 {
	let term: GhosttyTerminal;
	const r = ghostty_terminal_new(null, term, 80, 24);
	console.log(`vtMin: terminal_new with a NULL allocator -> ${r as int32}`);
	return (r as int32) != 0 ? 0 : 1;
}

process.exit(main());
