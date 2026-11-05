@include("string.h");

extern function memmove(to: Ptr<uint8>, from: Readonly<Ptr<uint8>>, size: uint64): Ptr<uint8>;

export function copyInto(to: Span<uint8>, at: int32, from: Readonly<Span<uint8>>): void {
	if (from.length == 0) { return; }
	const _to = memmove(to[at..at + from.length] as Ptr<uint8>, from as Readonly<Ptr<uint8>>, from.length as uint64);
}

export function appendBytes(this to: uint8[], from: Readonly<Span<uint8>>): void {
	const at = to.length;
	to.length = at + from.length;
	copyInto(to, at, from);
}

test "bytes copy into a window and append in bulk" {
	const head: uint8[] = [1, 2];
	const tail: Vec<uint8> = [3, 4, 5];
	head.appendBytes(tail);
	head.appendBytes(tail[1..3]);
	assert head.join(",") == "1,2,3,4,5,4,5", head.join(",");
	let into: Vec<uint8> = [0, 0, 0, 0];
	copyInto(into, 1, tail);
	assert into.join(",") == "0,3,4,5";
}
