#include <stdio.h>
#include <string.h>

#include "../SnapshotCache.h"

static int failures = 0;

static void AUBExpect(const char *name, const AUBSnapshot *snapshot,
                      bool expected) {
  bool actual = AUBSnapshotValidForCache(snapshot);
  if (actual == expected)
    return;
  fprintf(stderr, "%s: expected %d, got %d\n", name, expected, actual);
  failures++;
}

int main(void) {
  AUBSnapshot snapshot = {
      .valid = true,
      .fetchedAt = 1,
      .claude.status = AUBProviderStatusSignedOut,
      .codex.status = AUBProviderStatusSignedOut,
  };
  AUBExpect("minimal snapshot", &snapshot, true);

  snapshot.claude.status = AUBProviderStatusPending;
  AUBExpect("pending provider", &snapshot, false);
  snapshot.claude.status = AUBProviderStatusSignedOut;

  snapshot.statusComponentCount = 1;
  AUBExpect("components without status", &snapshot, false);
  snapshot.statusComponentCount = 0;

  // A machine that will never have Codex caches that fact, so the next launch
  // renders without waiting on a fetch that can only report the same thing.
  snapshot.codex.status = AUBProviderStatusNotInstalled;
  AUBExpect("not-installed provider", &snapshot, true);

  snapshot.claude.status = AUBProviderStatusReady;
  snapshot.claude.windowCount = 1;
  strcpy(snapshot.claude.windows[0].id, "session");
  strcpy(snapshot.claude.windows[0].label, "Session");
  snapshot.claude.windows[0].percent = 101;
  AUBExpect("invalid percentage", &snapshot, false);
  snapshot.claude.windows[0].percent = 50;
  AUBExpect("usage window", &snapshot, true);

  if (failures != 0)
    return 1;
  printf("6 cache validation tests passed\n");
  return 0;
}
