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
  if (provider->status == AUBProviderStatusSignedOut ||
      provider->status == AUBProviderStatusPending) {
    return true;
  }

  char group[96] = {0};
  int count = snprintf(group, sizeof(group), "%s ", mark);
  if (count < 0 || (size_t)count >= sizeof(group))
    return false;
  if (provider->status == AUBProviderStatusFailed) {
    if (!AUBAppendText(group, sizeof(group), "?"))
      return false;
  } else {
    const AUBWindow *session = AUBHeadlineWindow(provider, "session");
    const AUBWindow *weekly = AUBHeadlineWindow(provider, "weekly");
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
- (void)refreshUsage;
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
  id openAtLogin = [defaults objectForKey:@"open_at_login"];
  if (openAtLogin != nil) {
    _openAtLogin = [defaults boolForKey:@"open_at_login"];
  } else {
    _openAtLogin = AUBSetLoginItem(true);
    if (_openAtLogin)
      [defaults setBool:YES forKey:@"open_at_login"];
  }
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
    [self render];
  } else {
    [self refresh];
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
  [self refreshUsage];
  [self refreshStatus];
}

- (void)refreshUsage {
  if (_usageRefreshing)
    return;
  _usageRefreshing = true;
  NSString *helper = [NSBundle.mainBundle.bundlePath
      stringByAppendingPathComponent:@"Contents/Helpers/AgentUsageFetcher"];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
      AUBSnapshot snapshot = {0};
      bool succeeded =
          helper != nil && AUBRunFetcher(helper.fileSystemRepresentation,
                                         AUBFetcherModeUsage, &snapshot);
      dispatch_async(dispatch_get_main_queue(), ^{
        self->_usageRefreshing = false;
        if (succeeded) {
          self->_snapshot.valid = snapshot.valid;
          self->_snapshot.fetchedAt = snapshot.fetchedAt;
          self->_snapshot.claude = snapshot.claude;
          self->_snapshot.codex = snapshot.codex;
          [self applyBudgetOverrides];
          AUBSaveSnapshot(&self->_snapshot);
          [self render];
          [self->_usagePanelView reload];
          [self updatePanelSize];
        } else {
          self->_statusItem.button.title = @"!";
          self->_statusItem.button.toolTip = @"Usage refresh failed";
        }
      });
    }
  });
}

- (void)applyBudgetOverrides {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  AUBProviderState *providers[] = {&_snapshot.claude, &_snapshot.codex};
  NSString *keys[] = {@"budget_override_minor_claude",
                      @"budget_override_minor_codex"};
  for (uint8_t index = 0; index < 2; index++) {
    AUBProviderState *provider = providers[index];
    if (!provider->budget.present || provider->budget.hasLimit)
      continue;
    id value = [defaults objectForKey:keys[index]];
    if (value == nil)
      continue;
    if (![value isKindOfClass:NSNumber.class] || [value longLongValue] <= 0) {
      [defaults removeObjectForKey:keys[index]];
      continue;
    }
    provider->budget.limitMinor = [value longLongValue];
    provider->budget.hasLimit = true;
    provider->budget.overridden = true;
  }
}

- (void)refreshStatus {
  if (_statusRefreshing) {
    _statusRefreshPending = true;
    return;
  }
  _statusRefreshing = true;
  uint32_t revision = _statusRevision;
  NSString *helper = [NSBundle.mainBundle.bundlePath
      stringByAppendingPathComponent:@"Contents/Helpers/AgentUsageFetcher"];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
      AUBSnapshot snapshot = {0};
      bool succeeded =
          helper != nil && AUBRunFetcher(helper.fileSystemRepresentation,
                                         AUBFetcherModeStatus, &snapshot);
      dispatch_async(dispatch_get_main_queue(), ^{
        self->_statusRefreshing = false;
        if (succeeded && snapshot.hasStatus &&
            revision == self->_statusRevision) {
          self->_snapshot.hasStatus = true;
          self->_snapshot.statusIndicator = snapshot.statusIndicator;
          self->_snapshot.statusFetchedAt = snapshot.statusFetchedAt;
          memcpy(self->_snapshot.statusDescription, snapshot.statusDescription,
                 sizeof(self->_snapshot.statusDescription));
          memcpy(self->_snapshot.statusContext, snapshot.statusContext,
                 sizeof(self->_snapshot.statusContext));
          memcpy(self->_snapshot.statusComponents, snapshot.statusComponents,
                 sizeof(self->_snapshot.statusComponents));
          self->_snapshot.statusComponentCount = snapshot.statusComponentCount;
          AUBSaveSnapshot(&self->_snapshot);
          [self->_usagePanelView reload];
          [self updatePanelSize];
        }
        if (self->_statusRefreshPending) {
          self->_statusRefreshPending = false;
          [self refreshStatus];
        }
      });
    }
  });
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

  double now = CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970;
  if (!_snapshot.valid || now - _snapshot.fetchedAt > 60)
    [self refreshUsage];
  if (!_snapshot.hasStatus || now - _snapshot.statusFetchedAt > 60)
    [self refreshStatus];
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
  NSString *key = nil;
  AUBProviderState *provider = NULL;
  switch (providerKind) {
  case AUBProviderKindClaude:
    key = @"budget_override_minor_claude";
    provider = &_snapshot.claude;
    break;
  case AUBProviderKindCodex:
    key = @"budget_override_minor_codex";
    provider = &_snapshot.codex;
    break;
  }
  if (minor <= 0 || !provider->budget.present ||
      (provider->budget.hasLimit && !provider->budget.overridden)) {
    NSBeep();
    return;
  }
  [NSUserDefaults.standardUserDefaults setObject:@(minor) forKey:key];
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
  NSString *key = nil;
  AUBProviderState *provider = NULL;
  switch (providerKind) {
  case AUBProviderKindClaude:
    key = @"budget_override_minor_claude";
    provider = &_snapshot.claude;
    break;
  case AUBProviderKindCodex:
    key = @"budget_override_minor_codex";
    provider = &_snapshot.codex;
    break;
  }
  [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
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
