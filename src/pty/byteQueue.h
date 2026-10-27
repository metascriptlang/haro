#ifndef HARO_BYTE_QUEUE_H
#define HARO_BYTE_QUEUE_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define READ_LIMIT (4 << 20)
#define BATCH_KEEP (4 << 20)
#define WRITE_LIMIT (16 << 20)

typedef struct {
	uint8_t* data;
	int64_t head;
	int64_t len;
	int64_t cap;
} ByteQueue;

static inline int queuePush(ByteQueue* q, const uint8_t* bytes, int64_t n, int64_t firstCap) {
	if (q->head > 0 && q->len + n > q->cap) {
		memmove(q->data, q->data + q->head, (size_t)(q->len - q->head));
		q->len -= q->head;
		q->head = 0;
	}
	if (q->len + n > q->cap) {
		int64_t cap = q->cap ? q->cap : firstCap;
		while (cap < q->len + n) cap *= 2;
		uint8_t* grown = realloc(q->data, (size_t)cap);
		if (!grown) return 0;
		q->data = grown;
		q->cap = cap;
	}
	memcpy(q->data + q->len, bytes, (size_t)n);
	q->len += n;
	return 1;
}

static inline int64_t queueTake(ByteQueue* q, uint8_t* buf, int64_t cap) {
	int64_t held = q->len - q->head;
	int64_t n = held < cap ? held : cap;
	if (n > 0) {
		memcpy(buf, q->data + q->head, (size_t)n);
		q->head += n;
		if (q->head == q->len) q->head = q->len = 0;
	}
	return n;
}

#endif
