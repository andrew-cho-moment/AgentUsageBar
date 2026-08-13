#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../FetcherProtocol.h"

static int failures = 0;

static void AUBExpect(const char *name, const char *fixture,
                      AUBFetcherMode mode, bool expected) {
  char *mutableFixture = strdup(fixture);
  AUBSnapshot snapshot = {0};
  bool actual = AUBParseFetcherOutput(mutableFixture, mode, &snapshot);
  free(mutableFixture);
  if (actual == expected)
    return;
  fprintf(stderr, "%s: expected %d, got %d\n", name, expected, actual);
  failures++;
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: ProtocolTests <oversized-fetcher>\n");
    return 2;
  }
  AUBExpect("usage",
            "V\t1\nP\tclaude\tsigned_out\t\nP\tcodex\tsigned_out\t\nD\t1\n",
            AUBFetcherModeUsage, true);
  AUBExpect("status",
            "V\t1\nS\tnone\tOperational\tTracks Claude\t1\n"
            "T\tid\tClaude API\toperational\t1\nD\t1\n",
            AUBFetcherModeStatus, true);
  AUBExpect("duplicate provider",
            "V\t1\nP\tclaude\tsigned_out\t\nP\tclaude\tsigned_out\t\n"
            "P\tcodex\tsigned_out\t\nD\t1\n",
            AUBFetcherModeUsage, false);
  AUBExpect("data before provider",
            "V\t1\nW\tclaude\tsession\tSession\t1\t\t1\n"
            "P\tclaude\tready\tPro\nP\tcodex\tsigned_out\t\nD\t1\n",
            AUBFetcherModeUsage, false);
  AUBExpect("record after done",
            "V\t1\nP\tclaude\tsigned_out\t\nP\tcodex\tsigned_out\t\nD\t1\n"
            "U\tclaude\tlate\n",
            AUBFetcherModeUsage, false);
  AUBExpect("invalid status enum", "V\t1\nS\tunknown\tNope\tNope\t1\nD\t1\n",
            AUBFetcherModeStatus, false);
  AUBExpect("invalid percent",
            "V\t1\nP\tclaude\tready\tPro\n"
            "W\tclaude\tsession\tSession\t101\t\t1\n"
            "P\tcodex\tsigned_out\t\nD\t1\n",
            AUBFetcherModeUsage, false);
  AUBExpect("extra field",
            "V\t1\nS\tnone\tOperational\tTracks Claude\t1\textra\nD\t1\n",
            AUBFetcherModeStatus, false);
  AUBExpect("wrong mode",
            "V\t1\nS\tnone\tOperational\tTracks Claude\t1\nD\t1\n",
            AUBFetcherModeUsage, false);

  AUBSnapshot snapshot = {0};
  if (AUBRunFetcher(argv[1], AUBFetcherModeUsage, &snapshot)) {
    fprintf(stderr, "oversized helper output was accepted\n");
    failures++;
  }

  if (failures != 0)
    return 1;
  printf("10 protocol tests passed\n");
  return 0;
}
