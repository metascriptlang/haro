#ifndef HARO_SPAWN_H
#define HARO_SPAWN_H

int haroSpawnSocket(const char *joined, const char *errPath, int *fd);
int haroReap(int pid, int *code);
int haroShutdownWrite(int fd);

#endif
