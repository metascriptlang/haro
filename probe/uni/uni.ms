import { buildWorkload } from "../../bench/workloads";
import { Vt } from "../../src/vt/vt";
import { plan } from "../../src/screen/plan";

const workload = buildWorkload("unicode");
if (workload.ok) {
	const created = Vt.create(120, 40);
	if (created.ok) {
		const vt = created.value;
		const all = workload.value.payload;
		let at = 0;
		let chunk = 0;
		while (at < all.length) {
			const end = Math.min(at + 4096, all.length) as int32;
			vt.write(all.slice(at, end));
			at = end;
			chunk++;
			const planned = vt.plan();
			if (!planned.ok) {
				console.log(`plan failed at chunk ${chunk}: ${planned.error.toString()}`);
				break;
			}
		}
		console.log(`done ${at}`);
	}
}
