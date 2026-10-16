// W1 probe, variant with no output: the result is the exit code, 0 = every check passed.
import { Vt } from "../../src/vt/vt";

function check(): int32 {
	const created = Vt.create(20, 4);
	if (!created.ok) { return 10; }
	const vt = created.value;
	vt.writeText("hello\r\n\x1b[31mred\x1b[0m");
	if (!vt.update().ok) { return 11; }
	const rows = vt.rows();
	if (!rows.ok) { return 12; }
	const word = "hello";
	const first = rows.value[0].cells;
	for (let i = 0; i < word.length; i++) {
		if (first[i].cp != (word.charCodeAt(i) as uint32)) { return 20 + i; }
	}
	const red = rows.value[1].cells[0];
	if (red.cp != ("r".charCodeAt(0) as uint32)) { return 30; }
	const plain = rows.value[0].cells[0];
	if (red.fg == plain.fg) { return 31; }
	vt.free();
	return 0;
}

process.exit(check());
