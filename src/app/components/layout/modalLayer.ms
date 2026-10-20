import { NeonNode } from "../../../../../neon/src/render/node";
import { View } from "../../../../../neon/src/components/primitives";
import { SCRIM, SCRIM_OPACITY } from "../../theme";

export function ModalLayer(props: { children: NeonNode }): NeonNode {
	return <View style={{ position: "absolute", left: 0, top: 0, right: 0, bottom: 0 }}>
		<View
			style={{
				position: "absolute", left: 0, top: 0, right: 0, bottom: 0,
				backgroundColor: SCRIM, opacity: SCRIM_OPACITY,
			}}
		/>
		<View
			style={{
				position: "absolute", left: 0, top: 0, right: 0, bottom: 0,
				alignItems: "center", justifyContent: "center",
			}}>
			{props.children}
		</View>
	</View>;
}
