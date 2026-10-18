import { argv } from "std/process";
import { NativePty } from "../../src/pty/pty";
import { Vt, CellFlag, Underline, palette } from "../../src/vt/vt";
import { line } from "../../src/grid/lines";
import { spansOf } from "../../src/app/frame";
import { Style } from "../../../neon/src/render/style";

const command = argv[1];
const opened = NativePty.spawn(command, 105, 30);
if (opened.ok) {
	const p = opened.value;
	let buf: Vec<uint8> = new Array(65536);
	let raw: Vec<uint8> = [];
	let shown = "";
	let replied = argv.length < 3;
	for (let i = 0; i < 40; i++) {
		if (!p.wait(250).ok) { break; }
		const r = p.read(buf);
		if (!r.ok) { break; }
		if (!replied && shown.includes("[?u")) {
			let reply: Vec<uint8> = [27, 91, 63, 48, 117];
			p.write(reply);
			replied = true;
			shown += `
[${Math.round(performance.now())}ms REPLIED] `;
		}
		if (r.value > 0) { shown += `
[${Math.round(performance.now())}ms ${r.value}B] `; }
		for (let k = 0; k < r.value; k++) {
			raw.push(buf[k]);
			const b = buf[k] as int32;
			shown += b < 32 ? `<${b}>` : b < 128 ? String.fromCharCode(b) : "~";
		}
	}
	p.close();
	console.log(shown);
	const created = Vt.create(105, 30);
	if (created.ok) {
		const vt = created.value;
		vt.write(raw);
		vt.update();
		const rows = vt.rows();
		if (rows.ok) {
			for (const row of rows.value) {
				let attrs = "";
				for (const c of row.cells) {
					attrs += c.underline != Underline.None ? "u" : c.flags.has(CellFlag.Bold) ? "B" : c.flags.has(CellFlag.Italic) ? "I" : c.cp == 0 ? " " : ".";
				}
				console.log(`row ${row.y}: ${attrs.trimEnd()}`);
			}
		}
		const pal = vt.palette();
		const rows2 = vt.rows();
		if (pal.ok && rows2.ok) {
			const styles = new Map<string, Style>();
			for (let y = 0; y < 3; y++) {
				const l = rows2.value[y].line(-1);
				if (l.ok) {
					for (const sp of spansOf(styles, l.value, pal.value.bg)) {
						const st = sp.style;
						console.log(`  y${y} [${sp.text.trimEnd()}] w=${st.fontWeight} deco=${st.textDecorationLine} ds=${st.textDecorationStyle}`);
					}
				}
			}
		}
		const look = vt.cursorLook();
		if (look.ok) { console.log(`cursor visible=${look.value.visible}`); }
	}
}
