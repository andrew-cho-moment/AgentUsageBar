#ifndef AUB_SNAPSHOT_CACHE_H
#define AUB_SNAPSHOT_CACHE_H

#include <stdbool.h>

#include "FetcherProtocol.h"

bool AUBLoadSnapshot(AUBSnapshot *snapshot);
void AUBSaveSnapshot(const AUBSnapshot *snapshot);
bool AUBSnapshotValidForCache(const AUBSnapshot *snapshot);

#endif
