@include("string.h");
extern function memcpy(to: Ptr<uint8>, from: Readonly<Ptr<uint8>>, size: uint64): Ptr<uint8>;

export function copyInto(to: Span<uint8>, at: int32, from: Readonly<Span<uint8>>): void {
	if (from.length == 0) { return; }
	const into: Span<uint8> = to[at..at + from.length];
	const _to = memcpy(into as Ptr<uint8>, from as Readonly<Ptr<uint8>>, from.length as uint64);
}

export function append(this to: uint8[], from: Readonly<Span<uint8>>): void {
	const at = to.length as int32;
	to.length = at + from.length;
	copyInto(to, at, from);
}

test "copyInto writes a view at an offset and append grows a Vec by a whole view" {
	let buf: Vec<uint8> = new Array(6);
	const src: uint8[] = [1, 2, 3, 4];
	copyInto(buf, 2, src[1..4]);
	assert buf.join(",") == "0,0,2,3,4,0";
	let grown: Vec<uint8> = [9];
	grown.append(src);
	grown.append([]);
	assert grown.join(",") == "9,1,2,3,4";
}
