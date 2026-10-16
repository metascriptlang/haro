import { readFileSync, writeFileSync } from "node:fs";

const GRAPHEME_MAX_LEN = 64;
const text = readFileSync(process.argv[2], "utf8").split("\n")[0];
let out = "";
let marks = 0;
for (const ch of text) {
	const cp = ch.codePointAt(0);
	const isMark = cp >= 0x300 && cp <= 0x36f;
	if (!isMark) { marks = 0; }
	if (!isMark || marks < GRAPHEME_MAX_LEN) { out += ch; }
	if (isMark) { marks += 1; }
}
writeFileSync(process.argv[3], out);
