#include <stdio.h>
#include <string.h>

#include "../FetcherProtocol.h"

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: FetcherProtocolHarness <fetcher> <usage|status>\n");
    return 2;
  }

  AUBFetcherMode mode;
  if (strcmp(argv[2], "usage") == 0) {
    mode = AUBFetcherModeUsage;
  } else if (strcmp(argv[2], "status") == 0) {
    mode = AUBFetcherModeStatus;
  } else {
    return 2;
  }

  AUBSnapshot snapshot = {0};
  if (!AUBRunFetcher(argv[1], mode, &snapshot)) {
    fprintf(stderr, "fetch or protocol parse failed\n");
    return 1;
  }

  printf("valid=%d claude=%u/%u codex=%u/%u status=%d/%u\n", snapshot.valid,
         snapshot.claude.status, snapshot.claude.windowCount,
         snapshot.codex.status, snapshot.codex.windowCount, snapshot.hasStatus,
         snapshot.statusComponentCount);
  return 0;
}
