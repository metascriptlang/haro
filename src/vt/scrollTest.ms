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

function topAfterJump(this vt: Vt, toward: PromptJump): string {
	const jumped = vt.jumpToPrompt(toward);
	if (!jumped.ok) { return "<failed>"; }
	if (!jumped.value) { return "<none>"; }
	vt.update();
	return vt.topLine();
}

test "the viewport jumps between OSC 133 prompts" {
	assert withVt(10, 3, (vt: Vt): void => {
		const prompt = "\x1b]133;A\x07";
		vt.writeText(`${prompt}p1\r\nout1\r\nout2\r\n${prompt}p2\r\nout3\r\n${prompt}p3`);
		vt.update();
		assert vt.lines().ok;
		assert vt.topAfterJump(PromptJump.Previous) == "p1";
		assert vt.topAfterJump(PromptJump.Previous) == "<none>";
		assert vt.topAfterJump(PromptJump.Next) == "p2";
	});
}

test "a screen without prompt marks has nothing to jump to" {
	assert withVt(10, 3, (vt: Vt): void => {
		vt.writeText("a\r\nb\r\nc\r\nd\r\ne");
		assert vt.topAfterJump(PromptJump.Previous) == "<none>";
		assert vt.topAfterJump(PromptJump.Next) == "<none>";
	});
}

test "the viewport scrolls by lines, pages, to the top and back to the bottom" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		defer vt.free();
		vt.writeText(numberedLines(10));
		assert vt.update().ok;
		assert vt.topLine() == "r6";
		assert (try vt.atBottom() catch false);
		vt.scrollLines(-2);
		assert vt.update().ok;
		assert vt.topLine() == "r4";
		assert !(try vt.atBottom() catch true);
		assert (try vt.scrollOffset() catch -1) == 4;
		vt.scrollLines(1);
		assert vt.update().ok;
		assert vt.topLine() == "r5";
		vt.scrollTop();
		assert vt.update().ok;
		assert vt.topLine() == "r0";
		vt.scrollLines(-5);
		assert vt.update().ok;
		assert vt.topLine() == "r0";
		assert vt.scrollPages(1).ok;
		assert vt.update().ok;
		assert vt.topLine() == "r4";
		vt.scrollBottom();
		assert vt.update().ok;
		assert vt.topLine() == "r6";
		assert (try vt.atBottom() catch false);
		vt.scrollLines(5);
		assert vt.update().ok;
		assert vt.topLine() == "r6";
	}
}

test "new output while scrolled up leaves the view where it was" {
	const created = Vt.create(10, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		defer vt.free();
		vt.writeText(numberedLines(10));
		vt.scrollLines(-3);
		assert vt.update().ok;
		assert vt.topLine() == "r3";
		vt.writeText("\r\nr10\r\nr11\r\nr12\r\nr13\r\nr14");
		assert vt.update().ok;
		assert vt.topLine() == "r3";
		assert !(try vt.atBottom() catch true);
		vt.scrollBottom();
		assert vt.update().ok;
		assert vt.topLine() == "r11";
	}
}
