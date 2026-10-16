#include <stdlib.h>
#include <string.h>

#include "memShim.h"

/* Fills `mb` megabytes of the C heap with 0xAA and frees nothing: the heap-ownership probe of vtWebOverlap.ms. */
int vtClobber(int mb) {
	unsigned char* p = malloc((size_t)mb << 20);
	if (!p) return 0;
	memset(p, 0xAA, (size_t)mb << 20);
	/* the buffer escapes, so the optimiser cannot drop the allocation and the fill as dead */
	__asm__ volatile("" : : "r"(p) : "memory");
	return 1;
}
