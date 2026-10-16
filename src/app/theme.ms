import { Rgb } from "../vt/vt";
import { hexOf } from "./frame";

export const THEME_FG: Rgb = { r: 204, g: 204, b: 204 };
export const THEME_BG: Rgb = { r: 12, g: 12, b: 12 };
export const FOREGROUND = "#cccccc";
export const BACKGROUND = "#0c0c0c";

test "the drawn colours are the ones the terminal answers a colour query with" {
	assert hexOf(THEME_FG) == FOREGROUND;
	assert hexOf(THEME_BG) == BACKGROUND;
}
