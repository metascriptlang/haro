export interface Keybind {
	keys: string;
	text?: string;
	// "close_window" and "alt" | "~alt" once JSON.stringify takes a literal union field:
	// ~/metascript/.inbox/compiler/2026-10-20-json-stringify-refuses-a-string-literal-union-field.md
	action?: string;
	mode?: string;
}

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
}

export const saigonNight = {
	background: "#16161e",
	foreground: "#a9b1d6",
	palette: [
		"#363b54", "#f7768e", "#73daca", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#787c99",
		"#363b54", "#f7768e", "#41a6b5", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#acb0d0",
	],
};
