export interface Keybind {
	keys: string;
	text?: string;
	action?: "close_window";
	mode?: "alt" | "~alt";
}

export interface KeyPress {
	code: string;
	text: string;
	shift: boolean;
	ctrl: boolean;
	alt: boolean;
	super: boolean;
	repeat: boolean;
}

export interface KeyAnswer {
	handled: boolean;
	send?: string;
}

export type Anchor = int32;

export interface Prompt {
	at: Anchor;
}

export interface CommandDone {
	exitCode?: number;
	command: string;
	durationMs?: number;
	prompt?: Anchor;
	output?: Anchor;
	end: Anchor;
}

export interface Decoration {
	from: Anchor;
	to: Anchor;
	background?: string;
	foreground?: string;
}

export extern function send(text: string): void from "haro.send";
export extern function notify(title: string, body: string): void from "haro.notify";
export extern function decorate(d: Decoration): int32 from "haro.decorate";
export extern function undecorate(id: int32): void from "haro.undecorate";

export interface HaroConfig {
	fontFamily?: string[];
	fontSize?: number;
	padding?: number;
	command?: string;
	workingDirectory?: string;
	scrollback?: int32;
	foreground?: string;
	background?: string;
	palette?: string[];
	keybinds?: Keybind[];
	optionAsAlt?: "neither" | "left" | "right" | "both";
	onKey?: (e: KeyPress) => KeyAnswer;
	onPrompt?: (e: Prompt) => void;
	onCommandDone?: (e: CommandDone) => void;
}

export const saigonNight = {
	background: "#16161e",
	foreground: "#a9b1d6",
	palette: [
		"#363b54", "#f7768e", "#73daca", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#787c99",
		"#363b54", "#f7768e", "#41a6b5", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#acb0d0",
	],
};
