#include <string.h>
#include <unistd.h>

int main(void) {
  char output[4096];
  memset(output, 'x', sizeof(output));
  for (int index = 0; index < 40; index++) {
    size_t written = 0;
    while (written < sizeof(output)) {
      ssize_t count =
          write(STDOUT_FILENO, output + written, sizeof(output) - written);
      if (count <= 0)
        return 1;
      written += (size_t)count;
    }
  }
  return 0;
}
