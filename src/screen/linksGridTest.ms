import { Vt, VtError } from "../vt/vt";
import { withVt } from "../vt/vtRig";
import { Link, linkUnder } from "./linksGrid";

function shown(r: Result<Link | null, VtError>): string {
	if (!r.ok) { return "<failed>"; }
	const link = r.value;
	if (link === null) { return "<none>"; }
	let parts: string[] = [];
	for (const s of link.stretches) { parts.push(`${s.row}:${s.from}-${s.to}`); }
	return `${link.uri} @ ${parts.join(" ")}`;
}

function at(vt: Vt, col: int32, row: int32): string {
	const _updated = vt.update();
	return shown(vt.linkUnder(col, row));
}

test "a URL written as plain text is found from any of its cells, with the cells it covers" {
	assert withVt(30, 3, (vt: Vt): void => {
		vt.writeText("see https://example.com/a. ok");
		assert vt.update().ok;
		assert at(vt, 4, 0) == "https://example.com/a @ 0:4-25";
		assert at(vt, 24, 0) == "https://example.com/a @ 0:4-25";
		assert at(vt, 25, 0) == "<none>";
		assert at(vt, 0, 0) == "<none>";
		assert at(vt, 0, 1) == "<none>";
	});
}

test "a URL that soft-wraps onto the next row is one link covering both rows" {
	assert withVt(10, 3, (vt: Vt): void => {
		vt.writeText("go https://example.com/x y");
		assert vt.update().ok;
		const both = "https://example.com/x @ 0:3-10 1:0-10 2:0-4";
		assert at(vt, 5, 0) == both;
		assert at(vt, 9, 1) == both;
		assert at(vt, 3, 2) == both;
		assert at(vt, 5, 2) == "<none>";
	});
}

test "an OSC 8 hyperlink wins over text, and covers its own cells" {
	assert withVt(30, 3, (vt: Vt): void => {
		vt.writeText("a \u001b]8;;https://e.com/h\u0007click me\u001b]8;;\u0007 b");
		assert vt.update().ok;
		assert at(vt, 3, 0) == "https://e.com/h @ 0:2-10";
		assert at(vt, 10, 0) == "<none>";
	});
}

test "a wide character before the URL moves its cells, not its text" {
	assert withVt(30, 3, (vt: Vt): void => {
		vt.writeText("中 http://a.io");
		assert vt.update().ok;
		assert at(vt, 4, 0) == "http://a.io @ 0:2-13";
	});
}
