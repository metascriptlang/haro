import { visible } from "../input/paste";

export const NOTICE_LINES: int32 = 8;

export function noticeLines(text: string, cols: int32): string[] {
	let out: string[] = [];
	if (text == "") { return out; }
	const all = text.trimEnd().split("\n");
	for (const raw of all) {
		if (out.length == NOTICE_LINES - 1 && all.length > NOTICE_LINES) {
			out.push(`… ${all.length - out.length} more lines`);
			break;
		}
		out.push(visible(raw.trimEnd(), cols));
	}
	return out;
}

test "no notice has no lines" {
	assert noticeLines("", 40).length == 0;
}

test "each line of a notice is cut to the width, a carriage return dropped" {
	const lines = noticeLines("error: a long message here\r\n  --> config.ms:3:27\r\n", 12);
	assert lines.length == 2;
	assert lines[0] == "error: a lo…";
	assert lines[1] == "  --> confi…";
}

test "a notice past its lines ends by counting what it left out" {
	let text = "";
	for (let i = 0; i < 20; i++) { text += `line ${i}\n`; }
	const lines = noticeLines(text, 40);
	assert lines.length == NOTICE_LINES;
	assert lines[NOTICE_LINES - 2] == "line 6";
	assert lines[NOTICE_LINES - 1] == "… 13 more lines";
}
