import { buildWorkload } from "../../bench/workloads";
import { Vt } from "../../src/vt/vt";
import { plan } from "../../src/screen/plan";

const w = buildWorkload("unicode");
if (w.ok) {
	const created = Vt.create(120, 40);
	if (created.ok) {
		const vt = created.value;
		const all = w.value.payload;
		let at = 0;
		let chunk = 0;
		while (at < all.length) {
			const end = Math.min(at + 4096, all.length) as int32;
			vt.write(all.slice(at, end));
			at = end;
			chunk++;
			const p = vt.plan();
			if (!p.ok) {
				console.log(`plan failed at chunk ${chunk}: ${p.error.toString()}`);
				break;
			}
		}
		console.log(`done ${at}`);
	}
}
