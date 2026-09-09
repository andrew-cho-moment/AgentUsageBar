#ifndef AUB_FETCHER_PROTOCOL_H
#define AUB_FETCHER_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum {
  AUBMaxWindows = 8,
  AUBProviderNameCapacity = 64,
  AUBWindowIDCapacity = 64,
  AUBWindowLabelCapacity = 128,
  AUBErrorCapacity = 160,
  AUBUnrecognizedCapacity = 256,
  AUBMaxStatusComponents = 16,
};

/// The two meters both providers report. Must match `WindowID` in Models.swift:
/// the menu bar and the panel pick their headline rows out by these ids.
#define AUBWindowIDSession "session"
#define AUBWindowIDWeekly "weekly"

typedef enum : uint8_t {
  AUBProviderStatusPending,
  AUBProviderStatusReady,
  AUBProviderStatusSignedOut,
  AUBProviderStatusFailed,
  /// This machine has no installation of the provider's CLI, so the app has no
  /// account to report on and says nothing about it anywhere. Appended rather
  /// than sorted into the ladder because a cached snapshot stores these values
  /// raw, and inserting one would change what an existing cache means.
  AUBProviderStatusNotInstalled,
} AUBProviderStatus;

typedef enum : uint8_t {
  AUBBudgetUnitNone,
  AUBBudgetUnitCurrency,
  AUBBudgetUnitCredits,
} AUBBudgetUnit;

typedef enum : uint8_t {
  AUBBudgetScopeNone,
  AUBBudgetScopeOrganization,
  AUBBudgetScopeSeatTier,
  AUBBudgetScopeAccount,
  AUBBudgetScopeGroup,
  AUBBudgetScopeOrganizationService,
} AUBBudgetScope;

typedef enum : uint8_t {
  AUBBudgetStateActive,
  AUBBudgetStateLimitReached,
  AUBBudgetStateOutOfCredits,
  AUBBudgetStateDisabled,
} AUBBudgetState;

typedef enum : uint8_t {
  AUBStatusIndicatorNone,
  AUBStatusIndicatorMinor,
  AUBStatusIndicatorMajor,
  AUBStatusIndicatorCritical,
} AUBStatusIndicator;

typedef enum : uint8_t {
  AUBComponentStatusOperational,
  AUBComponentStatusUnderMaintenance,
  AUBComponentStatusDegradedPerformance,
  AUBComponentStatusPartialOutage,
  AUBComponentStatusMajorOutage,
} AUBComponentStatus;

typedef struct {
  char id[AUBWindowIDCapacity];
  char label[AUBWindowLabelCapacity];
  double percent;
  double resetsAt;
  bool hasReset;
  bool active;
} AUBWindow;

typedef struct {
  bool present;
  bool overridden;
  bool hasSpent;
  bool hasLimit;
  int64_t spentMinor;
  int64_t limitMinor;
  AUBBudgetUnit unit;
  char currency[8];
  uint8_t exponent;
  AUBBudgetScope scope;
  AUBBudgetState state;
  char disabledReason[AUBErrorCapacity];
  double resetsAt;
  bool hasReset;
} AUBBudgetReading;

typedef struct {
  AUBProviderStatus status;
  char plan[AUBProviderNameCapacity];
  char error[AUBErrorCapacity];
  AUBWindow windows[AUBMaxWindows];
  uint8_t windowCount;
  AUBBudgetReading budget;
  bool hasCreditBalance;
  int64_t creditBalanceMinor;
  uint8_t creditExponent;
  char unrecognized[AUBUnrecognizedCapacity];
} AUBProviderState;

typedef struct {
  char id[AUBWindowIDCapacity];
  char name[AUBWindowLabelCapacity];
  AUBComponentStatus status;
  bool tracked;
} AUBStatusComponent;

typedef struct {
  bool valid;
  double fetchedAt;
  bool hasStatus;
  AUBStatusIndicator statusIndicator;
  char statusDescription[AUBWindowLabelCapacity];
  char statusContext[AUBUnrecognizedCapacity];
  double statusFetchedAt;
  AUBStatusComponent statusComponents[AUBMaxStatusComponents];
  uint8_t statusComponentCount;
  AUBProviderState claude;
  AUBProviderState codex;
} AUBSnapshot;

/// A provider contributes numbers to the menu bar and the panel only once it
/// has been fetched at least once and is actually signed in. Stated as the two
/// states that do report, so a state added later stays silent until its own
/// rendering is written.
static inline bool AUBProviderVisible(const AUBProviderState *provider) {
  return provider->status == AUBProviderStatusReady ||
         provider->status == AUBProviderStatusFailed;
}

/// Whether the provider belongs on screen at all. A provider that is installed
/// but signed out still earns its sign-in hint and, for Claude, its service
/// status; one that was never installed earns no mention of itself. A provider
/// not yet fetched counts as installed, because the first fetch is what
/// decides.
static inline bool AUBProviderInstalled(const AUBProviderState *provider) {
  return provider->status != AUBProviderStatusNotInstalled;
}

/// Which halves of the snapshot one helper run produces. `All` exists so that
/// wanting both costs one helper process rather than two, each of which would
/// pay its own Foundation and CFNetwork load.
typedef enum : uint8_t {
  AUBFetcherModeUsage,
  AUBFetcherModeStatus,
  AUBFetcherModeAll,
} AUBFetcherMode;

static inline bool AUBFetcherModeWantsUsage(AUBFetcherMode mode) {
  return mode == AUBFetcherModeUsage || mode == AUBFetcherModeAll;
}

static inline bool AUBFetcherModeWantsStatus(AUBFetcherMode mode) {
  return mode == AUBFetcherModeStatus || mode == AUBFetcherModeAll;
}

bool AUBParseFetcherOutput(char *text, AUBFetcherMode mode,
                           AUBSnapshot *result);
bool AUBRunFetcher(const char *path, AUBFetcherMode mode, AUBSnapshot *result);

#endif
