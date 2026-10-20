// node probe/web/vtStandalone.mjs <ghostty-vt.wasm of zig build -Demit-lib-vt -Dtarget=wasm32-freestanding>
import fs from "node:fs";

const { instance } = await WebAssembly.instantiate(fs.readFileSync(process.argv[2]), {});
const e = instance.exports;
const bytes = () => new Uint8Array(e.memory.buffer);
const view = () => new DataView(e.memory.buffer);
const check = (r, what) => { if (r !== 0) throw new Error(`${what}: ${r}`); };

const exported = Object.keys(e).filter((k) => k.startsWith("ghostty_")).length;
console.log(`vtStandalone: ${exported} ghostty_* exports, memory ${e.memory.buffer.byteLength} bytes at start`);

const slot = e.ghostty_wasm_alloc_opaque();
check(e.ghostty_terminal_new(0, slot, 20, 4), "terminal_new");
const term = e.ghostty_wasm_take_opaque(slot);
const text = new TextEncoder().encode("hello\r\nworld");
const ptr = e.ghostty_wasm_alloc(text.length);
bytes().set(text, ptr);
e.ghostty_terminal_vt_write(term, ptr, text.length);
const out = e.ghostty_wasm_alloc(8);
check(e.ghostty_terminal_get(term, 3, out), "cursor_x");
const x = view().getUint16(out, true);
check(e.ghostty_terminal_get(term, 4, out), "cursor_y");
const y = view().getUint16(out, true);
console.log(`vtStandalone: cursor after "hello\r\nworld" = (${x}, ${y}), expected (5, 1); memory now ${e.memory.buffer.byteLength} bytes`);
