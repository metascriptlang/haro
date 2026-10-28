import {
	CellFlag,
	Rgb,
	Underline,
	Vt,
	clean,
	Grapheme,
	dirtyRows,
	graphemes,
	lines,
	linkAt,
	rows,
	text,
	update,
	writeText,
} from "./vt";
import { shown, withVt } from "./vtRig";

test "an OSC 8 link answers for each of its cells and for no others" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x1b]8;;https://example.com/a?b=1\x1b\\link\x1b]8;;\x1b\\ plain");
		assert shown(vt.linkAt(0, 0)) == "https://example.com/a?b=1";
		assert shown(vt.linkAt(3, 0)) == "https://example.com/a?b=1";
		assert shown(vt.linkAt(4, 0)) == "<none>";
		assert shown(vt.linkAt(0, 1)) == "<none>";
		assert shown(vt.linkAt(0, 40)) == "<failed>";
	});
}

test "a styled cell carries its colour, flags and underline" {
	assert withVt(20, 2, (vt: Vt): void => {
		vt.writeText("\x1b[1;4;38;2;255;0;0mA\x1b[0mb");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const red: Rgb = { r: 255, g: 0, b: 0 };
			const a = rows.value[0].cells[0];
			assert a.cp == 0x41;
			assert a.fg == red;
			assert a.flags.has(CellFlag.Bold);
			assert !a.flags.has(CellFlag.Italic);
			assert a.underline == Underline.Single;
			const b = rows.value[0].cells[1];
			assert b.cp == 0x62;
			assert b.fg != red;
			assert b.flags.isEmpty();
			assert b.underline == Underline.None;
		}
	});
}

test "an erased line keeps its background on cells without text" {
	assert withVt(10, 2, (vt: Vt): void => {
		vt.writeText("\x1b[48;2;0;0;255m\x1b[K");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const blue: Rgb = { r: 0, g: 0, b: 255 };
			const cell = rows.value[0].cells[5];
			assert cell.cp == 0;
			assert cell.bg == blue;
		}
	});
}

test "a cluster of forty codepoints is one cell that keeps them all" {
	assert withVt(10, 2, (vt: Vt): void => {
		let cluster = "a";
		for (let i = 0; i < 39; i++) { cluster += String.fromCharCode(0x301); }
		vt.writeText(cluster + "b");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const row = rows.value[0];
			assert row.cells[0].cp == 0x61;
			assert row.cells[0].extra == 39;
			assert row.cells[1].cp == 0x62;
			const text = row.text();
			assert text.ok;
			if (text.ok) { assert text.value.startsWith(cluster + "b"); }
		}
	});
}

test "a character above the basic plane reads back whole" {
	assert withVt(10, 2, (vt: Vt): void => {
		vt.writeText("x😀");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			assert rows.value[0].cells[1].cp == 0x1F600;
			const text = rows.value[0].text();
			assert text.ok;
			if (text.ok) { assert text.value.startsWith("x😀"); }
		}
	});
}

test "an underline carries the SGR 58 colour, resolved from the palette when it is an index" {
	assert withVt(10, 2, (vt: Vt): void => {
		vt.writeText("\x1b[4:3m\x1b[58;2;255;80;80ma\x1b[58;5;1mb\x1b[59mc\x1b[24;58;2;1;2;3md");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const cells = rows.value[0].cells;
			const salmon: Rgb = { r: 255, g: 80, b: 80 };
			assert cells[0].underlineColor == salmon;
			const indexed = cells[1].underlineColor;
			assert indexed !== null;
			if (indexed !== null) {
				assert indexed.r > indexed.g && indexed.r > indexed.b && indexed.r != 255;
			}
			assert cells[2].underline == Underline.Curly;
			assert cells[2].underlineColor === null;
			assert cells[3].underline == Underline.None;
			assert cells[3].underlineColor === null;
		}
	});
}

test "a wide character is flagged and its spacer holds no text" {
	assert withVt(10, 2, (vt: Vt): void => {
		vt.writeText("中a");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const cells = rows.value[0].cells;
			assert cells[0].cp == 0x4E2D;
			assert cells[0].flags.has(CellFlag.Wide);
			assert cells[1].cp == 0;
			assert cells[2].cp == 0x61;
			assert !cells[2].flags.has(CellFlag.Wide);
		}
	});
}

test "a combining mark joins its base cell" {
	assert withVt(10, 2, (vt: Vt): void => {
		vt.writeText("éx");
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const row = rows.value[0];
			assert row.cells[0].cp == 0x65;
			assert row.cells[0].extra == 1;
			assert row.extra.length == 1;
			assert row.extra[0] == 0x301;
			assert row.cells[1].cp == 0x78;
		}
	});
}

test "a skin-tone emoji is one wide cell, also after a full reset" {
	assert withVt(10, 2, (vt: Vt): void => {
		for (const prefix of ["", "\x1bc"]) {
			vt.writeText(`${prefix}\u{1F44D}\u{1F3FD}x`);
			assert vt.update().ok;
			const rows = vt.rows();
			assert rows.ok;
			if (rows.ok) {
				const row = rows.value[0];
				assert row.cells[0].cp == 0x1F44D;
				assert row.cells[0].flags.has(CellFlag.Wide);
				assert row.cells[0].extra == 1 && row.extra[0] == 0x1F3FD;
				assert row.cells[2].cp == 0x78;
			}
		}
	});
}

function clusterAt(this vt: Vt, base: uint32): Vec<uint32> {
	let found: Vec<uint32> = [];
	if (!vt.update().ok) { return found; }
	const rows = vt.rows();
	if (!rows.ok) { return found; }
	for (const row of rows.value) {
		let extraAt = 0;
		for (const cell of row.cells) {
			if (cell.cp == base && cell.flags.has(CellFlag.Wide)) {
				found.push(base);
				for (let k = 0; k < (cell.extra as int32); k++) { found.push(row.extra[extraAt + k]); }
				return found;
			}
			extraAt += cell.extra as int32;
		}
	}
	return found;
}

test "a cluster that widens in the last column wraps with its codepoints, below a scroll region too" {
	const heart = "\u{2764}\u{200D}\u{1F44D}";
	const kssa = "\u{915}\u{94D}\u{937}";
	for (const at of ["\x1b[2;4r\x1b[6;20H", "\x1b[6;20H", "\x1b[2;4r\x1b[4;20H"]) {
		assert withVt(20, 6, (vt: Vt): void => {
			vt.writeText(at + heart);
			const cluster = vt.clusterAt(0x2764);
			assert cluster.length == 3 && cluster[1] == 0x200D && cluster[2] == 0x1F44D;
		});
		assert withVt(20, 6, (vt: Vt): void => {
			vt.writeText(at + kssa);
			const cluster = vt.clusterAt(0x915);
			assert cluster.length == 3 && cluster[1] == 0x94D && cluster[2] == 0x937;
		});
	}
}

test "a line's text keeps each cell's combining marks with that cell" {
	assert withVt(10, 2, (vt: Vt): void => {
		vt.writeText("éậx");
		assert vt.update().ok;
		const lines = vt.lines();
		assert lines.ok;
		if (lines.ok) { assert lines.value[0] == "éậx"; }
	});
}

test "a grapheme longer than the inline buffer arrives whole" {
	assert withVt(10, 2, (vt: Vt): void => {
		vt.writeText(`e${"\u0301".repeat(20)}x`);
		assert vt.update().ok;
		const rows = vt.rows();
		assert rows.ok;
		if (rows.ok) {
			const row = rows.value[0];
			assert row.cells[0].cp == 0x65;
			assert row.cells[0].extra == 20;
			assert row.extra.length == 20;
			assert row.extra[19] == 0x301;
			assert row.cells[1].cp == 0x78;
		}
	});
}

test "only rows written since the last clean are dirty" {
	assert withVt(10, 4, (vt: Vt): void => {
		vt.writeText("a\nb");
		assert vt.update().ok;
		vt.clean();
		vt.writeText("c");
		assert vt.update().ok;
		const dirty = vt.dirtyRows();
		assert dirty.ok;
		if (dirty.ok) {
			assert dirty.value.length == 1;
			assert dirty.value[0].y == 1;
			assert dirty.value[0].cells[1].cp == 0x62;
		}
	});
}

test "text splits into graphemes with the cells the terminal gives each" {
	const got = graphemes("e\u0301x·中🚀").map((g: Grapheme): string => `${g.text}:${g.cells}`);
	assert got.join(" ") == "e\u0301:1 x:1 ·:1 中:2 🚀:2", got.join(" ");
}
