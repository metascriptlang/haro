#include "wake.h"
#include "../pty/nativePty.h"

void ionWakeLoop(void);

/* msc cannot pass ionWakeLoop as a function pointer:
   .inbox/compiler/2026-10-19-a-function-passed-to-a-c-function-pointer-fails-at-clang.md */
void appWireWake(void) {
	ptySetWake(ionWakeLoop);
}
