// The terminal's pages come from the C heap, so a 64 MB malloc must not run into them.
@include("./memShim.h");
@compile("./memShim.c");

import { Vt } from "../../src/vt/vt";
import { firstRowText } from "./vtWebCheck";

extern function vtClobber(mb: int32): int32;

function main(): int32 {
	const created = Vt.create(20, 4);
	if (!created.ok) { return 1; }
	const vt = created.value;
	vt.writeText("hello");
	if (!vt.update().ok) { return 1; }
	const before = vt.rows();
	if (!before.ok) { return 1; }
	console.log(`vtWebOverlap: before = "${firstRowText(before.value)}"`);
	console.log(`vtWebOverlap: clobber -> ${vtClobber(64)}`);
	const after = vt.rows();
	if (!after.ok) {
		console.log("vtWebOverlap: rows failed after the allocation");
		return 2;
	}
	console.log(`vtWebOverlap: after  = "${firstRowText(after.value)}"`);
	return firstRowText(after.value).trim() == "hello" ? 0 : 3;
}

process.exit(main());
