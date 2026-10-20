// Haro's Vt on the wasm libghostty-vt of scripts/buildVtWasm.sh, run under node:
//   msc build probe/web/vtWeb.ms --os=emcc --output=<dir>/vtWeb.js
import { Vt } from "../../src/vt/vt";

function main(): int32 {
	const created = Vt.create(20, 4);
	if (!created.ok) {
		console.log("vtWeb: create failed");
		return 1;
	}
	const vt = created.value;
	vt.writeText("hello\r\n\x1b[31mred\x1b[0m");
	if (!vt.update().ok) {
		console.log("vtWeb: update failed");
		return 1;
	}
	const rows = vt.rows();
	if (!rows.ok) {
		console.log("vtWeb: rows failed");
		return 1;
	}
	let line = "";
	for (const cell of rows.value[0].cells) {
		line += cell.cp == 0 ? " " : String.fromCharCode(cell.cp as int32);
	}
	console.log(`vtWeb: row 0 = "${line}"`);
	const red = rows.value[1].cells[0];
	console.log(`vtWeb: row 1 cell 0 cp=${red.cp} fg=${red.fg.r},${red.fg.g},${red.fg.b}`);
	vt.free();
	return 0;
}

process.exit(main());
