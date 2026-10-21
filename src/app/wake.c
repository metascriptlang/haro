#include "wake.h"
#include "../pty/nativePty.h"

void ionWakeLoop(void);

/* msc cannot pass ionWakeLoop as a function pointer:
   .inbox/compiler/2026-10-16-function-into-c-function-pointer-emits-msclosure.md */
void appWireWake(void) {
	ptySetWake(ionWakeLoop);
}
