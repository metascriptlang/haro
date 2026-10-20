import { VoidHost } from "../../../../neon/src/platform/void/host";
import { gfxSetup, fbWidth, fbHeight, dpiScale } from "../../../../void/src/sokol/gpu";
import { setup2d } from "../../../../void/src/void2d/draw";
import { present } from "../../../../void/src/void2d/scene";

export function startGraphics(): void {
	gfxSetup();
	setup2d();
}

export function presentFrame(vh: VoidHost): void {
	const scale = dpiScale();
	vh.layout((fbWidth() as float32) / scale, (fbHeight() as float32) / scale);
	vh.scene.present();
}
