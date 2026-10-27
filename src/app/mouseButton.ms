export enum MouseButton {
	None = 0,
	Left = 1,
	Right = 2,
	Middle = 3,
	WheelUp = 4,
	WheelDown = 5,
}

export function buttonOf(code: number): MouseButton {
	return match (code) {
		1 => MouseButton.Left,
		2 => MouseButton.Right,
		3 => MouseButton.Middle,
		_ => MouseButton.None,
	};
}

export function holdsButton(code: int32): boolean {
	const left: int32 = MouseButton.Left as int32;
	const middle: int32 = MouseButton.Middle as int32;
	return code >= left && code <= middle;
}

test "the window's numbering maps to a button, and only the three real buttons are held" {
	assert buttonOf(1) == MouseButton.Left;
	assert buttonOf(3) == MouseButton.Middle;
	assert buttonOf(0) == MouseButton.None;
	assert buttonOf(9) == MouseButton.None;
	assert holdsButton(MouseButton.Right as int32);
	assert !holdsButton(MouseButton.WheelUp as int32);
	assert !holdsButton(MouseButton.None as int32);
}
