// Haro's Vt on the wasm libghostty-vt of scripts/buildVtWasm.sh, run under node:
//   msc build probe/web/vtWeb.ms --os=emcc --output=<dir>/vtWeb.js
import { free } from "../../src/vt/vt";
import { HelloError, firstRowText, writeHello } from "./vtWebCheck";

function failedStep(error: HelloError): string {
	return match (error) {
		HelloError.Create => "create",
		HelloError.Update => "update",
		HelloError.Rows => "rows",
	};
}

function main(): int32 {
	const hello = writeHello();
	if (!hello.ok) {
		console.log(`vtWeb: ${failedStep(hello.error)} failed`);
		return 1;
	}
	const screen = hello.value;
	console.log(`vtWeb: row 0 = "${firstRowText(screen.rows)}"`);
	const red = screen.rows[1].cells[0];
	console.log(`vtWeb: row 1 cell 0 cp=${red.cp} fg=${red.fg.r},${red.fg.g},${red.fg.b}`);
	screen.vt.free();
	return 0;
}

process.exit(main());
