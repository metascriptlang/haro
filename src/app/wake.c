#include "wake.h"
#include "../pty/nativePty.h"

void ionWakeLoop(void);

void appWireWake(void) {
	ptySetWake(ionWakeLoop);
}
