import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const NAMED = {
	Black: "i0", Red: "i1", Green: "i2", Yellow: "i3", Blue: "i4", Magenta: "i5", Cyan: "i6", White: "i7",
	BrightBlack: "i8", BrightRed: "i9", BrightGreen: "i10", BrightYellow: "i11",
	BrightBlue: "i12", BrightMagenta: "i13", BrightCyan: "i14", BrightWhite: "i15",
	DimBlack: "i0", DimRed: "i1", DimGreen: "i2", DimYellow: "i3",
	DimBlue: "i4", DimMagenta: "i5", DimCyan: "i6", DimWhite: "i7",
	Foreground: "d", Background: "d", BrightForeground: "d", DimForeground: "d", Cursor: "d",
};

function color(c) {
	if (c.Named !== undefined) {
		const t = NAMED[c.Named];
		if (t === undefined) { throw new Error(`unmapped named colour ${c.Named}`); }
		return t;
	}
	if (c.Indexed !== undefined) { return `i${c.Indexed}`; }
	const h = (n) => n.toString(16).padStart(2, "0");
	return `#${h(c.Spec.r)}${h(c.Spec.g)}${h(c.Spec.b)}`;
}

function flagsOf(flags) {
	const has = (name) => flags.split(" | ").includes(name);
	let out = "";
	if (has("BOLD")) { out += "B"; }
	if (has("ITALIC")) { out += "I"; }
	if (has("STRIKEOUT")) { out += "S"; }
	if (has("UNDERLINE")) { out += "u"; }
	if (has("DOUBLE_UNDERLINE")) { out += "U"; }
	if (has("UNDERCURL")) { out += "c"; }
	if (has("DOTTED_UNDERLINE")) { out += "o"; }
	if (has("DASHED_UNDERLINE")) { out += "a"; }
	if (has("INVERSE")) { out += "V"; }
	if (has("DIM")) { out += "F"; }
	if (has("HIDDEN")) { out += "H"; }
	return out === "" ? "-" : out;
}

const [, , refRoot, outRoot, ...names] = process.argv;
for (const name of names) {
	const dir = join(refRoot, name);
	const grid = JSON.parse(readFileSync(join(dir, "grid.json"), "utf8"));
	const size = JSON.parse(readFileSync(join(dir, "size.json"), "utf8"));
	const out = join(outRoot, name);
	mkdirSync(out, { recursive: true });
	copyFileSync(join(dir, "alacritty.recording"), join(out, "in.bin"));
	const rows = [];
	const attrs = [];
	let astral = false;
	for (let y = 0; y < size.screen_lines; y++) {
		const row = grid.raw.inner[size.screen_lines - 1 - y].inner;
		let text = "";
		const units = [];
		for (const cell of row) {
			const flags = cell.flags.split(" | ");
			if (flags.includes("WIDE_CHAR_SPACER")) { continue; }
			const chars = [cell.c === "\t" ? " " : cell.c, ...(cell.extra ? cell.extra.zerowidth : [])].join("");
			if ([...chars].some((ch) => ch.codePointAt(0) > 0xffff)) { astral = true; }
			text += chars;
			const token = `${color(cell.fg)}:${color(cell.bg)}:${flagsOf(cell.flags)}`;
			for (let k = 0; k < chars.length; k++) { units.push(token); }
		}
		rows.push(text.trimEnd());
		const runs = [];
		for (const token of units) {
			const last = runs[runs.length - 1];
			if (last && last.token === token) { last.n += 1; } else { runs.push({ token, n: 1 }); }
		}
		attrs.push(runs.map((r) => `${r.n}:${r.token}`).join(" "));
	}
	writeFileSync(join(out, "rows.txt"), rows.join("\n") + "\n");
	writeFileSync(join(out, "attrs.txt"), attrs.join("\n") + "\n");
	writeFileSync(join(out, "size.txt"), `${size.columns} ${size.screen_lines}\n`);
	console.log(`${name} ${size.columns}x${size.screen_lines}${astral ? " astral" : ""}`);
}
