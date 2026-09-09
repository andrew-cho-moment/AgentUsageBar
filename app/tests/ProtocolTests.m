#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../FetcherProtocol.h"

static int failures = 0;
static int checks = 0;

static void AUBExpect(const char *name, const char *fixture,
                      AUBFetcherMode mode, bool expected) {
  checks++;
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

  const char *both = "V\t1\nP\tclaude\tsigned_out\t\nP\tcodex\tsigned_out\t\n"
                     "S\tnone\tOperational\tTracks Claude\t1\n"
                     "T\tid\tClaude API\toperational\t1\nD\t1\n";
  AUBExpect("all", both, AUBFetcherModeAll, true);
  // A status outage must not discard the usage half that came back fine.
  AUBExpect("all tolerates missing status",
            "V\t1\nP\tclaude\tsigned_out\t\nP\tcodex\tsigned_out\t\nD\t1\n",
            AUBFetcherModeAll, true);
  // Status alone, though, has nothing left to deliver.
  AUBExpect("status requires status", "V\t1\nD\t1\n", AUBFetcherModeStatus,
            false);
  AUBExpect("all missing usage",
            "V\t1\nS\tnone\tOperational\tTracks Claude\t1\nD\t1\n",
            AUBFetcherModeAll, false);
  AUBExpect("usage rejects combined output", both, AUBFetcherModeUsage, false);
  AUBExpect("status rejects combined output", both, AUBFetcherModeStatus,
            false);
  AUBExpect("not installed",
            "V\t1\nP\tclaude\tnot_installed\t\n"
            "P\tcodex\tnot_installed\t\nD\t1\n",
            AUBFetcherModeUsage, true);
  // A provider with no installation reports no meters, so a window record
  // against one is a fetcher that contradicted itself.
  AUBExpect("window against a not-installed provider",
            "V\t1\nP\tclaude\tnot_installed\t\n"
            "W\tclaude\tsession\tSession\t1\t\t1\n"
            "P\tcodex\tsigned_out\t\nD\t1\n",
            AUBFetcherModeUsage, false);
  AUBExpect("folder record",
            "V\t1\nP\tclaude\tready\tPro\nH\tclaude\t/x\tsetting\n"
            "P\tcodex\tnot_installed\t\nH\tcodex\t/y\tstandard\n"
            "D\t1\n",
            AUBFetcherModeUsage, true);
  AUBExpect("folder record with an unknown source",
            "V\t1\nP\tclaude\tready\tPro\nH\tclaude\t/x\tguessed\n"
            "P\tcodex\tsigned_out\t\nD\t1\n",
            AUBFetcherModeUsage, false);
  // A folder record before its provider would attach to a state nothing has
  // set.
  AUBExpect("folder record before its provider",
            "V\t1\nH\tclaude\t/x\tsetting\nP\tclaude\tready\tPro\n"
            "P\tcodex\tsigned_out\t\nD\t1\n",
            AUBFetcherModeUsage, false);
  AUBExpect("duplicate folder record",
            "V\t1\nP\tclaude\tready\tPro\nH\tclaude\t/x\tsetting\n"
            "H\tclaude\t/z\tsetting\nP\tcodex\tsigned_out\t\nD\t1\n",
            AUBFetcherModeUsage, false);
  AUBExpect("folder record with no path",
            "V\t1\nP\tclaude\tready\tPro\nH\tclaude\t\tsetting\n"
            "P\tcodex\tsigned_out\t\nD\t1\n",
            AUBFetcherModeUsage, false);
  AUBExpect("all rejects a lone provider",
            "V\t1\nP\tclaude\tsigned_out\t\n"
            "S\tnone\tOperational\tTracks Claude\t1\nD\t1\n",
            AUBFetcherModeAll, false);

  // A provider reports one U record per API field it did not recognize, so the
  // count is set by the response rather than by this app. Overflowing the fixed
  // buffer has to cost the overflowing text, never the refresh that carried it.
  {
    char fixture[4096];
    size_t offset = (size_t)snprintf(fixture, sizeof(fixture),
                                     "V\t1\nP\tclaude\tready\tPro\n");
    for (int index = 0; index < 24; index++) {
      offset +=
          (size_t)snprintf(fixture + offset, sizeof(fixture) - offset,
                           "U\tclaude\tunrecognized field number %d\n", index);
    }
    snprintf(fixture + offset, sizeof(fixture) - offset,
             "P\tcodex\tsigned_out\t\nD\t1\n");

    AUBSnapshot overflowed = {0};
    checks++;
    if (!AUBParseFetcherOutput(fixture, AUBFetcherModeUsage, &overflowed)) {
      fprintf(stderr, "overflowing unrecognized text rejected the refresh\n");
      failures++;
    } else {
      checks++;
      const char *text = overflowed.claude.unrecognized;
      size_t length = strlen(text);
      if (length >= AUBUnrecognizedCapacity) {
        fprintf(stderr, "unrecognized buffer overran: %zu bytes\n", length);
        failures++;
      }
      checks++;
      if (length < 5 || strcmp(text + length - 5, ", ...") != 0) {
        fprintf(stderr, "truncation was not marked: %s\n", text);
        failures++;
      }
      checks++;
      if (overflowed.claude.windowCount != 0 ||
          overflowed.claude.status != AUBProviderStatusReady) {
        fprintf(stderr, "provider state lost alongside the truncation\n");
        failures++;
      }
    }
  }

  AUBSnapshot snapshot = {0};
  if (AUBRunFetcher(argv[1], AUBFetcherModeUsage, &snapshot)) {
    fprintf(stderr, "oversized helper output was accepted\n");
    failures++;
  }
  checks++;

  // The two states the UI renders numbers for, and the three it does not.
  {
    AUBProviderState provider = {0};
    const struct {
      const char *name;
      AUBProviderStatus status;
      bool visible;
      bool installed;
    } cases[] = {
        {"pending", AUBProviderStatusPending, false, true},
        {"ready", AUBProviderStatusReady, true, true},
        {"signed out", AUBProviderStatusSignedOut, false, true},
        {"failed", AUBProviderStatusFailed, true, true},
        {"not installed", AUBProviderStatusNotInstalled, false, false},
    };
    for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); index++) {
      provider.status = cases[index].status;
      checks++;
      if (AUBProviderVisible(&provider) != cases[index].visible) {
        fprintf(stderr, "%s: wrong visibility\n", cases[index].name);
        failures++;
      }
      checks++;
      if (AUBProviderInstalled(&provider) != cases[index].installed) {
        fprintf(stderr, "%s: wrong installed state\n", cases[index].name);
        failures++;
      }
    }
  }

  if (failures != 0)
    return 1;
  printf("%d protocol tests passed\n", checks);
  return 0;
}
