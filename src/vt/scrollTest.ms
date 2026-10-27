import {
	PromptJump,
	Vt,
	atBottom,
	create,
	free,
	jumpToPrompt,
	lines,
	scrollBottom,
	scrollLines,
	scrollOffset,
	scrollPages,
	scrollTop,
	update,
	writeText,
} from "./vt";
import { numberedLines, topLine, withVt } from "./vtRig";

function topAfterJump(vt: Vt, toward: PromptJump): string {
	const jumped = vt.jumpToPrompt(toward);
	if (!jumped.ok) { return "<failed>"; }
	if (!jumped.value) { return "<none>"; }
	vt.update();
	return topLine(vt);
}

test "the viewport jumps between OSC 133 prompts" {
	assert withVt(10, 3, (vt: Vt): void => {
		const prompt = "\x1b]133;A\x07";
		vt.writeText(`${prompt}p1\r\nout1\r\nout2\r\n${prompt}p2\r\nout3\r\n${prompt}p3`);
		vt.update();
		assert vt.lines().ok;
		assert topAfterJump(vt, PromptJump.Previous) == "p1";
		assert topAfterJump(vt, PromptJump.Previous) == "<none>";
		assert topAfterJump(vt, PromptJump.Next) == "p2";
	});
}

test "a screen without prompt marks has nothing to jump to" {
	assert withVt(10, 3, (vt: Vt): void => {
		vt.writeText("a\r\nb\r\nc\r\nd\r\ne");
		assert topAfterJump(vt, PromptJump.Previous) == "<none>";
		assert topAfterJump(vt, PromptJump.Next) == "<none>";
	});
}

test "the viewport scrolls by lines, pages, to the top and back to the bottom" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText(numberedLines(10));
		assert vt.update().ok;
		assert topLine(vt) == "r6";
		assert (try vt.atBottom() catch false);
		vt.scrollLines(-2);
		assert vt.update().ok;
		assert topLine(vt) == "r4";
		assert !(try vt.atBottom() catch true);
		assert (try vt.scrollOffset() catch -1) == 4;
		vt.scrollLines(1);
		assert vt.update().ok;
		assert topLine(vt) == "r5";
		vt.scrollTop();
		assert vt.update().ok;
		assert topLine(vt) == "r0";
		vt.scrollLines(-5);
		assert vt.update().ok;
		assert topLine(vt) == "r0";
		assert vt.scrollPages(1).ok;
		assert vt.update().ok;
		assert topLine(vt) == "r4";
		vt.scrollBottom();
		assert vt.update().ok;
		assert topLine(vt) == "r6";
		assert (try vt.atBottom() catch false);
		vt.scrollLines(5);
		assert vt.update().ok;
		assert topLine(vt) == "r6";
		vt.free();
	}
}

test "new output while scrolled up leaves the view where it was" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		vt.writeText(numberedLines(10));
		vt.scrollLines(-3);
		assert vt.update().ok;
		assert topLine(vt) == "r3";
		vt.writeText("\r\nr10\r\nr11\r\nr12\r\nr13\r\nr14");
		assert vt.update().ok;
		assert topLine(vt) == "r3";
		assert !(try vt.atBottom() catch true);
		vt.scrollBottom();
		assert vt.update().ok;
		assert topLine(vt) == "r11";
		vt.free();
	}
}
