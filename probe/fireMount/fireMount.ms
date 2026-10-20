import { element } from "../../../neon/src/macros/ui/element";
import { render } from "../../../neon/src/render/host";
import { View, Pressable } from "../../../neon/src/components/primitives";
import { Show } from "../../../neon/src/macros/ui/flow";
import { createSignal } from "../../../neon/src/core/signal";
import { NeonEvent } from "../../../neon/src/render/event";
import { createVoidHostWith } from "../../../neon/src/platform/void/host";
import { Scene2D } from "../../../void/src/void2d/node";
import { create } from "../../../void/src/void2d/scene";
import { rgba } from "../../../void/src/void2d/types";
import { addFont } from "../../../void/src/void2d/font";

const font = addFont("assets/JetBrainsMonoNL-Regular.ttf");
if (!font.ok) { throw new Error("font"); }
const vh = createVoidHostWith(Scene2D.create(rgba(0.0, 0.0, 0.0, 1.0)), font.value);
const [open, setOpen] = createSignal<boolean>(false);
render(element(
	<View
		style={{ width: 400, height: 300 }}
		onPointerUp={(e: NeonEvent): void => { setOpen(true); }}
	>
		{Show({ when: open, children: element(
			<Pressable style={{ width: 50, height: 20 }} onPress={(): void => {}} />
		) })}
	</View>
), vh.host, vh.root);
vh.layout(400.0, 300.0);
vh.pointerDown(100.0, 100.0, 2);
vh.pointerUp(100.0, 100.0, 2);
console.log(`opened ${open()}`);
