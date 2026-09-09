#include "SnapshotCache.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum {
  AUBSnapshotCacheMagic = 0x41554243,
  AUBSnapshotCacheVersion = 1,
};

typedef struct {
  uint32_t magic;
  uint16_t version;
  uint16_t reserved;
  uint32_t snapshotSize;
  uint32_t alignmentPadding;
} AUBSnapshotCacheHeader;

static bool AUBTerminated(const char *text, size_t capacity) {
  return memchr(text, '\0', capacity) != NULL;
}

static bool AUBBudgetValid(const AUBBudgetReading *budget) {
  if (!budget->present)
    return true;
  if (budget->unit != AUBBudgetUnitCurrency &&
      budget->unit != AUBBudgetUnitCredits) {
    return false;
  }
  if (budget->scope > AUBBudgetScopeOrganizationService ||
      budget->state > AUBBudgetStateDisabled || budget->exponent > 9 ||
      !AUBTerminated(budget->currency, sizeof(budget->currency)) ||
      !AUBTerminated(budget->disabledReason, sizeof(budget->disabledReason))) {
    return false;
  }
  if ((budget->hasSpent && budget->spentMinor < 0) ||
      (budget->hasLimit && budget->limitMinor < 0) ||
      (budget->overridden && (!budget->hasLimit || budget->limitMinor <= 0)) ||
      (budget->hasReset &&
       (!isfinite(budget->resetsAt) || budget->resetsAt <= 0))) {
    return false;
  }
  return true;
}

static bool AUBProviderValid(const AUBProviderState *provider) {
  if (provider->status == AUBProviderStatusPending ||
      provider->status > AUBProviderStatusNotInstalled ||
      provider->windowCount > AUBMaxWindows ||
      !AUBTerminated(provider->plan, sizeof(provider->plan)) ||
      !AUBTerminated(provider->error, sizeof(provider->error)) ||
      !AUBTerminated(provider->unrecognized, sizeof(provider->unrecognized)) ||
      !AUBBudgetValid(&provider->budget)) {
    return false;
  }
  for (uint8_t index = 0; index < provider->windowCount; index++) {
    const AUBWindow *window = &provider->windows[index];
    if (!AUBTerminated(window->id, sizeof(window->id)) ||
        window->id[0] == '\0' ||
        !AUBTerminated(window->label, sizeof(window->label)) ||
        window->label[0] == '\0' || !isfinite(window->percent) ||
        window->percent < 0 || window->percent > 100 ||
        (window->hasReset &&
         (!isfinite(window->resetsAt) || window->resetsAt <= 0))) {
      return false;
    }
  }
  return true;
}

bool AUBSnapshotValidForCache(const AUBSnapshot *snapshot) {
  if (snapshot == NULL)
    return false;
  if (!snapshot->valid || !isfinite(snapshot->fetchedAt) ||
      snapshot->fetchedAt <= 0 || !AUBProviderValid(&snapshot->claude) ||
      !AUBProviderValid(&snapshot->codex)) {
    return false;
  }
  if (!snapshot->hasStatus)
    return snapshot->statusComponentCount == 0;
  if (snapshot->statusIndicator > AUBStatusIndicatorCritical ||
      snapshot->statusComponentCount > AUBMaxStatusComponents ||
      !isfinite(snapshot->statusFetchedAt) || snapshot->statusFetchedAt <= 0 ||
      !AUBTerminated(snapshot->statusDescription,
                     sizeof(snapshot->statusDescription)) ||
      !AUBTerminated(snapshot->statusContext,
                     sizeof(snapshot->statusContext))) {
    return false;
  }
  for (uint8_t index = 0; index < snapshot->statusComponentCount; index++) {
    const AUBStatusComponent *component = &snapshot->statusComponents[index];
    if (component->status > AUBComponentStatusMajorOutage ||
        !AUBTerminated(component->id, sizeof(component->id)) ||
        component->id[0] == '\0' ||
        !AUBTerminated(component->name, sizeof(component->name)) ||
        component->name[0] == '\0') {
      return false;
    }
  }
  return true;
}

static uint64_t AUBChecksum(const AUBSnapshot *snapshot) {
  const uint8_t *bytes = (const uint8_t *)snapshot;
  uint64_t value = UINT64_C(14695981039346656037);
  for (size_t index = 0; index < sizeof(*snapshot); index++) {
    value ^= bytes[index];
    value *= UINT64_C(1099511628211);
  }
  return value;
}

static bool AUBCachePath(char *path, size_t capacity) {
  size_t length = confstr(_CS_DARWIN_USER_CACHE_DIR, path, capacity);
  if (length == 0 || length > capacity)
    return false;
  const char *name = "com.andrewcho.agentusagebar.snapshot-v1";
  size_t used = strlen(path);
  size_t added = strlen(name);
  if (used + added >= capacity)
    return false;
  memcpy(path + used, name, added + 1);
  return true;
}

static bool AUBReadExact(int descriptor, void *buffer, size_t length) {
  uint8_t *bytes = buffer;
  size_t used = 0;
  while (used < length) {
    ssize_t count = read(descriptor, bytes + used, length - used);
    if (count > 0) {
      used += (size_t)count;
      continue;
    }
    if (count < 0 && errno == EINTR)
      continue;
    return false;
  }
  return true;
}

static bool AUBAtEnd(int descriptor) {
  char extra;
  ssize_t count;
  do {
    count = read(descriptor, &extra, 1);
  } while (count < 0 && errno == EINTR);
  return count == 0;
}

static bool AUBWriteAll(int descriptor, const void *buffer, size_t length) {
  const uint8_t *bytes = buffer;
  size_t written = 0;
  while (written < length) {
    ssize_t count = write(descriptor, bytes + written, length - written);
    if (count > 0) {
      written += (size_t)count;
      continue;
    }
    if (count < 0 && errno == EINTR)
      continue;
    return false;
  }
  return true;
}

bool AUBLoadSnapshot(AUBSnapshot *snapshot) {
  if (snapshot == NULL)
    return false;
  char path[1024];
  if (!AUBCachePath(path, sizeof(path)))
    return false;
  int descriptor = open(path, O_RDONLY | O_CLOEXEC);
  if (descriptor < 0)
    return false;
  AUBSnapshotCacheHeader header = {0};
  uint64_t checksum = 0;
  bool read = AUBReadExact(descriptor, &header, sizeof(header)) &&
              AUBReadExact(descriptor, snapshot, sizeof(*snapshot)) &&
              AUBReadExact(descriptor, &checksum, sizeof(checksum)) &&
              AUBAtEnd(descriptor);
  close(descriptor);
  if (!read || header.magic != AUBSnapshotCacheMagic ||
      header.version != AUBSnapshotCacheVersion || header.reserved != 0 ||
      header.snapshotSize != sizeof(*snapshot) ||
      header.alignmentPadding != 0 || checksum != AUBChecksum(snapshot) ||
      !AUBSnapshotValidForCache(snapshot)) {
    memset(snapshot, 0, sizeof(*snapshot));
    return false;
  }
  return true;
}

void AUBSaveSnapshot(const AUBSnapshot *snapshot) {
  if (!AUBSnapshotValidForCache(snapshot))
    return;
  char path[1024];
  if (!AUBCachePath(path, sizeof(path)))
    return;
  char temporaryPath[1060];
  int length =
      snprintf(temporaryPath, sizeof(temporaryPath), "%s.XXXXXX", path);
  if (length < 0 || (size_t)length >= sizeof(temporaryPath))
    return;

  AUBSnapshotCacheHeader header = {
      .magic = AUBSnapshotCacheMagic,
      .version = AUBSnapshotCacheVersion,
      .snapshotSize = sizeof(*snapshot),
  };
  uint64_t checksum = AUBChecksum(snapshot);
  int descriptor = mkstemp(temporaryPath);
  if (descriptor < 0)
    return;
  bool written = AUBWriteAll(descriptor, &header, sizeof(header)) &&
                 AUBWriteAll(descriptor, snapshot, sizeof(*snapshot)) &&
                 AUBWriteAll(descriptor, &checksum, sizeof(checksum));
  if (close(descriptor) != 0)
    written = false;
  if (!written || rename(temporaryPath, path) != 0)
    unlink(temporaryPath);
}
