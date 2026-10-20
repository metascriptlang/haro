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
