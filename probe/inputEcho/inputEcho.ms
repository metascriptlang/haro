import { argv } from "std/process";
import { NativePty } from "../../src/pty/pty";

const bs = String.fromCharCode(92);
const script = ["C:", "Users", "metacraft", "metascript", "terminator-wt-terminator-m1", "probe", "inputEcho", "keys.ps1"].join(bs);
const opened = NativePty.spawn(`pwsh.exe -NoLogo -NoProfile -File ${script}`, 100, 10);
if (opened.ok) {
	const p = opened.value;
	let buf: Vec<uint8> = new Array(65536);
	let out = "";
	let sent = false;
	for (let i = 0; i < 40; i++) {
		if (!p.wait(150).ok) { break; }
		const r = p.read(buf);
		if (!r.ok) { break; }
		for (let k = 0; k < r.value; k++) { const b = buf[k] as int32; out += b < 32 ? "" : String.fromCharCode(b); }
		if (!sent && i == 8) {
			let reply: Vec<uint8> = [27, 91, 63, 48, 117];
			p.write(reply);
			sent = true;
		}
	}
	const at = out.indexOf("keys=");
	console.log(at < 0 ? `no keys line: ${out.slice(0, 200)}` : out.slice(at));
	p.close();
}
