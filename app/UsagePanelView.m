#import "UsagePanelView.h"

#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/// Actions marked below carry their target in `AUBActionRect.argument`, so
/// adding a provider or an appearance option does not add enum cases or
/// `mouseDown:` branches.
typedef NS_ENUM(uint8_t, AUBAction) {
  AUBActionRefresh,
  AUBActionToggleSettings,
  AUBActionToggleLogin,
  AUBActionToggleShortcut,
  AUBActionToggleStatusComponent, // argument: component index
  AUBActionManageProvider,        // argument: AUBProviderKind
  AUBActionEditBudget,            // argument: AUBProviderKind
  AUBActionSetBudget,             // argument: AUBProviderKind
  AUBActionClearBudget,           // argument: AUBProviderKind
  AUBActionAppearance,            // argument: AUBAppearanceMode
};

typedef struct {
  NSRect rect;
  AUBAction action;
  uint8_t argument;
} AUBActionRect;

/// Headroom over the worst case (refresh, settings, 3 toggles, 2 manage links,
/// 6 budget controls, 3 appearance segments, one row per status component) so
/// that adding a control cannot silently push the last row past the limit.
enum { AUBMaxActions = AUBMaxStatusComponents + 24 };

static const CGFloat AUBWidth = 360;
static const CGFloat AUBMargin = 16;
static const CGFloat AUBArrowHeight = 10;
static const CGFloat AUBContentWidth = AUBWidth - 2 * AUBMargin;
static const CGFloat AUBBodyRadius = 11;
// Legacy wheels report line counts rather than points.
static const CGFloat AUBScrollLineHeight = 24;

static NSString *AUBString(const char *text) {
  if (text[0] == '\0')
    return @"";
  NSString *value = [NSString stringWithUTF8String:text];
  return value ?: @"";
}

static NSColor *AUBTierColor(double percent) {
  if (percent < 70)
    return [NSColor colorWithRed:0.13 green:0.77 blue:0.37 alpha:1];
  if (percent < 90)
    return [NSColor colorWithRed:1 green:0.80 blue:0 alpha:1];
  return [NSColor colorWithRed:1 green:0.23 blue:0.19 alpha:1];
}

static NSDictionary<NSAttributedStringKey, id> *
AUBAttributes(CGFloat size, NSFontWeight weight, NSColor *color) {
  return @{
    NSFontAttributeName : [NSFont systemFontOfSize:size weight:weight],
    NSForegroundColorAttributeName : color,
  };
}

static void AUBDrawText(NSString *text, CGFloat x, CGFloat y,
                        NSDictionary<NSAttributedStringKey, id> *attributes) {
  [text drawAtPoint:NSMakePoint(x, y) withAttributes:attributes];
}

static void AUBDrawRight(NSString *text, CGFloat right, CGFloat y,
                         NSDictionary<NSAttributedStringKey, id> *attributes) {
  CGFloat width = ceil([text sizeWithAttributes:attributes].width);
  [text drawAtPoint:NSMakePoint(right - width, y) withAttributes:attributes];
}

/// Built once rather than per checkbox: up to nineteen are drawn per pass. Safe
/// to cache because `whiteColor` is a fixed color, unlike the accent and label
/// colors below it, which must resolve against the live appearance on every
/// draw.
static NSDictionary<NSAttributedStringKey, id> *AUBCheckAttributes(void) {
  static NSDictionary<NSAttributedStringKey, id> *attributes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    attributes = AUBAttributes(9, NSFontWeightSemibold, NSColor.whiteColor);
  });
  return attributes;
}

static void AUBDrawCheckbox(bool enabled, CGFloat x, CGFloat y) {
  NSRect box = NSMakeRect(x, y, 12, 12);
  [NSColor.tertiaryLabelColor setStroke];
  [[NSBezierPath bezierPathWithRoundedRect:box xRadius:2 yRadius:2] stroke];
  if (!enabled)
    return;
  [NSColor.controlAccentColor setFill];
  [[NSBezierPath bezierPathWithRoundedRect:box xRadius:2 yRadius:2] fill];
  AUBDrawText(@"✓", x + 2, y - 1, AUBCheckAttributes());
}

static NSString *AUBProviderName(AUBProviderKind kind) {
  return kind == AUBProviderKindClaude ? @"Claude" : @"Codex";
}

/// The line a provider has earned in the empty state: a command the user can
/// actually run, or nothing at all when its CLI is not on this Mac.
static NSString *AUBProviderHint(AUBProviderKind kind,
                                 const AUBProviderState *provider) {
  if (!AUBProviderInstalled(provider))
    return nil;
  return kind == AUBProviderKindClaude
             ? @"Run `claude login` to track Claude usage."
             : @"Run `codex login` to track Codex usage.";
}

static NSString *AUBManageURL(AUBProviderKind kind) {
  return kind == AUBProviderKindClaude
             ? @"https://claude.ai/settings/usage"
             : @"https://chatgpt.com/codex/settings/usage";
}

static const AUBProviderState *AUBStateForKind(const AUBSnapshot *snapshot,
                                               AUBProviderKind kind) {
  return kind == AUBProviderKindClaude ? &snapshot->claude : &snapshot->codex;
}

static NSString *AUBComponentStatusLabel(AUBComponentStatus status) {
  switch (status) {
  case AUBComponentStatusOperational:
    return @"operational";
  case AUBComponentStatusUnderMaintenance:
    return @"maintenance";
  case AUBComponentStatusDegradedPerformance:
    return @"degraded";
  case AUBComponentStatusPartialOutage:
    return @"partial outage";
  case AUBComponentStatusMajorOutage:
    return @"major outage";
  }
}

static bool AUBCanOverrideBudget(const AUBProviderState *provider) {
  return provider->status == AUBProviderStatusReady &&
         provider->budget.present &&
         (!provider->budget.hasLimit || provider->budget.overridden);
}

static uint8_t AUBBudgetCandidateCount(const AUBSnapshot *snapshot) {
  return (AUBCanOverrideBudget(&snapshot->claude) ? 1 : 0) +
         (AUBCanOverrideBudget(&snapshot->codex) ? 1 : 0);
}

static int64_t AUBScale(uint8_t exponent) {
  int64_t scale = 1;
  for (uint8_t index = 0; index < exponent; index++)
    scale *= 10;
  return scale;
}

static CGFloat
AUBDrawWrapped(NSString *text, NSRect rect,
               NSDictionary<NSAttributedStringKey, id> *attributes, bool draw) {
  NSRect measured =
      [text boundingRectWithSize:NSMakeSize(rect.size.width, CGFLOAT_MAX)
                         options:NSStringDrawingUsesLineFragmentOrigin
                      attributes:attributes];
  CGFloat height = ceil(measured.size.height);
  if (draw) {
    rect.size.height = height;
    [text drawWithRect:rect
               options:NSStringDrawingUsesLineFragmentOrigin
            attributes:attributes];
  }
  return height;
}

static NSString *AUBFormatEpoch(double epoch, const char *format) {
  time_t seconds = (time_t)epoch;
  struct tm local = {0};
  localtime_r(&seconds, &local);
  char buffer[64];
  strftime(buffer, sizeof(buffer), format, &local);
  return AUBString(buffer);
}

static NSString *AUBResetText(const AUBWindow *window) {
  if (!window->hasReset)
    return @"";
  return AUBFormatEpoch(window->resetsAt,
                        strcmp(window->id, AUBWindowIDSession) == 0
                            ? "Resets at %-I:%M %p"
                            : "Resets on %-d %b at %-I:%M %p");
}

static NSString *AUBUpdatedText(double epoch) {
  return AUBFormatEpoch(epoch, "Last updated: %-I:%M %p");
}

static NSString *AUBGroupedInteger(int64_t value) {
  char digits[32];
  snprintf(digits, sizeof(digits), "%lld", value);
  size_t length = strlen(digits);
  size_t commas = length > 0 ? (length - 1) / 3 : 0;
  char output[48];
  size_t destination = length + commas;
  output[destination] = '\0';
  size_t source = length;
  size_t group = 0;
  while (source > 0) {
    output[--destination] = digits[--source];
    if (++group == 3 && source > 0) {
      output[--destination] = ',';
      group = 0;
    }
  }
  return AUBString(output);
}

static NSString *AUBAmount(int64_t minor, const AUBBudgetReading *budget) {
  int64_t scale = AUBScale(budget->exponent);
  int64_t whole = minor / scale;

  if (budget->unit == AUBBudgetUnitCredits) {
    return [NSString stringWithFormat:@"%@ credits", AUBGroupedInteger(whole)];
  }

  NSString *prefix = @"";
  if (strcmp(budget->currency, "USD") == 0) {
    prefix = @"$";
  } else if (strcmp(budget->currency, "EUR") == 0) {
    prefix = @"€";
  } else if (strcmp(budget->currency, "GBP") == 0) {
    prefix = @"£";
  } else if (strcmp(budget->currency, "JPY") == 0) {
    prefix = @"¥";
  } else {
    prefix = [AUBString(budget->currency) stringByAppendingString:@" "];
  }

  if (budget->exponent == 0) {
    return
        [NSString stringWithFormat:@"%@%@", prefix, AUBGroupedInteger(whole)];
  }
  return [NSString stringWithFormat:@"%@%@.%0*lld", prefix,
                                    AUBGroupedInteger(whole), budget->exponent,
                                    llabs(minor % scale)];
}

@interface AUBUsagePanelView () {
  const AUBSnapshot *_snapshot;
  __weak id<AUBUsagePanelViewDelegate> _delegate;
  AUBActionRect _actions[AUBMaxActions];
  uint8_t _actionCount;
  CGFloat _scrollOffset;
  CGFloat _measuredHeight;
  bool _heightValid;
  bool _showingSettings;
  bool _editingBudget;
  AUBProviderKind _budgetEditorKind;
  char _budgetInput[24];
  NSDictionary<NSAttributedStringKey, id> *_headline;
  NSDictionary<NSAttributedStringKey, id> *_subheadline;
  NSDictionary<NSAttributedStringKey, id> *_subheadlineBold;
  NSDictionary<NSAttributedStringKey, id> *_caption;
  NSDictionary<NSAttributedStringKey, id> *_caption2;
  NSDictionary<NSAttributedStringKey, id> *_warning;
  NSDictionary<NSAttributedStringKey, id> *_warning2;
  NSDictionary<NSAttributedStringKey, id> *_segment;
  NSDictionary<NSAttributedStringKey, id> *_segmentSelected;
}
@end

@implementation AUBUsagePanelView

- (instancetype)initWithSnapshot:(const AUBSnapshot *)snapshot
                        delegate:(id<AUBUsagePanelViewDelegate>)delegate {
  self = [super initWithFrame:NSMakeRect(0, 0, AUBWidth, 260)];
  if (self) {
    _snapshot = snapshot;
    _delegate = delegate;
    _headline = AUBAttributes(NSFont.systemFontSize, NSFontWeightRegular,
                              NSColor.labelColor);
    _subheadline = AUBAttributes(NSFont.smallSystemFontSize + 1,
                                 NSFontWeightRegular, NSColor.labelColor);
    _subheadlineBold = AUBAttributes(NSFont.smallSystemFontSize + 1,
                                     NSFontWeightSemibold, NSColor.labelColor);
    _caption = AUBAttributes(NSFont.smallSystemFontSize, NSFontWeightRegular,
                             NSColor.secondaryLabelColor);
    _caption2 = AUBAttributes(NSFont.smallSystemFontSize - 1,
                              NSFontWeightRegular, NSColor.secondaryLabelColor);
    _warning = AUBAttributes(NSFont.smallSystemFontSize, NSFontWeightRegular,
                             NSColor.systemOrangeColor);
    _warning2 = AUBAttributes(NSFont.smallSystemFontSize - 1,
                              NSFontWeightRegular, NSColor.systemOrangeColor);
    _segment = AUBAttributes(NSFont.smallSystemFontSize - 1,
                             NSFontWeightRegular, NSColor.labelColor);
    _segmentSelected = AUBAttributes(NSFont.smallSystemFontSize - 1,
                                     NSFontWeightRegular, NSColor.whiteColor);
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

// The measure pass is offset-independent, so the result only changes when the
// snapshot or the settings state does.
- (CGFloat)contentHeight {
  if (!_heightValid)
    [self layoutAndDraw:NO];
  return _measuredHeight;
}

- (CGFloat)maximumScrollOffset {
  return MAX(0, [self contentHeight] - self.bounds.size.height);
}

// Scrolling by whole device pixels keeps glyph rasterization on the cached
// path. The offset itself stays unsnapped so sub-pixel deltas still accumulate.
- (CGFloat)snappedScrollOffset {
  CGFloat scale = self.window.backingScaleFactor;
  if (scale <= 0)
    scale = 1;
  return round(_scrollOffset * scale) / scale;
}

- (void)reload {
  _heightValid = false;
  _scrollOffset = MIN(_scrollOffset, [self maximumScrollOffset]);
  [self setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  if (_snapshot == NULL)
    return;
  _scrollOffset = MIN(_scrollOffset, [self maximumScrollOffset]);
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  [NSColor.clearColor setFill];
  NSRectFill(self.bounds);
  NSBezierPath *body = [NSBezierPath
      bezierPathWithRoundedRect:NSMakeRect(0, AUBArrowHeight, AUBWidth,
                                           self.bounds.size.height -
                                               AUBArrowHeight)
                        xRadius:AUBBodyRadius
                        yRadius:AUBBodyRadius];
  [NSColor.windowBackgroundColor setFill];
  [body fill];
  NSBezierPath *arrow = [NSBezierPath bezierPath];
  [arrow moveToPoint:NSMakePoint(AUBWidth / 2 - 10, AUBArrowHeight)];
  [arrow lineToPoint:NSMakePoint(AUBWidth / 2, 0)];
  [arrow lineToPoint:NSMakePoint(AUBWidth / 2 + 10, AUBArrowHeight)];
  [arrow closePath];
  [arrow fill];

  // Content is laid out in unscrolled coordinates and shifted by the CTM, so
  // the clip keeps it inside the rounded body instead of over the arrow.
  [NSGraphicsContext saveGraphicsState];
  [body addClip];
  CGContextTranslateCTM(NSGraphicsContext.currentContext.CGContext, 0,
                        -[self snappedScrollOffset]);
  [self layoutAndDraw:YES];
  [NSGraphicsContext restoreGraphicsState];
}

// Delegate getters called from here must stay side-effect free: the measure
// pass runs them too, and one that called -reload would recurse forever.
- (void)layoutAndDraw:(bool)draw {
  if (draw)
    _actionCount = 0;
  CGFloat y = AUBMargin + AUBArrowHeight;

  if (draw)
    AUBDrawText(@"Agent Usage", AUBMargin, y, _headline);
  y += 32;

  bool hasProvider = AUBProviderVisible(&_snapshot->claude) ||
                     AUBProviderVisible(&_snapshot->codex);

  if (!hasProvider) {
    NSString *hints[AUBProviderKindCodex + 1];
    uint8_t hintCount = 0;
    for (AUBProviderKind kind = AUBProviderKindClaude;
         kind <= AUBProviderKindCodex; kind++) {
      NSString *hint = AUBProviderHint(kind, AUBStateForKind(_snapshot, kind));
      if (hint != nil)
        hints[hintCount++] = hint;
    }
    if (draw) {
      AUBDrawText(hintCount == 0 ? @"👋 No agent CLI on this Mac"
                                 : @"👋 No providers signed in",
                  AUBMargin, y, _subheadline);
    }
    y += 22;
    if (hintCount == 0)
      hints[hintCount++] = @"Install Claude Code or Codex to track usage.";
    for (uint8_t index = 0; index < hintCount; index++) {
      if (draw)
        AUBDrawText(hints[index], AUBMargin, y, _caption);
      y += 18;
    }
  } else {
    for (AUBProviderKind kind = AUBProviderKindClaude;
         kind <= AUBProviderKindCodex; kind++) {
      y = [self provider:kind y:y draw:draw];
    }
  }

  if (_snapshot->hasStatus) {
    y += 2;
    if (draw) {
      [NSColor.separatorColor setFill];
      NSRectFill(NSMakeRect(AUBMargin, y, AUBContentWidth, 1));
    }
    y += 14;
    NSColor *dotColor = NSColor.systemGreenColor;
    if (_snapshot->statusIndicator == AUBStatusIndicatorMinor) {
      dotColor = NSColor.systemYellowColor;
    } else if (_snapshot->statusIndicator == AUBStatusIndicatorMajor) {
      dotColor = NSColor.systemOrangeColor;
    } else if (_snapshot->statusIndicator == AUBStatusIndicatorCritical) {
      dotColor = NSColor.systemRedColor;
    }
    if (draw) {
      [dotColor setFill];
      [[NSBezierPath
          bezierPathWithOvalInRect:NSMakeRect(AUBMargin, y + 3, 8, 8)] fill];
      NSString *summary = _snapshot->statusIndicator == AUBStatusIndicatorNone
                              ? @"All Claude services operational"
                              : AUBString(_snapshot->statusDescription);
      AUBDrawText(summary, AUBMargin + 16, y, _caption);
      AUBDrawText(AUBString(_snapshot->statusContext), AUBMargin + 16, y + 17,
                  _caption2);
    }
    y += 42;
  }

  y += 4;
  if (draw) {
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(AUBMargin, y, AUBContentWidth, 1));
  }
  y += 14;

  if (_snapshot->valid) {
    if (draw)
      AUBDrawText(AUBUpdatedText(_snapshot->fetchedAt), AUBMargin, y, _caption);
  }
  NSString *refresh = @"Refresh";
  if (draw) {
    AUBDrawRight(refresh, AUBWidth - AUBMargin, y, _subheadline);
    CGFloat width = ceil([refresh sizeWithAttributes:_subheadline].width);
    [self addAction:AUBActionRefresh
               rect:NSMakeRect(AUBWidth - AUBMargin - width - 4, y - 2,
                               width + 8, 20)];
  }
  y += 30;

  NSString *settings = _showingSettings ? @"Hide Settings" : @"Settings";
  if (draw) {
    AUBDrawText(settings, AUBMargin, y, _subheadline);
    CGFloat width = ceil([settings sizeWithAttributes:_subheadline].width);
    [self addAction:AUBActionToggleSettings
               rect:NSMakeRect(AUBMargin - 4, y - 2, width + 8, 20)];
  }
  y += 24;

  if (_showingSettings) {
    // Measure the block to size its background, so the two cannot disagree. The
    // background has to be filled before the rows draw over it, which is why
    // this is the one place a second pass is unavoidable.
    if (draw) {
      CGFloat height = [self settingsAtY:y draw:NO] - y;
      [[NSColor.secondaryLabelColor colorWithAlphaComponent:0.08] setFill];
      [[NSBezierPath
          bezierPathWithRoundedRect:NSMakeRect(AUBMargin, y, AUBContentWidth,
                                               height)
                            xRadius:6
                            yRadius:6] fill];
    }
    y = [self settingsAtY:y draw:draw];
  }

  _measuredHeight = y + AUBMargin;
  _heightValid = true;
}

/// Which Claude services to watch. The snapshot carries a status half only on a
/// machine that runs Claude Code, so this section appears with the components
/// it lists rather than as a header over an empty list.
- (CGFloat)statusSettingsAtY:(CGFloat)y draw:(bool)draw {
  if (!_snapshot->hasStatus)
    return y;

  if (draw) {
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(AUBMargin + 8, y, AUBContentWidth - 16, 1));
  }
  y += 14;
  if (draw) {
    AUBDrawText(@"Claude status: services to track", AUBMargin + 10, y,
                _caption);
  }
  y += 18;
  if (draw) {
    AUBDrawText(@"At least one service must remain selected.", AUBMargin + 10,
                y, _caption2);
  }
  y += 24;
  for (uint8_t index = 0; index < _snapshot->statusComponentCount; index++) {
    const AUBStatusComponent *component = &_snapshot->statusComponents[index];
    if (draw) {
      AUBDrawCheckbox(component->tracked, AUBMargin + 10, y + 1);
      AUBDrawText(AUBString(component->name), AUBMargin + 28, y, _caption2);
      AUBDrawRight(AUBComponentStatusLabel(component->status),
                   AUBWidth - AUBMargin - 10, y, _caption2);
      [self
          addAction:AUBActionToggleStatusComponent
           argument:index
               rect:NSMakeRect(AUBMargin + 6, y - 3, AUBContentWidth - 12, 22)];
    }
    y += 24;
  }
  return y;
}

- (CGFloat)settingsAtY:(CGFloat)y draw:(bool)draw {
  uint8_t budgetCandidateCount = AUBBudgetCandidateCount(_snapshot);
  bool shortcutConflict = [_delegate usagePanelViewShortcutConflicted:self];
  y += 10;
  if (draw) {
    AUBDrawCheckbox([_delegate usagePanelViewOpenAtLogin:self], AUBMargin + 10,
                    y + 1);
    AUBDrawText(@"Open at Login", AUBMargin + 28, y, _caption);
    AUBDrawText(@"Launch automatically when you log in", AUBMargin + 28, y + 17,
                _caption2);
    [self addAction:AUBActionToggleLogin
               rect:NSMakeRect(AUBMargin + 6, y - 3, AUBContentWidth - 12, 38)];
  }
  y += 48;
  if (draw) {
    AUBDrawCheckbox([_delegate usagePanelViewShortcutEnabled:self],
                    AUBMargin + 10, y + 1);
    AUBDrawText(@"Keyboard Shortcut (⌘U)", AUBMargin + 28, y, _caption);
    AUBDrawText(@"Toggle this popup from anywhere", AUBMargin + 28, y + 17,
                _caption2);
    [self addAction:AUBActionToggleShortcut
               rect:NSMakeRect(AUBMargin + 6, y - 3, AUBContentWidth - 12, 38)];
  }
  y += 42;
  if (shortcutConflict) {
    if (draw) {
      AUBDrawText(@"⌘U is already in use, so the shortcut is inactive.",
                  AUBMargin + 28, y, _warning2);
    }
    y += 18;
  }

  if (draw) {
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(AUBMargin + 8, y, AUBContentWidth - 16, 1));
  }
  y += 14;
  if (draw)
    AUBDrawText(@"Monthly budget", AUBMargin + 10, y, _caption);
  y += 20;
  if (budgetCandidateCount == 0) {
    if (draw) {
      AUBDrawText(@"Each signed-in provider reports its own limit.",
                  AUBMargin + 10, y, _caption2);
    }
    y += 20;
  } else {
    for (AUBProviderKind kind = AUBProviderKindClaude;
         kind <= AUBProviderKindCodex; kind++) {
      const AUBProviderState *provider = AUBStateForKind(_snapshot, kind);
      if (!AUBCanOverrideBudget(provider))
        continue;
      NSRect field = NSMakeRect(AUBMargin + 70, y - 3, 96, 22);
      if (draw) {
        bool editing = [self isEditingBudgetFor:kind];
        AUBDrawText(AUBProviderName(kind), AUBMargin + 10, y, _caption2);
        [(editing ? NSColor.controlAccentColor
                  : NSColor.tertiaryLabelColor) setStroke];
        [[NSBezierPath bezierPathWithRoundedRect:field xRadius:4
                                         yRadius:4] stroke];
        NSString *input = @"";
        if (editing) {
          input = AUBString(_budgetInput);
        } else if (provider->budget.overridden) {
          double value = (double)provider->budget.limitMinor /
                         (double)AUBScale(provider->budget.exponent);
          input = [NSString
              stringWithFormat:@"%.*f", provider->budget.exponent, value];
        }
        NSDictionary *inputAttributes =
            input.length == 0 ? _caption2 : _caption;
        AUBDrawText(input.length == 0 ? @"e.g. 1000" : input, NSMinX(field) + 6,
                    y, inputAttributes);
        [self addAction:AUBActionEditBudget argument:kind rect:field];

        NSRect set = NSMakeRect(NSMaxX(field) + 8, y - 3, 34, 22);
        AUBDrawText(@"Set", NSMinX(set) + 6, y, _caption);
        [self addAction:AUBActionSetBudget argument:kind rect:set];
        if (provider->budget.overridden) {
          NSRect clear = NSMakeRect(NSMaxX(set) + 6, y - 3, 44, 22);
          AUBDrawText(@"Clear", NSMinX(clear) + 4, y, _caption);
          [self addAction:AUBActionClearBudget argument:kind rect:clear];
        }
      }
      y += 34;
    }
  }

  y = [self statusSettingsAtY:y draw:draw];

  if (draw) {
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(AUBMargin + 8, y, AUBContentWidth - 16, 1));
  }
  y += 14;
  if (draw)
    AUBDrawText(@"Appearance", AUBMargin + 10, y, _caption);
  y += 22;
  const AUBAppearanceMode modes[] = {
      AUBAppearanceModeSystem,
      AUBAppearanceModeDark,
      AUBAppearanceModeLight,
  };
  NSString *const labels[] = {@"System", @"Dark", @"Light"};
  const uint8_t segmentCount = sizeof(modes) / sizeof(modes[0]);
  CGFloat segmentWidth = (AUBContentWidth - 20) / segmentCount;
  AUBAppearanceMode selected = [_delegate usagePanelViewAppearanceMode:self];
  for (uint8_t index = 0; index < segmentCount; index++) {
    NSRect segment =
        NSMakeRect(AUBMargin + 10 + segmentWidth * index, y, segmentWidth, 24);
    if (draw) {
      bool isSelected = selected == modes[index];
      [(isSelected
            ? NSColor.controlAccentColor
            : [NSColor.labelColor colorWithAlphaComponent:0.08]) setFill];
      [[NSBezierPath bezierPathWithRoundedRect:segment xRadius:4
                                       yRadius:4] fill];
      NSDictionary *attributes = isSelected ? _segmentSelected : _segment;
      NSString *label = labels[index];
      NSSize size = [label sizeWithAttributes:attributes];
      AUBDrawText(label, NSMidX(segment) - size.width / 2,
                  NSMidY(segment) - size.height / 2, attributes);
      [self addAction:AUBActionAppearance argument:modes[index] rect:segment];
    }
  }
  y += 34;
  return y;
}

- (CGFloat)provider:(AUBProviderKind)kind y:(CGFloat)y draw:(bool)draw {
  const AUBProviderState *provider = AUBStateForKind(_snapshot, kind);
  if (!AUBProviderVisible(provider))
    return y;

  NSString *name = AUBProviderName(kind);
  NSString *title = provider->plan[0] == '\0'
                        ? name
                        : [NSString stringWithFormat:@"%@ · %@", name,
                                                     AUBString(provider->plan)];
  if (draw)
    AUBDrawText(title, AUBMargin, y, _subheadlineBold);
  y += 24;

  if (provider->status == AUBProviderStatusFailed) {
    CGFloat height = AUBDrawWrapped(
        AUBString(provider->error),
        NSMakeRect(AUBMargin, y, AUBContentWidth, 0), _warning, draw);
    return y + height + 16;
  }

  for (uint8_t index = 0; index < provider->windowCount; index++) {
    const AUBWindow *window = &provider->windows[index];
    bool headline = strcmp(window->id, AUBWindowIDSession) == 0 ||
                    strcmp(window->id, AUBWindowIDWeekly) == 0;
    if (!headline && window->percent < 1)
      continue;

    if (draw) {
      AUBDrawText(AUBString(window->label), AUBMargin, y, _subheadlineBold);
      AUBDrawRight(AUBResetText(window), AUBWidth - AUBMargin, y, _caption);
      [self drawProgressAtY:y + 20 percent:window->percent];
      AUBDrawText([NSString stringWithFormat:@"%.0f%% used", window->percent],
                  AUBMargin, y + 30, _caption);
    }
    y += 52;
  }

  if (provider->budget.present && provider->budget.hasSpent &&
      provider->budget.hasLimit && provider->budget.limitMinor > 0) {
    const AUBBudgetReading *budget = &provider->budget;
    NSString *budgetTitle = budget->unit == AUBBudgetUnitCredits
                                ? @"Monthly credit limit"
                                : (budget->scope == AUBBudgetScopeOrganization
                                       ? @"Monthly budget (whole org)"
                                       : @"Monthly budget");
    double percent =
        100.0 * (double)budget->spentMinor / (double)budget->limitMinor;
    if (draw) {
      AUBDrawText(budgetTitle, AUBMargin, y, _subheadlineBold);
      NSString *manage = @"Manage →";
      AUBDrawRight(manage, AUBWidth - AUBMargin, y, _subheadlineBold);
      CGFloat width = ceil([manage sizeWithAttributes:_subheadlineBold].width);
      [self addAction:AUBActionManageProvider
             argument:kind
                 rect:NSMakeRect(AUBWidth - AUBMargin - width - 4, y - 2,
                                 width + 8, 20)];
      [self drawProgressAtY:y + 20 percent:percent];

      int64_t remaining = MAX(0, budget->limitMinor - budget->spentMinor);
      NSString *detail =
          [NSString stringWithFormat:@"%@ of %@ · %@ left · %.0f%%",
                                     AUBAmount(budget->spentMinor, budget),
                                     AUBAmount(budget->limitMinor, budget),
                                     AUBAmount(remaining, budget), percent];
      AUBDrawText(detail, AUBMargin, y + 30, _caption);
    }
    y += 52;

    if (budget->overridden) {
      if (draw) {
        AUBDrawText(
            @"Limit set by you in Settings, not reported by the provider.",
            AUBMargin, y, _caption2);
      }
      y += 18;
    }

    NSString *badge = nil;
    if (budget->state == AUBBudgetStateLimitReached) {
      badge = @"⚠ Monthly spend limit reached";
    } else if (budget->state == AUBBudgetStateOutOfCredits) {
      badge = @"⚠ Prepaid credits exhausted";
    } else if (budget->state == AUBBudgetStateDisabled) {
      badge = [@"⚠ " stringByAppendingString:AUBString(budget->disabledReason)];
    }
    if (badge != nil) {
      if (draw) {
        AUBDrawText(badge, AUBMargin, y, _warning2);
      }
      y += 18;
    }
  } else if (provider->hasCreditBalance) {
    AUBBudgetReading credits = {
        .unit = AUBBudgetUnitCredits,
        .exponent = provider->creditExponent,
    };
    if (draw) {
      NSString *text = [NSString
          stringWithFormat:@"%@ available",
                           AUBAmount(provider->creditBalanceMinor, &credits)];
      AUBDrawText(text, AUBMargin, y, _caption);
    }
    y += 20;
  } else if (provider->budget.present) {
    NSString *message =
        @"No monthly limit reported. Set one in Settings to see percent used.";
    CGFloat height = AUBDrawWrapped(
        message, NSMakeRect(AUBMargin, y, AUBContentWidth, 0), _caption2, draw);
    y += height + 8;
  }

  if (provider->unrecognized[0] != '\0') {
    NSString *message = [@"⚠ Unrecognized from API: "
        stringByAppendingString:AUBString(provider->unrecognized)];
    CGFloat height = AUBDrawWrapped(
        message, NSMakeRect(AUBMargin, y, AUBContentWidth, 0), _warning2, draw);
    y += height + 8;
  }
  return y + 10;
}

- (void)drawProgressAtY:(CGFloat)y percent:(double)percent {
  CGFloat fraction = MAX(0, MIN(1, percent / 100));
  NSRect background = NSMakeRect(AUBMargin, y, AUBContentWidth, 6);
  [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:background xRadius:3
                                   yRadius:3] fill];
  if (fraction <= 0)
    return;
  NSRect fill = background;
  fill.size.width *= fraction;
  [AUBTierColor(percent) setFill];
  [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:3 yRadius:3] fill];
}

- (void)addAction:(AUBAction)action rect:(NSRect)rect {
  [self addAction:action argument:0 rect:rect];
}

- (void)addAction:(AUBAction)action
         argument:(uint8_t)argument
             rect:(NSRect)rect {
  if (_actionCount >= AUBMaxActions)
    return;
  _actions[_actionCount++] =
      (AUBActionRect){.rect = rect, .action = action, .argument = argument};
}

- (bool)isEditingBudgetFor:(AUBProviderKind)kind {
  return _editingBudget && _budgetEditorKind == kind;
}

- (void)beginBudgetEditing:(AUBProviderKind)kind {
  _editingBudget = true;
  _budgetEditorKind = kind;
  const AUBBudgetReading *budget = &AUBStateForKind(_snapshot, kind)->budget;
  if (budget->overridden) {
    double value =
        (double)budget->limitMinor / (double)AUBScale(budget->exponent);
    snprintf(_budgetInput, sizeof(_budgetInput), "%.*f", budget->exponent,
             value);
  } else {
    _budgetInput[0] = '\0';
  }
  [self.window makeFirstResponder:self];
  [self setNeedsDisplay:YES];
}

- (void)commitBudgetEditingFor:(AUBProviderKind)kind {
  if (![self isEditingBudgetFor:kind])
    [self beginBudgetEditing:kind];
  char *end = NULL;
  double value = strtod(_budgetInput, &end);
  const AUBBudgetReading *budget = &AUBStateForKind(_snapshot, kind)->budget;
  int64_t scale = AUBScale(budget->exponent);
  if (_budgetInput[0] == '\0' || end == _budgetInput || *end != '\0' ||
      !isfinite(value) || value <= 0 ||
      value > (double)LLONG_MAX / (double)scale) {
    NSBeep();
    return;
  }
  [_delegate usagePanelView:self
      setBudgetOverrideMinor:llround(value * (double)scale)
                 forProvider:kind];
  _editingBudget = false;
  _budgetInput[0] = '\0';
  [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  if (point.y < AUBArrowHeight)
    return;
  // Action rects only exist after a draw, and they live in unscrolled
  // coordinates, so settle any pending redraw before matching against them.
  [self displayIfNeeded];
  point.y += [self snappedScrollOffset];
  for (uint8_t index = 0; index < _actionCount; index++) {
    if (!NSPointInRect(point, _actions[index].rect))
      continue;
    uint8_t argument = _actions[index].argument;
    switch (_actions[index].action) {
    case AUBActionRefresh:
      [_delegate usagePanelViewDidRequestRefresh:self];
      return;
    case AUBActionToggleSettings:
      _showingSettings = !_showingSettings;
      // Invalidate before the delegate resizes: it asks for the content height,
      // which would otherwise still be the measurement for the old state.
      [self reload];
      [_delegate usagePanelViewDidChangeContentHeight:self];
      return;
    case AUBActionToggleLogin: {
      BOOL enabled = ![_delegate usagePanelViewOpenAtLogin:self];
      [_delegate usagePanelView:self setOpenAtLogin:enabled];
      [self reload];
      return;
    }
    // Enabling the shortcut while ⌘U is taken adds a warning row, so the panel
    // has to grow with it.
    case AUBActionToggleShortcut: {
      BOOL enabled = ![_delegate usagePanelViewShortcutEnabled:self];
      [_delegate usagePanelView:self setShortcutEnabled:enabled];
      [self reload];
      [_delegate usagePanelViewDidChangeContentHeight:self];
      return;
    }
    case AUBActionToggleStatusComponent:
      [_delegate usagePanelView:self toggleStatusComponentAtIndex:argument];
      return;
    case AUBActionManageProvider:
      [NSWorkspace.sharedWorkspace
          openURL:[NSURL URLWithString:AUBManageURL(argument)]];
      return;
    case AUBActionEditBudget:
      [self beginBudgetEditing:argument];
      return;
    case AUBActionSetBudget:
      [self commitBudgetEditingFor:argument];
      return;
    case AUBActionClearBudget:
      _editingBudget = false;
      [_delegate usagePanelView:self clearBudgetOverrideForProvider:argument];
      return;
    case AUBActionAppearance:
      [_delegate usagePanelView:self setAppearanceMode:argument];
      return;
    }
  }
}

- (void)keyDown:(NSEvent *)event {
  if (!_editingBudget) {
    [super keyDown:event];
    return;
  }
  if (event.keyCode == 36 || event.keyCode == 76) {
    [self commitBudgetEditingFor:_budgetEditorKind];
    return;
  }
  if (event.keyCode == 51) {
    size_t length = strlen(_budgetInput);
    if (length > 0)
      _budgetInput[length - 1] = '\0';
    [self setNeedsDisplay:YES];
    return;
  }

  NSString *characters = event.charactersIgnoringModifiers;
  if (characters.length != 1)
    return;
  unichar character = [characters characterAtIndex:0];
  bool digit = character >= '0' && character <= '9';
  bool decimal = character == '.' && strchr(_budgetInput, '.') == NULL;
  size_t length = strlen(_budgetInput);
  if ((!digit && !decimal) || length + 1 >= sizeof(_budgetInput)) {
    NSBeep();
    return;
  }
  _budgetInput[length] = (char)character;
  _budgetInput[length + 1] = '\0';
  [self setNeedsDisplay:YES];
}

- (void)scrollWheel:(NSEvent *)event {
  CGFloat delta = event.scrollingDeltaY;
  if (!event.hasPreciseScrollingDeltas)
    delta *= AUBScrollLineHeight;
  // A positive delta means "show earlier content", and a larger offset moves
  // content up, so the two run opposite each other.
  CGFloat offset =
      MAX(0, MIN([self maximumScrollOffset], _scrollOffset - delta));
  // Skips the redraw for the rest of a momentum phase once pinned at a limit.
  if (offset == _scrollOffset)
    return;
  _scrollOffset = offset;
  [self setNeedsDisplay:YES];
}

@end
