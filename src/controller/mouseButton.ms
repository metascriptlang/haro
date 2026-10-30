import { MouseButton } from "../vt/vt";
export { MouseButton } from "../vt/vt";

export function buttonOf(code: int32): MouseButton {
	return match (code) {
		1 => MouseButton.Left,
		2 => MouseButton.Right,
		3 => MouseButton.Middle,
		_ => MouseButton.None,
	};
}

export function holdsButton(button: MouseButton): boolean {
	return button == MouseButton.Left || button == MouseButton.Right || button == MouseButton.Middle;
}

test "the window's numbering maps to a button, and only the three real buttons are held" {
	assert buttonOf(1) == MouseButton.Left;
	assert buttonOf(3) == MouseButton.Middle;
	assert buttonOf(0) == MouseButton.None;
	assert buttonOf(9) == MouseButton.None;
	assert holdsButton(MouseButton.Right);
	assert !holdsButton(MouseButton.WheelUp);
	assert !holdsButton(MouseButton.None);
}
