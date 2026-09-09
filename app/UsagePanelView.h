#import <AppKit/AppKit.h>

#import "FetcherProtocol.h"

@class AUBUsagePanelView;

typedef NS_ENUM(uint8_t, AUBAppearanceMode) {
  AUBAppearanceModeSystem,
  AUBAppearanceModeDark,
  AUBAppearanceModeLight,
};

typedef NS_ENUM(uint8_t, AUBProviderKind) {
  AUBProviderKindClaude,
  AUBProviderKindCodex,
};

@protocol AUBUsagePanelViewDelegate <NSObject>
- (void)usagePanelViewDidRequestRefresh:(AUBUsagePanelView *)view;
- (void)usagePanelViewDidChangeContentHeight:(AUBUsagePanelView *)view;
- (BOOL)usagePanelViewOpenAtLogin:(AUBUsagePanelView *)view;
- (void)usagePanelView:(AUBUsagePanelView *)view setOpenAtLogin:(BOOL)enabled;
- (BOOL)usagePanelViewShortcutEnabled:(AUBUsagePanelView *)view;
- (BOOL)usagePanelViewShortcutConflicted:(AUBUsagePanelView *)view;
- (void)usagePanelView:(AUBUsagePanelView *)view
    setShortcutEnabled:(BOOL)enabled;
- (void)usagePanelView:(AUBUsagePanelView *)view
    toggleStatusComponentAtIndex:(uint8_t)index;
- (AUBAppearanceMode)usagePanelViewAppearanceMode:(AUBUsagePanelView *)view;
- (void)usagePanelView:(AUBUsagePanelView *)view
     setAppearanceMode:(AUBAppearanceMode)mode;
- (void)usagePanelView:(AUBUsagePanelView *)view
    setBudgetOverrideMinor:(int64_t)minor
               forProvider:(AUBProviderKind)provider;
- (void)usagePanelView:(AUBUsagePanelView *)view
    clearBudgetOverrideForProvider:(AUBProviderKind)provider;
/// NO when the path names nothing this app can read, which leaves the field in
/// editing so the user can correct it rather than storing a setting that fails
/// on the next refresh.
- (BOOL)usagePanelView:(AUBUsagePanelView *)view
       setHomeOverride:(NSString *)path
           forProvider:(AUBProviderKind)provider;
- (void)usagePanelView:(AUBUsagePanelView *)view
    clearHomeOverrideForProvider:(AUBProviderKind)provider;
@end

@interface AUBUsagePanelView : NSView

- (instancetype)initWithSnapshot:(const AUBSnapshot *)snapshot
                        delegate:(id<AUBUsagePanelViewDelegate>)delegate;
- (CGFloat)contentHeight;
- (void)reload;

@end
