// Native control of the emcc build of Neon's <Text>:
//   msc build probe/web/ui/nativeText.ms --output=<dir>/nativeText.exe
import { element } from "../../../../neon/src/macros/ui/element";
import { Text } from "../../../../neon/src/components/primitives";

function main(): int32 {
	const node = element(<Text style={{ fontSize: 14 }}>hello</Text>);
	console.log(`nativeText: built ${node === null ? "null" : "a node"}`);
	return 0;
}

process.exit(main());
