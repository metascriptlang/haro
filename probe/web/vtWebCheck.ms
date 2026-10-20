import { Row, Vt } from "../../src/vt/vt";

export enum HelloError {
	Create,
	Update,
	Rows,
}

export struct HelloScreen {
	vt: Vt;
	rows: Vec<Row>;
}

export function writeHello(): Result<HelloScreen, HelloError> {
	const created = Vt.create(20, 4);
	if (!created.ok) { return Result.err(HelloError.Create); }
	const vt = created.value;
	vt.writeText("hello\r\n\x1b[31mred\x1b[0m");
	if (!vt.update().ok) { return Result.err(HelloError.Update); }
	const rows = vt.rows();
	if (!rows.ok) { return Result.err(HelloError.Rows); }
	return Result.ok({ vt: vt, rows: rows.value });
}

export function firstRowText(rows: Vec<Row>): string {
	let line = "";
	for (const cell of rows[0].cells) {
		line += cell.cp == 0 ? " " : String.fromCharCode(cell.cp as int32);
	}
	return line;
}

export function checkVt(word: string): int32 {
	const hello = writeHello();
	if (!hello.ok) {
		return match (hello.error) {
			HelloError.Create => 10,
			HelloError.Update => 11,
			HelloError.Rows => 12,
		};
	}
	const screen = hello.value;
	const first = screen.rows[0].cells;
	for (let i = 0; i < word.length; i++) {
		if (first[i].cp != (word.charCodeAt(i) as uint32)) { return 20 + i; }
	}
	const red = screen.rows[1].cells[0];
	if (red.cp != ("r".charCodeAt(0) as uint32)) { return 30; }
	const plain = screen.rows[0].cells[0];
	if (red.fg == plain.fg) { return 31; }
	screen.vt.free();
	return 0;
}
