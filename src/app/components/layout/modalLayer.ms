import { NeonNode } from "../../../../../neon/src/render/node";
import { View } from "../../../../../neon/src/components/primitives";
import { StyleSheet } from "../../../../../neon/src/api/styleSheet";
import { SCRIM, SCRIM_OPACITY } from "../../theme";

export function ModalLayer(props: { children: NeonNode }): NeonNode {
	return <View style={StyleSheet.absoluteFill}>
		<View
			style={[StyleSheet.absoluteFill, { backgroundColor: SCRIM, opacity: SCRIM_OPACITY }]}
		/>
		<View style={[StyleSheet.absoluteFill, { alignItems: "center", justifyContent: "center" }]}>
			{props.children}
		</View>
	</View>;
}
