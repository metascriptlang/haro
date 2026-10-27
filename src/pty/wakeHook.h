#ifndef HARO_WAKE_HOOK_H
#define HARO_WAKE_HOOK_H

#include <stdatomic.h>

typedef void (*WakeFn)(void);

static _Atomic(WakeFn) wakeApp;
static atomic_int wakePending;

static inline void wakeInstall(WakeFn wake) {
	atomic_store(&wakeApp, wake);
	if (wake && atomic_exchange(&wakePending, 0)) wake();
}

static inline void wake(void) {
	WakeFn fn = atomic_load(&wakeApp);
	if (fn) {
		fn();
		return;
	}
	atomic_store(&wakePending, 1);
	fn = atomic_load(&wakeApp);
	if (fn && atomic_exchange(&wakePending, 0)) fn();
}

#endif
