import { MouseButton } from "../controller/mouseButton";
import { Hit } from "../controller/controls";
import { IoPort } from "../controller/io";
import { Shell, portOf } from "../controller/shell";
import { Action } from "../input/bindings";
import { KeyEvent } from "../keys/keys";

function flushed(shell: Shell, send: (bytes: Vec<uint8>) => void): void {
	shell.typed().then((bytes: Vec<uint8>): void => {
		if (bytes.length > 0) { send(bytes); }
	});
}

export function remotePortOf(shell: Shell, send: (bytes: Vec<uint8>) => void): IoPort {
	const local = portOf(shell);
	const flush = (): void => { flushed(shell, send); };
	return {
		...local,
		key: (k: KeyEvent, time: float64): void => {
			local.key(k, time);
			flush();
		},
		keyReleased: (k: KeyEvent): void => {
			local.keyReleased(k);
			flush();
		},
		text: (typed: string, time: float64): void => {
			local.text(typed, time);
			flush();
		},
		focus: (gained: boolean): void => {
			local.focus(gained);
			flush();
		},
		press: (button: MouseButton, h: Hit, time: float64): void => {
			local.press(button, h, time);
			flush();
		},
		move: (h: Hit, pressed: boolean): void => {
			local.move(h, pressed);
			flush();
		},
		release: (button: MouseButton, h: Hit): void => {
			local.release(button, h);
			flush();
		},
		wheel: (notches: float64, h: Hit): void => {
			local.wheel(notches, h);
			flush();
		},
		act: (action: Action): void => {
			local.act(action);
			flush();
		},
		closeKey: (): void => {
			local.closeKey();
			flush();
		},
		confirmDialog: (): void => {
			local.confirmDialog();
			flush();
		},
		cancelDialog: (): void => {
			local.cancelDialog();
			flush();
		},
		pasted: (clipboard: string): void => {
			local.pasted(clipboard);
			flush();
		},
	};
}
