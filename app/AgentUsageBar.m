#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <malloc/malloc.h>

#include <dlfcn.h>
#import <string.h>

#import "FetcherProtocol.h"
#import "SnapshotCache.h"
#import "UsagePanelView.h"

typedef NS_ENUM(NSInteger, AUBAppServiceStatus) {
  AUBAppServiceStatusNotRegistered,
  AUBAppServiceStatusEnabled,
  AUBAppServiceStatusRequiresApproval,
  AUBAppServiceStatusNotFound,
};

@protocol AUBAppService <NSObject>
@property(readonly) AUBAppServiceStatus status;
- (BOOL)registerAndReturnError:(NSError **)error;
- (BOOL)unregisterAndReturnError:(NSError **)error;
@end

@protocol AUBAppServiceClass <NSObject>
+ (id<AUBAppService>)mainAppService;
@end

/// `SMAppService.mainAppService` resolves through the main bundle, so this has
/// to run in the app itself: from a bare helper in `Contents/Helpers` the main
/// bundle is that directory and the status comes back `NotFound`. The framework
/// loads only when the setting changes, which is first launch and explicit
/// toggles, never a normal launch.
static bool AUBSetLoginItem(bool enabled) {
  void *framework =
      dlopen("/System/Library/Frameworks/ServiceManagement.framework/"
             "ServiceManagement",
             RTLD_LAZY | RTLD_LOCAL);
  if (framework == NULL)
    return false;
  Class serviceClass = NSClassFromString(@"SMAppService");
  if (serviceClass == Nil) {
    dlclose(framework);
    return false;
  }
  id<AUBAppService> service =
      [(id<AUBAppServiceClass>)serviceClass mainAppService];
  AUBAppServiceStatus status = service.status;
  NSError *error = nil;
  bool succeeded;
  if (enabled) {
    succeeded = status == AUBAppServiceStatusEnabled ||
                status == AUBAppServiceStatusRequiresApproval ||
                [service registerAndReturnError:&error];
  } else {
    succeeded = status == AUBAppServiceStatusNotRegistered ||
                [service unregisterAndReturnError:&error];
  }
  service = nil;
  dlclose(framework);
  return succeeded;
}

static const AUBWindow *AUBHeadlineWindow(const AUBProviderState *provider,
                                          const char *identifier) {
  for (uint8_t index = 0; index < provider->windowCount; index++) {
    if (strcmp(provider->windows[index].id, identifier) == 0) {
      return &provider->windows[index];
    }
  }
  return NULL;
}

static bool AUBAppendText(char *destination, size_t capacity,
                          const char *text) {
  size_t used = strlen(destination);
  size_t added = strlen(text);
  if (used + added >= capacity)
    return false;
  memcpy(destination + used, text, added + 1);
  return true;
}

static bool AUBAppendProviderHeadline(char *title, size_t capacity,
                                      const AUBProviderState *provider,
                                      const char *mark) {
  if (!AUBProviderVisible(provider))
    return true;

  char group[96] = {0};
  int count = snprintf(group, sizeof(group), "%s ", mark);
  if (count < 0 || (size_t)count >= sizeof(group))
    return false;
  if (provider->status == AUBProviderStatusFailed) {
    if (!AUBAppendText(group, sizeof(group), "?"))
      return false;
  } else {
    const AUBWindow *session = AUBHeadlineWindow(provider, AUBWindowIDSession);
    const AUBWindow *weekly = AUBHeadlineWindow(provider, AUBWindowIDWeekly);
    if (session == NULL && weekly == NULL) {
      if (!AUBAppendText(group, sizeof(group), "…"))
        return false;
    } else {
      char percentages[64] = {0};
      if (session != NULL) {
        count = snprintf(percentages, sizeof(percentages), "%.0f%%",
                         session->percent);
        if (count < 0 || (size_t)count >= sizeof(percentages))
          return false;
      }
      if (weekly != NULL) {
        char weeklyText[32] = {0};
        count = snprintf(weeklyText, sizeof(weeklyText), "%s%.0f%%",
                         session == NULL ? "" : "/", weekly->percent);
        if (count < 0 || (size_t)count >= sizeof(weeklyText) ||
            !AUBAppendText(percentages, sizeof(percentages), weeklyText)) {
          return false;
        }
      }
      if (!AUBAppendText(group, sizeof(group), percentages))
        return false;
    }
  }

  if (title[0] != '\0' && !AUBAppendText(title, capacity, "   "))
    return false;
  return AUBAppendText(title, capacity, group);
}

/// Idle poll cadence. Both providers meter rolling multi-hour windows, so the
/// number moves only while an agent runs; the leeway lets the kernel fold this
/// wake into one it was already making rather than scheduling its own.
static const double AUBPollInterval = 300;
static const uint64_t AUBPollLeeway = 60 * NSEC_PER_SEC;
/// A meter drops to zero the instant its window rolls over, so poll just past
/// the boundary instead of showing the spent percentage for another interval.
static const double AUBResetSlack = 5;
/// How stale the panel tolerates on open, where the user is waiting on the
/// number rather than glancing at the menu bar.
static const double AUBPanelFreshness = 60;

/// Pulls a poll deadline back to just past a reset that lands before it, so a
/// rolled-over meter reads zero rather than its spent percentage.
static double AUBPullToReset(double deadline, double now, bool hasReset,
                             double resetsAt) {
  double due = resetsAt + AUBResetSlack;
  return hasReset && due > now && due < deadline ? due : deadline;
}

static double AUBNow(void) {
  return CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970;
}

@interface AUBPanel : NSPanel
@end

@implementation AUBPanel
- (BOOL)canBecomeKeyWindow {
  return YES;
}
@end

@interface AUBAppDelegate
    : NSObject <NSApplicationDelegate, AUBUsagePanelViewDelegate> {
  NSStatusItem *_statusItem;
  AUBPanel *_panel;
  AUBUsagePanelView *_usagePanelView;
  id _panelObserver;
  id _globalEventMonitor;
  id _localEventMonitor;
  AUBSnapshot _snapshot;
  EventHandlerRef _hotKeyHandler;
  EventHotKeyRef _hotKey;
  CFAbsoluteTime _lastPanelClose;
  dispatch_source_t _pollTimer;
  double _usageAttemptedAt;
  double _statusAttemptedAt;
  double _pollUsageAt;
  bool _usageRefreshing;
  bool _statusRefreshing;
  bool _statusRefreshPending;
  bool _openAtLogin;
  bool _shortcutEnabled;
  bool _shortcutConflict;
  bool _terminating;
  AUBAppearanceMode _appearanceMode;
  uint32_t _statusRevision;
}
- (void)togglePanel;
- (void)refresh;
- (void)refreshStatus;
- (void)applyAppearance;
- (void)applyBudgetOverrides;
@end

static OSStatus AUBHandleHotKey(EventHandlerCallRef nextHandler, EventRef event,
                                void *userData) {
  (void)nextHandler;
  (void)event;
  AUBAppDelegate *delegate = (__bridge AUBAppDelegate *)userData;
  [delegate togglePanel];
  return noErr;
}

@implementation AUBAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  bool registerLoginItem = [defaults objectForKey:@"open_at_login"] == nil;
  _openAtLogin = !registerLoginItem && [defaults boolForKey:@"open_at_login"];
  _shortcutEnabled = [defaults objectForKey:@"shortcut_enabled"] == nil
                         ? true
                         : [defaults boolForKey:@"shortcut_enabled"];
  NSString *appearance = [defaults stringForKey:@"appearance_mode"];
  if (appearance == nil || [appearance isEqualToString:@"system"]) {
    _appearanceMode = AUBAppearanceModeSystem;
  } else if ([appearance isEqualToString:@"dark"]) {
    _appearanceMode = AUBAppearanceModeDark;
  } else if ([appearance isEqualToString:@"light"]) {
    _appearanceMode = AUBAppearanceModeLight;
  } else {
    [defaults removeObjectForKey:@"appearance_mode"];
    _appearanceMode = AUBAppearanceModeSystem;
  }
  [self applyAppearance];
  _statusItem = [NSStatusBar.systemStatusBar
      statusItemWithLength:NSVariableStatusItemLength];
  _statusItem.autosaveName = @"AgentUsageBar";
  _statusItem.button.title = @"…";
  _statusItem.button.toolTip = @"Checking Claude and Codex…";
  _statusItem.button.target = self;
  _statusItem.button.action = @selector(statusItemClicked:);
  [_statusItem.button
      sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
  if (_shortcutEnabled)
    [self registerHotKey];
  if (AUBLoadSnapshot(&_snapshot)) {
    // An hours-old cache is due for a poll immediately, a seconds-old one is
    // not.
    _usageAttemptedAt = _snapshot.fetchedAt;
    _statusAttemptedAt = _snapshot.statusFetchedAt;
    [self render];
  } else {
    [self refresh];
  }
  [self schedulePoll];

  // First launch only. Registering with launchd is a synchronous XPC
  // round-trip, so it runs after the status item exists and off the main
  // thread. The outcome is recorded either way: writing the key only on success
  // is what made a failed registration pay the dlopen and the round-trip again
  // on every later launch.
  if (registerLoginItem) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      bool enabled = AUBSetLoginItem(true);
      dispatch_async(dispatch_get_main_queue(), ^{
        self->_openAtLogin = enabled;
        [NSUserDefaults.standardUserDefaults setBool:enabled
                                              forKey:@"open_at_login"];
        [self->_usagePanelView reload];
      });
    });
  }
}

- (void)applyAppearance {
  switch (_appearanceMode) {
  case AUBAppearanceModeSystem:
    NSApp.appearance = nil;
    break;
  case AUBAppearanceModeDark:
    NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    break;
  case AUBAppearanceModeLight:
    NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    break;
  }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  (void)notification;
  _terminating = true;
  if (_pollTimer != nil) {
    dispatch_source_cancel(_pollTimer);
    _pollTimer = nil;
  }
  if (_hotKey != NULL)
    UnregisterEventHotKey(_hotKey);
  if (_hotKeyHandler != NULL)
    RemoveEventHandler(_hotKeyHandler);
}

- (void)registerHotKey {
  if (_hotKeyHandler == NULL) {
    EventTypeSpec type = {
        .eventClass = kEventClassKeyboard,
        .eventKind = kEventHotKeyPressed,
    };
    if (InstallEventHandler(GetApplicationEventTarget(), AUBHandleHotKey, 1,
                            &type, (__bridge void *)self,
                            &_hotKeyHandler) != noErr) {
      _shortcutConflict = true;
      return;
    }
  }
  if (_hotKey != NULL)
    return;
  EventHotKeyID identifier = {.signature = 0x41554252, .id = 1};
  OSStatus status = RegisterEventHotKey(
      kVK_ANSI_U, cmdKey, identifier, GetApplicationEventTarget(), 0, &_hotKey);
  _shortcutConflict = status != noErr;
}

- (void)refresh {
  [self refreshUsage:true status:true];
}

- (void)refreshStatus {
  [self refreshUsage:false status:true];
}

/// Arms the next poll, one shot, so a fetch in flight can never be joined by a
/// second one. An outstanding fetch owns the next arming: `merge:` runs it
/// whatever the fetch returned, which is also what stops this from re-arming a
/// deadline the fetch has not yet moved and spinning on it.
///
/// The deadline is wall clock and the timer is not strict: it never wakes a
/// sleeping machine, after a sleep long enough to pass the deadline the poll
/// runs on wake instead of drifting by the length of the sleep, and the kernel
/// is free to fold the wake into one it was already making.
- (void)schedulePoll {
  if (_usageRefreshing || _statusRefreshing)
    return;
  if (_pollTimer == nil) {
    _pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                        dispatch_get_main_queue());
    __weak AUBAppDelegate *weakSelf = self;
    dispatch_source_set_event_handler(_pollTimer, ^{
      [weakSelf poll];
    });
    dispatch_resume(_pollTimer);
  }

  double now = AUBNow();
  _pollUsageAt = _usageAttemptedAt + AUBPollInterval;
  for (AUBProviderKind kind = AUBProviderKindClaude;
       kind <= AUBProviderKindCodex; kind++) {
    const AUBProviderState *provider = [self stateForKind:kind];
    for (uint8_t index = 0; index < provider->windowCount; index++) {
      const AUBWindow *window = &provider->windows[index];
      _pollUsageAt = AUBPullToReset(_pollUsageAt, now, window->hasReset,
                                    window->resetsAt);
    }
    _pollUsageAt = AUBPullToReset(_pollUsageAt, now, provider->budget.hasReset,
                                  provider->budget.resetsAt);
  }
  double deadline = MIN(_pollUsageAt, _statusAttemptedAt + AUBPollInterval);
  dispatch_source_set_timer(
      _pollTimer,
      dispatch_walltime(NULL, (int64_t)((deadline - now) * NSEC_PER_SEC)),
      DISPATCH_TIME_FOREVER, AUBPollLeeway);
}

- (void)poll {
  // A half within the leeway of its own deadline rides along with the one that
  // is due. Letting the two clocks drift apart would buy a second helper
  // process, which costs more than fetching one half slightly early.
  double horizon = AUBNow() + (double)(AUBPollLeeway / NSEC_PER_SEC);
  bool wantsUsage = horizon >= _pollUsageAt;
  bool wantsStatus = horizon >= _statusAttemptedAt + AUBPollInterval;
  if (wantsUsage || wantsStatus)
    [self refreshUsage:wantsUsage status:wantsStatus];
  [self schedulePoll];
}

/// Fetches the requested halves in a single helper run. Each half costs a full
/// dyld load of Foundation and CFNetwork in the helper, so asking one process
/// for both is worth more than any saving inside the app.
- (void)refreshUsage:(bool)wantsUsage status:(bool)wantsStatus {
  if (wantsUsage && _usageRefreshing)
    wantsUsage = false;
  if (wantsStatus && _statusRefreshing) {
    _statusRefreshPending = true;
    wantsStatus = false;
  }
  if (!wantsUsage && !wantsStatus)
    return;
  _usageRefreshing = _usageRefreshing || wantsUsage;
  _statusRefreshing = _statusRefreshing || wantsStatus;
  // The poll cadence counts from the attempt, not the result: a provider that
  // is down would otherwise leave the deadline in the past and retry in a loop.
  double now = AUBNow();
  if (wantsUsage)
    _usageAttemptedAt = now;
  if (wantsStatus)
    _statusAttemptedAt = now;

  AUBFetcherMode mode =
      wantsUsage ? (wantsStatus ? AUBFetcherModeAll : AUBFetcherModeUsage)
                 : AUBFetcherModeStatus;

  uint32_t revision = _statusRevision;
  NSString *helper = [NSBundle.mainBundle.bundlePath
      stringByAppendingPathComponent:@"Contents/Helpers/AgentUsageFetcher"];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
      AUBSnapshot snapshot = {0};
      bool succeeded =
          AUBRunFetcher(helper.fileSystemRepresentation, mode, &snapshot);
      dispatch_async(dispatch_get_main_queue(), ^{
        [self merge:&snapshot mode:mode succeeded:succeeded revision:revision];
      });
    }
  });
}

- (void)merge:(const AUBSnapshot *)fetched
         mode:(AUBFetcherMode)mode
    succeeded:(bool)succeeded
     revision:(uint32_t)revision {
  bool wantedUsage = AUBFetcherModeWantsUsage(mode);
  bool wantedStatus = AUBFetcherModeWantsStatus(mode);
  if (wantedUsage)
    _usageRefreshing = false;
  if (wantedStatus)
    _statusRefreshing = false;

  bool merged = false;
  if (succeeded && wantedUsage) {
    _snapshot.valid = fetched->valid;
    _snapshot.fetchedAt = fetched->fetchedAt;
    _snapshot.claude = fetched->claude;
    _snapshot.codex = fetched->codex;
    [self applyBudgetOverrides];
    [self render];
    merged = true;
  }
  // A tracking change while this fetch was in flight makes its status half
  // stale.
  if (succeeded && wantedStatus && fetched->hasStatus &&
      revision == _statusRevision) {
    _snapshot.hasStatus = true;
    _snapshot.statusIndicator = fetched->statusIndicator;
    _snapshot.statusFetchedAt = fetched->statusFetchedAt;
    memcpy(_snapshot.statusDescription, fetched->statusDescription,
           sizeof(_snapshot.statusDescription));
    memcpy(_snapshot.statusContext, fetched->statusContext,
           sizeof(_snapshot.statusContext));
    memcpy(_snapshot.statusComponents, fetched->statusComponents,
           sizeof(_snapshot.statusComponents));
    _snapshot.statusComponentCount = fetched->statusComponentCount;
    merged = true;
  }

  if (merged) {
    AUBSaveSnapshot(&_snapshot);
    [_usagePanelView reload];
    [self updatePanelSize];
  } else if (!succeeded && wantedUsage) {
    _statusItem.button.title = @"!";
    _statusItem.button.toolTip = @"Usage refresh failed";
  }

  if (wantedStatus && _statusRefreshPending) {
    _statusRefreshPending = false;
    [self refreshUsage:false status:true];
  }
  [self schedulePoll];
}

static NSString *AUBBudgetOverrideKey(AUBProviderKind kind) {
  return kind == AUBProviderKindClaude ? @"budget_override_minor_claude"
                                       : @"budget_override_minor_codex";
}

- (AUBProviderState *)stateForKind:(AUBProviderKind)kind {
  return kind == AUBProviderKindClaude ? &_snapshot.claude : &_snapshot.codex;
}

- (void)applyBudgetOverrides {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  for (AUBProviderKind kind = AUBProviderKindClaude;
       kind <= AUBProviderKindCodex; kind++) {
    AUBProviderState *provider = [self stateForKind:kind];
    if (!provider->budget.present)
      continue;
    NSString *key = AUBBudgetOverrideKey(kind);
    id value = [defaults objectForKey:key];
    if (value == nil)
      continue;
    // Drop the stored override once it is unusable — either malformed, or made
    // redundant by the provider reporting its own limit. Keeping it would let a
    // months-old number reappear unannounced the next time the provider stops
    // reporting one.
    if (![value isKindOfClass:NSNumber.class] || [value longLongValue] <= 0 ||
        provider->budget.hasLimit) {
      [defaults removeObjectForKey:key];
      continue;
    }
    provider->budget.limitMinor = [value longLongValue];
    provider->budget.hasLimit = true;
    provider->budget.overridden = true;
  }
}

- (void)render {
  char title[256] = {0};
  bool rendered =
      AUBAppendProviderHeadline(title, sizeof(title), &_snapshot.claude, "✳") &&
      AUBAppendProviderHeadline(title, sizeof(title), &_snapshot.codex, ">_");
  NSString *value = rendered && title[0] != '\0'
                        ? [NSString stringWithUTF8String:title]
                        : @"—";
  _statusItem.button.title = value ?: @"—";
  _statusItem.button.toolTip = @"AgentUsageBar";
}

- (void)statusItemClicked:(id)sender {
  (void)sender;
  if (NSApp.currentEvent.type == NSEventTypeRightMouseUp) {
    [self showContextMenu];
  } else {
    [self togglePanel];
  }
}

- (void)togglePanel {
  if (_panel.visible) {
    [self closePanel];
    return;
  }
  if (CFAbsoluteTimeGetCurrent() - _lastPanelClose < 0.2)
    return;

  NSStatusBarButton *button = _statusItem.button;
  if (button == nil)
    return;
  _usagePanelView = [[AUBUsagePanelView alloc] initWithSnapshot:&_snapshot
                                                       delegate:self];
  _panel = [[AUBPanel alloc] initWithContentRect:NSMakeRect(0, 0, 360, 260)
                                       styleMask:NSWindowStyleMaskBorderless
                                         backing:NSBackingStoreBuffered
                                           defer:YES];
  _panel.opaque = NO;
  _panel.backgroundColor = NSColor.clearColor;
  _panel.hasShadow = YES;
  _panel.level = NSStatusWindowLevel;
  _panel.hidesOnDeactivate = NO;
  _panel.contentView = _usagePanelView;
  [self updatePanelSize];
  NSRect buttonFrame = [button.window convertRectToScreen:button.frame];
  NSRect panelFrame = _panel.frame;
  panelFrame.origin.x = NSMidX(buttonFrame) - panelFrame.size.width / 2;
  panelFrame.origin.y = NSMinY(buttonFrame) - panelFrame.size.height;
  [_panel setFrame:panelFrame display:NO];
  [_panel makeKeyAndOrderFront:nil];

  __weak AUBAppDelegate *weakSelf = self;
  [_panel setReleasedWhenClosed:NO];
  _panelObserver = [NSNotificationCenter.defaultCenter
      addObserverForName:NSWindowDidResignKeyNotification
                  object:_panel
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification *notification) {
                (void)notification;
                [weakSelf closePanel];
              }];
  _globalEventMonitor =
      [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown |
                                                     NSEventMaskRightMouseDown
                                             handler:^(NSEvent *event) {
                                               (void)event;
                                               [weakSelf closePanel];
                                             }];
  _localEventMonitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown |
                                           NSEventMaskRightMouseDown |
                                           NSEventMaskKeyDown
                                   handler:^NSEvent *(NSEvent *event) {
                                     AUBAppDelegate *delegate = weakSelf;
                                     if (delegate == nil)
                                       return event;
                                     if (event.type == NSEventTypeKeyDown &&
                                         event.keyCode == kVK_Escape) {
                                       [delegate closePanel];
                                       return nil;
                                     }
                                     if ((event.type ==
                                              NSEventTypeLeftMouseDown ||
                                          event.type ==
                                              NSEventTypeRightMouseDown) &&
                                         event.window != delegate->_panel) {
                                       [delegate closePanel];
                                     }
                                     return event;
                                   }];

  double now = AUBNow();
  bool usageStale =
      !_snapshot.valid || now - _snapshot.fetchedAt > AUBPanelFreshness;
  bool statusStale = !_snapshot.hasStatus ||
                     now - _snapshot.statusFetchedAt > AUBPanelFreshness;
  if (usageStale || statusStale)
    [self refreshUsage:usageStale status:statusStale];
}

- (void)updatePanelSize {
  if (_usagePanelView == nil || _panel == nil)
    return;
  CGFloat available = 600;
  NSStatusBarButton *button = _statusItem.button;
  NSScreen *screen = button.window.screen ?: NSScreen.mainScreen;
  if (screen != nil) {
    available = MIN(available, MAX(200, screen.visibleFrame.size.height - 16));
  }
  CGFloat height = MIN(available, MAX(120, _usagePanelView.contentHeight));
  _usagePanelView.frame = NSMakeRect(0, 0, 360, height);
  NSRect frame = _panel.frame;
  CGFloat top = NSMaxY(frame);
  frame.size = NSMakeSize(360, height);
  frame.origin.y = top - height;
  [_panel setFrame:frame display:_panel.visible];
}

- (void)closePanel {
  if (_panel == nil)
    return;
  _lastPanelClose = CFAbsoluteTimeGetCurrent();
  if (_panelObserver != nil) {
    [NSNotificationCenter.defaultCenter removeObserver:_panelObserver];
    _panelObserver = nil;
  }
  if (_globalEventMonitor != nil) {
    [NSEvent removeMonitor:_globalEventMonitor];
    _globalEventMonitor = nil;
  }
  if (_localEventMonitor != nil) {
    [NSEvent removeMonitor:_localEventMonitor];
    _localEventMonitor = nil;
  }
  [_panel orderOut:nil];
  _panel.contentView = nil;
  _usagePanelView = nil;
  _panel = nil;
  if (!_terminating)
    malloc_zone_pressure_relief(NULL, 0);
}

- (void)showContextMenu {
  NSMenu *menu = [NSMenu new];
  NSMenuItem *show = [[NSMenuItem alloc] initWithTitle:@"Show Usage (⌘U)"
                                                action:@selector(togglePanel)
                                         keyEquivalent:@"u"];
  show.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  show.target = self;
  [menu addItem:show];
  [menu addItem:NSMenuItem.separatorItem];

  NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:@"Refresh"
                                                   action:@selector(refresh)
                                            keyEquivalent:@""];
  refresh.target = self;
  [menu addItem:refresh];
  [menu addItem:NSMenuItem.separatorItem];

  NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit AgentUsageBar"
                                                action:@selector(quit)
                                         keyEquivalent:@"q"];
  quit.target = self;
  [menu addItem:quit];

  _statusItem.menu = menu;
  [_statusItem.button performClick:nil];
  _statusItem.menu = nil;
}

- (void)quit {
  _terminating = true;
  [NSApp terminate:nil];
}

- (void)usagePanelViewDidRequestRefresh:(AUBUsagePanelView *)view {
  (void)view;
  [self refresh];
}

- (void)usagePanelViewDidChangeContentHeight:(AUBUsagePanelView *)view {
  (void)view;
  [self updatePanelSize];
}

- (BOOL)usagePanelViewOpenAtLogin:(AUBUsagePanelView *)view {
  (void)view;
  return _openAtLogin;
}

- (void)usagePanelView:(AUBUsagePanelView *)view setOpenAtLogin:(BOOL)enabled {
  (void)view;
  if (AUBSetLoginItem(enabled)) {
    _openAtLogin = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled
                                          forKey:@"open_at_login"];
  } else {
    NSBeep();
  }
}

- (BOOL)usagePanelViewShortcutEnabled:(AUBUsagePanelView *)view {
  (void)view;
  return _shortcutEnabled;
}

- (BOOL)usagePanelViewShortcutConflicted:(AUBUsagePanelView *)view {
  (void)view;
  return _shortcutConflict;
}

- (void)usagePanelView:(AUBUsagePanelView *)view
    setShortcutEnabled:(BOOL)enabled {
  (void)view;
  _shortcutEnabled = enabled;
  [NSUserDefaults.standardUserDefaults setBool:enabled
                                        forKey:@"shortcut_enabled"];
  if (enabled) {
    [self registerHotKey];
  } else {
    if (_hotKey != NULL) {
      UnregisterEventHotKey(_hotKey);
      _hotKey = NULL;
    }
    _shortcutConflict = false;
  }
}

- (void)usagePanelView:(AUBUsagePanelView *)view
    toggleStatusComponentAtIndex:(uint8_t)index {
  (void)view;
  if (index >= _snapshot.statusComponentCount)
    return;
  AUBStatusComponent *component = &_snapshot.statusComponents[index];
  if (component->tracked) {
    uint8_t trackedCount = 0;
    for (uint8_t current = 0; current < _snapshot.statusComponentCount;
         current++) {
      if (_snapshot.statusComponents[current].tracked)
        trackedCount++;
    }
    if (trackedCount == 1) {
      NSBeep();
      return;
    }
  }
  component->tracked = !component->tracked;
  NSMutableArray<NSString *> *identifiers =
      [NSMutableArray arrayWithCapacity:_snapshot.statusComponentCount];
  for (uint8_t current = 0; current < _snapshot.statusComponentCount;
       current++) {
    const AUBStatusComponent *candidate = &_snapshot.statusComponents[current];
    if (!candidate->tracked)
      continue;
    NSString *identifier = [NSString stringWithUTF8String:candidate->id];
    if (identifier != nil)
      [identifiers addObject:identifier];
  }
  [NSUserDefaults.standardUserDefaults setObject:identifiers
                                          forKey:@"tracked_component_ids"];
  _statusRevision++;
  AUBSaveSnapshot(&_snapshot);
  [_usagePanelView reload];
  [self refreshStatus];
}

- (AUBAppearanceMode)usagePanelViewAppearanceMode:(AUBUsagePanelView *)view {
  (void)view;
  return _appearanceMode;
}

- (void)usagePanelView:(AUBUsagePanelView *)view
     setAppearanceMode:(AUBAppearanceMode)mode {
  (void)view;
  _appearanceMode = mode;
  NSString *value = nil;
  switch (mode) {
  case AUBAppearanceModeSystem:
    value = @"system";
    break;
  case AUBAppearanceModeDark:
    value = @"dark";
    break;
  case AUBAppearanceModeLight:
    value = @"light";
    break;
  }
  [NSUserDefaults.standardUserDefaults setObject:value
                                          forKey:@"appearance_mode"];
  [self applyAppearance];
  [_usagePanelView reload];
}

- (void)usagePanelView:(AUBUsagePanelView *)view
    setBudgetOverrideMinor:(int64_t)minor
               forProvider:(AUBProviderKind)providerKind {
  (void)view;
  AUBProviderState *provider = [self stateForKind:providerKind];
  if (minor <= 0 || !provider->budget.present ||
      (provider->budget.hasLimit && !provider->budget.overridden)) {
    NSBeep();
    return;
  }
  [NSUserDefaults.standardUserDefaults
      setObject:@(minor)
         forKey:AUBBudgetOverrideKey(providerKind)];
  provider->budget.limitMinor = minor;
  provider->budget.hasLimit = true;
  provider->budget.overridden = true;
  AUBSaveSnapshot(&_snapshot);
  [_usagePanelView reload];
  [self updatePanelSize];
}

- (void)usagePanelView:(AUBUsagePanelView *)view
    clearBudgetOverrideForProvider:(AUBProviderKind)providerKind {
  (void)view;
  AUBProviderState *provider = [self stateForKind:providerKind];
  [NSUserDefaults.standardUserDefaults
      removeObjectForKey:AUBBudgetOverrideKey(providerKind)];
  if (provider->budget.overridden) {
    provider->budget.overridden = false;
    provider->budget.hasLimit = false;
    provider->budget.limitMinor = 0;
  }
  AUBSaveSnapshot(&_snapshot);
  [_usagePanelView reload];
  [self updatePanelSize];
}

@end

int main(int argc, const char *argv[]) {
  (void)argv;
  if (argc != 1)
    return 2;

  @autoreleasepool {
    NSApplication *application = NSApplication.sharedApplication;
    AUBAppDelegate *delegate = [AUBAppDelegate new];
    application.delegate = delegate;
    [application run];
  }
  return 0;
}
