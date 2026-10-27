#include "wake.h"
#include "../pty/nativePty.h"

void ionWakeLoop(void);

/* msc cannot pass ionWakeLoop as a function pointer: compiler card
   2026-10-19-a-function-passed-to-a-c-function-pointer-fails-at-clang */
void appWireWake(void) {
	ptySetWake(ionWakeLoop);
}
