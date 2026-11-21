#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

/* zig cc -target wasm32-wasi -O2 -mexec-model=reactor hybrid.c
 * -Wl,--export=add -Wl,--export=open_path -Wl,--export=spin -o hybrid.wasm */
double add(double left, double right) { return left + right; }

int open_path(const char *path, int writable) {
  int fd = open(path, writable ? O_WRONLY | O_CREAT | O_TRUNC : O_RDONLY, 0600);
  if (fd < 0) return -errno;
  close(fd);
  return 0;
}

int spin(int count) {
  volatile int value = 0;
  for (int index = 0; index < count; index++) value = index;
  return value;
}
