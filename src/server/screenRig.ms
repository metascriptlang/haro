import { Vt, create, free, lines, restore, update, write } from "../vt/vt";
import { ScreenFormat } from "./protocol";

export function screenText(
	format: ScreenFormat,
	bytes: Readonly<Span<uint8>>,
	cols: int32,
	rows: int32,
	after: string = "",
): string {
	const made = format == ScreenFormat.Native ? Vt.restore(bytes) : Vt.create(cols, rows);
	if (!made.ok) { return "<no vt>"; }
	const vt = made.value;
	defer vt.free();
	if (format == ScreenFormat.VtBytes) { vt.write(bytes); }
	vt.write(after.asBytes());
	if (!vt.update().ok) { return "<no update>"; }
	const shown = vt.lines();
	return shown.ok ? shown.value.join("\n") : "<no lines>";
}
