#include "FetcherProtocol.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static AUBProviderState *AUBProvider(AUBSnapshot *snapshot, const char *name) {
  if (strcmp(name, "claude") == 0)
    return &snapshot->claude;
  if (strcmp(name, "codex") == 0)
    return &snapshot->codex;
  return NULL;
}

static bool AUBDouble(const char *text, double *value) {
  if (text[0] == '\0')
    return false;
  char *end = NULL;
  errno = 0;
  double parsed = strtod(text, &end);
  if (errno != 0 || end == text || *end != '\0' || !isfinite(parsed))
    return false;
  *value = parsed;
  return true;
}

static bool AUBInteger(const char *text, int64_t *value) {
  if (text[0] == '\0')
    return false;
  char *end = NULL;
  errno = 0;
  long long parsed = strtoll(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0')
    return false;
  *value = parsed;
  return true;
}

static bool AUBCopy(char *destination, size_t capacity, const char *source) {
  size_t length = strlen(source);
  if (length >= capacity)
    return false;
  memcpy(destination, source, length + 1);
  return true;
}

static bool AUBAppend(char *destination, size_t capacity, const char *source) {
  size_t used = strlen(destination);
  size_t separator = used == 0 ? 0 : 2;
  size_t added = strlen(source);
  if (used + separator + added >= capacity)
    return false;
  if (separator != 0)
    memcpy(destination + used, ", ", separator);
  memcpy(destination + used + separator, source, added + 1);
  return true;
}

/// Overwrites the tail of a full buffer with an ellipsis, so a truncated diagnostics
/// list is visibly truncated. `capacity` counts the NUL.
static void AUBMarkTruncated(char *destination, size_t capacity) {
  static const char marker[] = ", ...";
  const size_t markerLength = sizeof(marker) - 1;
  if (capacity <= markerLength)
    return;
  size_t used = strlen(destination);
  size_t start = used + markerLength < capacity ? used : capacity - 1 - markerLength;
  memcpy(destination + start, marker, markerLength + 1);
}

static size_t AUBFields(char *line, char **fields, size_t capacity) {
  size_t count = 0;
  char *cursor = line;
  while (count < capacity) {
    fields[count++] = strsep(&cursor, "\t");
    if (cursor == NULL)
      break;
  }
  return cursor == NULL ? count : capacity + 1;
}

static bool AUBBool(const char *text, bool *value) {
  if (strcmp(text, "0") == 0) {
    *value = false;
  } else if (strcmp(text, "1") == 0) {
    *value = true;
  } else {
    return false;
  }
  return true;
}

static bool AUBScope(const char *text, AUBBudgetScope *scope) {
  if (text[0] == '\0') {
    *scope = AUBBudgetScopeNone;
  } else if (strcmp(text, "organization") == 0) {
    *scope = AUBBudgetScopeOrganization;
  } else if (strcmp(text, "seat_tier") == 0) {
    *scope = AUBBudgetScopeSeatTier;
  } else if (strcmp(text, "account") == 0) {
    *scope = AUBBudgetScopeAccount;
  } else if (strcmp(text, "group") == 0) {
    *scope = AUBBudgetScopeGroup;
  } else if (strcmp(text, "org_service") == 0) {
    *scope = AUBBudgetScopeOrganizationService;
  } else {
    return false;
  }
  return true;
}

static bool AUBState(const char *text, AUBBudgetReading *budget) {
  if (strcmp(text, "active") == 0) {
    budget->state = AUBBudgetStateActive;
  } else if (strcmp(text, "limit_reached") == 0) {
    budget->state = AUBBudgetStateLimitReached;
  } else if (strcmp(text, "out_of_credits") == 0) {
    budget->state = AUBBudgetStateOutOfCredits;
  } else if (strncmp(text, "disabled:", 9) == 0) {
    budget->state = AUBBudgetStateDisabled;
    if (!AUBCopy(budget->disabledReason, sizeof(budget->disabledReason),
                 text + 9)) {
      return false;
    }
  } else {
    return false;
  }
  return true;
}

static bool AUBParseBudget(char **fields, size_t count,
                           AUBProviderState *provider) {
  if (count != 10)
    return false;
  AUBBudgetReading budget = {.present = true};

  if (fields[2][0] != '\0') {
    if (!AUBInteger(fields[2], &budget.spentMinor) || budget.spentMinor < 0)
      return false;
    budget.hasSpent = true;
  }
  if (fields[3][0] != '\0') {
    if (!AUBInteger(fields[3], &budget.limitMinor) || budget.limitMinor < 0)
      return false;
    budget.hasLimit = true;
  }

  if (strcmp(fields[4], "currency") == 0) {
    if (fields[5][0] == '\0')
      return false;
    budget.unit = AUBBudgetUnitCurrency;
    if (!AUBCopy(budget.currency, sizeof(budget.currency), fields[5]))
      return false;
  } else if (strcmp(fields[4], "credits") == 0) {
    budget.unit = AUBBudgetUnitCredits;
  } else {
    return false;
  }

  int64_t exponent = 0;
  if (!AUBInteger(fields[6], &exponent) || exponent < 0 || exponent > 9)
    return false;
  budget.exponent = (uint8_t)exponent;
  if (!AUBScope(fields[7], &budget.scope) || !AUBState(fields[8], &budget))
    return false;
  if (fields[9][0] != '\0') {
    if (!AUBDouble(fields[9], &budget.resetsAt) || budget.resetsAt <= 0)
      return false;
    budget.hasReset = true;
  }

  provider->budget = budget;
  return true;
}

bool AUBParseFetcherOutput(char *text, AUBFetcherMode mode,
                           AUBSnapshot *result) {
  if (text == NULL || result == NULL)
    return false;
  AUBSnapshot parsed = {0};
  bool hasVersion = false;
  bool hasClaude = false;
  bool hasCodex = false;
  bool hasDone = false;
  char *lines = text;
  char *line = NULL;

  while ((line = strsep(&lines, "\n")) != NULL) {
    if (line[0] == '\0')
      continue;
    if (hasDone)
      return false;
    char *fields[10] = {0};
    size_t count = AUBFields(line, fields, 10);

    if (strcmp(fields[0], "V") == 0) {
      if (count != 2 || strcmp(fields[1], "1") != 0 || hasVersion)
        return false;
      hasVersion = true;
      continue;
    }
    if (!hasVersion)
      return false;

    if (strcmp(fields[0], "P") == 0) {
      if (count != 4)
        return false;
      AUBProviderState *provider = AUBProvider(&parsed, fields[1]);
      if (provider == NULL)
        return false;
      if (provider == &parsed.claude) {
        if (hasClaude)
          return false;
        hasClaude = true;
      } else {
        if (hasCodex)
          return false;
        hasCodex = true;
      }
      if (strcmp(fields[2], "ready") == 0) {
        provider->status = AUBProviderStatusReady;
        if (!AUBCopy(provider->plan, sizeof(provider->plan), fields[3]))
          return false;
      } else if (strcmp(fields[2], "signed_out") == 0) {
        provider->status = AUBProviderStatusSignedOut;
      } else if (strcmp(fields[2], "failed") == 0) {
        provider->status = AUBProviderStatusFailed;
        if (!AUBCopy(provider->error, sizeof(provider->error), fields[3]))
          return false;
      } else {
        return false;
      }
      continue;
    }

    if (strcmp(fields[0], "W") == 0) {
      if (count != 7)
        return false;
      AUBProviderState *provider = AUBProvider(&parsed, fields[1]);
      if (provider == NULL || provider->status != AUBProviderStatusReady ||
          provider->windowCount >= AUBMaxWindows) {
        return false;
      }
      if (fields[2][0] == '\0' || fields[3][0] == '\0')
        return false;
      for (uint8_t index = 0; index < provider->windowCount; index++) {
        if (strcmp(provider->windows[index].id, fields[2]) == 0)
          return false;
      }
      AUBWindow *window = &provider->windows[provider->windowCount];
      if (!AUBDouble(fields[4], &window->percent) || window->percent < 0 ||
          window->percent > 100) {
        return false;
      }
      if (!AUBCopy(window->id, sizeof(window->id), fields[2]) ||
          !AUBCopy(window->label, sizeof(window->label), fields[3])) {
        return false;
      }
      if (fields[5][0] != '\0') {
        if (!AUBDouble(fields[5], &window->resetsAt) || window->resetsAt <= 0) {
          return false;
        }
        window->hasReset = true;
      }
      if (!AUBBool(fields[6], &window->active))
        return false;
      provider->windowCount++;
      continue;
    }

    if (strcmp(fields[0], "B") == 0) {
      AUBProviderState *provider =
          count > 1 ? AUBProvider(&parsed, fields[1]) : NULL;
      if (provider == NULL || provider->status != AUBProviderStatusReady ||
          provider->budget.present ||
          !AUBParseBudget(fields, count, provider)) {
        return false;
      }
      continue;
    }

    if (strcmp(fields[0], "C") == 0) {
      if (count != 4)
        return false;
      AUBProviderState *provider = AUBProvider(&parsed, fields[1]);
      int64_t balance = 0;
      int64_t exponent = 0;
      if (provider == NULL || provider->status != AUBProviderStatusReady ||
          provider->hasCreditBalance || !AUBInteger(fields[2], &balance) ||
          balance < 0 || !AUBInteger(fields[3], &exponent) || exponent < 0 ||
          exponent > 9) {
        return false;
      }
      provider->hasCreditBalance = true;
      provider->creditBalanceMinor = balance;
      provider->creditExponent = (uint8_t)exponent;
      continue;
    }

    if (strcmp(fields[0], "U") == 0) {
      if (count != 3)
        return false;
      AUBProviderState *provider = AUBProvider(&parsed, fields[1]);
      if (provider == NULL || provider->status != AUBProviderStatusReady)
        return false;
      // These strings are diagnostics about the response, so a full buffer must not
      // discard an otherwise valid refresh. Mark the truncation instead, or the panel
      // would read as a complete list of what the API changed.
      if (!AUBAppend(provider->unrecognized, sizeof(provider->unrecognized),
                     fields[2])) {
        AUBMarkTruncated(provider->unrecognized,
                         sizeof(provider->unrecognized));
      }
      continue;
    }

    if (strcmp(fields[0], "S") == 0) {
      if (count != 5 || parsed.hasStatus)
        return false;
      if (strcmp(fields[1], "none") == 0) {
        parsed.statusIndicator = AUBStatusIndicatorNone;
      } else if (strcmp(fields[1], "minor") == 0) {
        parsed.statusIndicator = AUBStatusIndicatorMinor;
      } else if (strcmp(fields[1], "major") == 0) {
        parsed.statusIndicator = AUBStatusIndicatorMajor;
      } else if (strcmp(fields[1], "critical") == 0) {
        parsed.statusIndicator = AUBStatusIndicatorCritical;
      } else {
        return false;
      }
      if (!AUBCopy(parsed.statusDescription, sizeof(parsed.statusDescription),
                   fields[2]) ||
          !AUBCopy(parsed.statusContext, sizeof(parsed.statusContext),
                   fields[3])) {
        return false;
      }
      if (!AUBDouble(fields[4], &parsed.statusFetchedAt) ||
          parsed.statusFetchedAt <= 0) {
        return false;
      }
      parsed.hasStatus = true;
      continue;
    }

    if (strcmp(fields[0], "T") == 0) {
      if (count != 5 || !parsed.hasStatus ||
          parsed.statusComponentCount >= AUBMaxStatusComponents) {
        return false;
      }
      for (uint8_t index = 0; index < parsed.statusComponentCount; index++) {
        if (strcmp(parsed.statusComponents[index].id, fields[1]) == 0)
          return false;
      }
      AUBStatusComponent *component =
          &parsed.statusComponents[parsed.statusComponentCount];
      if (fields[1][0] == '\0' || fields[2][0] == '\0')
        return false;
      if (!AUBCopy(component->id, sizeof(component->id), fields[1]) ||
          !AUBCopy(component->name, sizeof(component->name), fields[2])) {
        return false;
      }
      if (strcmp(fields[3], "operational") == 0) {
        component->status = AUBComponentStatusOperational;
      } else if (strcmp(fields[3], "under_maintenance") == 0) {
        component->status = AUBComponentStatusUnderMaintenance;
      } else if (strcmp(fields[3], "degraded_performance") == 0) {
        component->status = AUBComponentStatusDegradedPerformance;
      } else if (strcmp(fields[3], "partial_outage") == 0) {
        component->status = AUBComponentStatusPartialOutage;
      } else if (strcmp(fields[3], "major_outage") == 0) {
        component->status = AUBComponentStatusMajorOutage;
      } else {
        return false;
      }
      if (!AUBBool(fields[4], &component->tracked))
        return false;
      parsed.statusComponentCount++;
      continue;
    }

    if (strcmp(fields[0], "D") == 0) {
      if (count != 2 || hasDone || !AUBDouble(fields[1], &parsed.fetchedAt) ||
          parsed.fetchedAt <= 0) {
        return false;
      }
      parsed.valid = true;
      hasDone = true;
      continue;
    }
    return false;
  }

  if (!hasVersion || !hasDone)
    return false;
  // Usage is all-or-nothing: one provider without the other is a truncated run.
  if (AUBFetcherModeWantsUsage(mode) != (hasClaude && hasCodex) ||
      hasClaude != hasCodex) {
    return false;
  }
  // A half that was never asked for means the wrong helper ran.
  if (parsed.hasStatus && !AUBFetcherModeWantsStatus(mode))
    return false;
  // Status is required when it is the only thing requested, but optional
  // alongside usage: status.claude.com being unreachable must not throw away a
  // good usage fetch. Callers test `hasStatus` before merging, and the poll
  // retries either way.
  if (!parsed.hasStatus && AUBFetcherModeWantsStatus(mode) &&
      !AUBFetcherModeWantsUsage(mode)) {
    return false;
  }
  *result = parsed;
  return true;
}

bool AUBRunFetcher(const char *path, AUBFetcherMode mode, AUBSnapshot *result) {
  if (path == NULL || result == NULL || mode > AUBFetcherModeAll)
    return false;
  enum { outputCapacity = 128 * 1024 };
  char *output = mmap(NULL, outputCapacity, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANON, -1, 0);
  if (output == MAP_FAILED)
    return false;

  int descriptors[2];
  if (pipe(descriptors) != 0) {
    munmap(output, outputCapacity);
    return false;
  }
  if (fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) != 0 ||
      fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) != 0) {
    close(descriptors[0]);
    close(descriptors[1]);
    munmap(output, outputCapacity);
    return false;
  }

  posix_spawn_file_actions_t actions = NULL;
  int actionStatus = posix_spawn_file_actions_init(&actions);
  if (actionStatus == 0) {
    actionStatus = posix_spawn_file_actions_adddup2(&actions, descriptors[1],
                                                    STDOUT_FILENO);
  }
  if (actionStatus == 0) {
    actionStatus = posix_spawn_file_actions_addclose(&actions, descriptors[0]);
  }
  if (actionStatus == 0) {
    actionStatus = posix_spawn_file_actions_addclose(&actions, descriptors[1]);
  }
  if (actionStatus != 0) {
    if (actions != NULL)
      posix_spawn_file_actions_destroy(&actions);
    close(descriptors[0]);
    close(descriptors[1]);
    munmap(output, outputCapacity);
    return false;
  }

  pid_t process = 0;
  char *arguments[3] = {(char *)path, NULL, NULL};
  if (AUBFetcherModeWantsStatus(mode)) {
    arguments[1] = AUBFetcherModeWantsUsage(mode) ? "--all" : "--status-only";
  }
  int spawnStatus =
      posix_spawn(&process, path, &actions, NULL, arguments, environ);
  posix_spawn_file_actions_destroy(&actions);
  close(descriptors[1]);

  bool success = false;
  if (spawnStatus == 0) {
    size_t used = 0;
    bool overflow = false;
    bool readFailed = false;
    char discarded[4096];
    for (;;) {
      char *destination = used + 1 < outputCapacity ? output + used : discarded;
      size_t capacity = used + 1 < outputCapacity ? outputCapacity - used - 1
                                                  : sizeof(discarded);
      ssize_t count = read(descriptors[0], destination, capacity);
      if (count > 0) {
        if (destination == output + used) {
          used += (size_t)count;
        } else {
          overflow = true;
        }
        continue;
      }
      if (count < 0 && errno == EINTR)
        continue;
      if (count < 0)
        readFailed = true;
      break;
    }
    output[used] = '\0';

    int processStatus = 0;
    pid_t waited = 0;
    do {
      waited = waitpid(process, &processStatus, 0);
    } while (waited < 0 && errno == EINTR);
    if (!overflow && !readFailed && waited == process &&
        WIFEXITED(processStatus) && WEXITSTATUS(processStatus) == 0) {
      success = AUBParseFetcherOutput(output, mode, result);
    }
  }

  close(descriptors[0]);
  munmap(output, outputCapacity);
  return success;
}
