import { Style } from "../../../neon/src/render/style";
import { CellInk } from "../grid/lines";
import { Rgb } from "../vt/vt";

export const SELECTION: CellInk = { fg: null, bg: null };
export const CURSOR_TEXT: Rgb | null = null;

export const NOTICE_BACKGROUND = "#5c1f24";
const NOTICE_TEXT = "#ffffff";
export const NOTICE_PADDING: number = 8;
export const NOTICE_RADIUS: number = 4;

export const SCRIM = "#000000";
export const SCRIM_OPACITY: number = 0.62;

export const DIALOG_PADDING: number = 16;
export const DIALOG_GAP: number = 12;
export const DIALOG_RADIUS: number = 6;
export const DIALOG_BORDER = "#3f3f3f";
export const DIALOG_SHADOW = "0 8px 24px rgba(0, 0, 0, 0.55)";
export const DIALOG_CARD = "#1c1c1c";
export const DIALOG_WELL = "#0c0c0c";
export const DIALOG_WELL_PADDING: number = 8;

const TEXT = "#cccccc";
const WARNING = "#f9f1a5";
const DIM = "#7a7a7a";
const ON_PRIMARY = "#0c0c0c";

export const TITLE_STYLE: Style = { color: WARNING, fontWeight: "bold" };
export const BODY_STYLE: Style = { color: TEXT };
export const DIM_STYLE: Style = { color: DIM };
export const NOTICE_STYLE: Style = { color: NOTICE_TEXT };

export struct ButtonLook {
	background: string;
	heldBackground: string;
	text: Style;
}

export const PRIMARY_BUTTON: ButtonLook = {
	background: "#cccccc",
	heldBackground: "#ffffff",
	text: { color: ON_PRIMARY, fontWeight: "bold" },
};

export const SECONDARY_BUTTON: ButtonLook = {
	background: "#2d2d2d",
	heldBackground: "#454545",
	text: { color: TEXT },
};
