#import "UsagePanelView.h"

#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef NS_ENUM(uint8_t, AUBAction) {
  AUBActionRefresh,
  AUBActionToggleSettings,
  AUBActionManageClaude,
  AUBActionManageCodex,
  AUBActionToggleLogin,
  AUBActionToggleShortcut,
  AUBActionEditClaudeBudget,
  AUBActionSetClaudeBudget,
  AUBActionClearClaudeBudget,
  AUBActionEditCodexBudget,
  AUBActionSetCodexBudget,
  AUBActionClearCodexBudget,
  AUBActionToggleStatusComponent,
  AUBActionAppearanceSystem,
  AUBActionAppearanceDark,
  AUBActionAppearanceLight,
};

typedef NS_ENUM(uint8_t, AUBBudgetEditor) {
  AUBBudgetEditorClosed,
  AUBBudgetEditorClaude,
  AUBBudgetEditorCodex,
};

typedef struct {
  NSRect rect;
  AUBAction action;
  uint8_t argument;
} AUBActionRect;

enum { AUBMaxActions = 32 };

static const CGFloat AUBWidth = 360;
static const CGFloat AUBMargin = 16;
static const CGFloat AUBArrowHeight = 10;
static const CGFloat AUBContentWidth = AUBWidth - 2 * AUBMargin;

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

static void AUBDrawCheckbox(bool enabled, CGFloat x, CGFloat y) {
  NSRect box = NSMakeRect(x, y, 12, 12);
  [NSColor.tertiaryLabelColor setStroke];
  [[NSBezierPath bezierPathWithRoundedRect:box xRadius:2 yRadius:2] stroke];
  if (!enabled)
    return;
  [NSColor.controlAccentColor setFill];
  [[NSBezierPath bezierPathWithRoundedRect:box xRadius:2 yRadius:2] fill];
  NSDictionary *check =
      AUBAttributes(9, NSFontWeightSemibold, NSColor.whiteColor);
  AUBDrawText(@"✓", x + 2, y - 1, check);
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

static NSString *AUBResetText(const AUBWindow *window) {
  if (!window->hasReset)
    return @"";
  time_t seconds = (time_t)window->resetsAt;
  struct tm local = {0};
  localtime_r(&seconds, &local);
  char buffer[64];
  if (strcmp(window->id, "session") == 0) {
    strftime(buffer, sizeof(buffer), "Resets at %-I:%M %p", &local);
  } else {
    strftime(buffer, sizeof(buffer), "Resets on %-d %b at %-I:%M %p", &local);
  }
  return AUBString(buffer);
}

static NSString *AUBUpdatedText(double epoch) {
  time_t seconds = (time_t)epoch;
  struct tm local = {0};
  localtime_r(&seconds, &local);
  char buffer[64];
  strftime(buffer, sizeof(buffer), "Last updated: %-I:%M %p", &local);
  return AUBString(buffer);
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
  int64_t scale = 1;
  for (uint8_t index = 0; index < budget->exponent; index++)
    scale *= 10;
  int64_t whole = minor / scale;
  int64_t fraction = llabs(minor % scale);

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
                                    fraction];
}

@interface AUBUsagePanelView () {
  const AUBSnapshot *_snapshot;
  __weak id<AUBUsagePanelViewDelegate> _delegate;
  AUBActionRect _actions[AUBMaxActions];
  uint8_t _actionCount;
  CGFloat _scrollOffset;
  CGFloat _measuredHeight;
  bool _showingSettings;
  AUBBudgetEditor _budgetEditor;
  char _budgetInput[24];
  NSDictionary<NSAttributedStringKey, id> *_headline;
  NSDictionary<NSAttributedStringKey, id> *_subheadline;
  NSDictionary<NSAttributedStringKey, id> *_subheadlineBold;
  NSDictionary<NSAttributedStringKey, id> *_caption;
  NSDictionary<NSAttributedStringKey, id> *_caption2;
  NSDictionary<NSAttributedStringKey, id> *_warning;
  NSDictionary<NSAttributedStringKey, id> *_warning2;
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
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (CGFloat)contentHeight {
  [self layoutAndDraw:NO];
  return _measuredHeight;
}

- (void)reload {
  CGFloat maximum = MAX(0, [self contentHeight] - self.bounds.size.height);
  _scrollOffset = MIN(_scrollOffset, maximum);
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  [self layoutAndDraw:YES];
}

- (void)layoutAndDraw:(bool)draw {
  if (draw)
    _actionCount = 0;
  if (draw) {
    [NSColor.clearColor setFill];
    NSRectFill(self.bounds);
    [NSColor.windowBackgroundColor setFill];
    NSRect body = NSMakeRect(0, AUBArrowHeight, AUBWidth,
                             self.bounds.size.height - AUBArrowHeight);
    [[NSBezierPath bezierPathWithRoundedRect:body xRadius:11 yRadius:11] fill];
    NSBezierPath *arrow = [NSBezierPath bezierPath];
    [arrow moveToPoint:NSMakePoint(AUBWidth / 2 - 10, AUBArrowHeight)];
    [arrow lineToPoint:NSMakePoint(AUBWidth / 2, 0)];
    [arrow lineToPoint:NSMakePoint(AUBWidth / 2 + 10, AUBArrowHeight)];
    [arrow closePath];
    [arrow fill];
  }
  CGFloat y = AUBMargin + AUBArrowHeight - _scrollOffset;

  if (draw)
    AUBDrawText(@"Agent Usage", AUBMargin, y, _headline);
  y += 32;

  bool hasProvider = _snapshot->claude.status != AUBProviderStatusSignedOut &&
                     _snapshot->claude.status != AUBProviderStatusPending;
  hasProvider =
      hasProvider || (_snapshot->codex.status != AUBProviderStatusSignedOut &&
                      _snapshot->codex.status != AUBProviderStatusPending);

  if (!hasProvider) {
    if (draw)
      AUBDrawText(@"👋 No providers signed in", AUBMargin, y, _subheadline);
    y += 22;
    if (draw) {
      AUBDrawText(@"Run `claude login` to track Claude usage.", AUBMargin, y,
                  _caption);
    }
    y += 18;
    if (draw)
      AUBDrawText(@"Run `codex login` to track Codex usage.", AUBMargin, y,
                  _caption);
    y += 18;
  } else {
    y = [self provider:&_snapshot->claude
                      name:@"Claude"
                         y:y
                      draw:draw
           titleAttributes:_subheadlineBold
         captionAttributes:_caption
        caption2Attributes:_caption2];
    y = [self provider:&_snapshot->codex
                      name:@"Codex"
                         y:y
                      draw:draw
           titleAttributes:_subheadlineBold
         captionAttributes:_caption
        caption2Attributes:_caption2];
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
    CGFloat panelTop = y;
    uint8_t budgetCandidateCount = AUBBudgetCandidateCount(_snapshot);
    bool shortcutConflict = [_delegate usagePanelViewShortcutConflicted:self];
    CGFloat budgetSettingsHeight =
        34 + (budgetCandidateCount == 0 ? 20 : 34 * budgetCandidateCount);
    if (draw) {
      [[NSColor.secondaryLabelColor colorWithAlphaComponent:0.08] setFill];
      NSBezierPath *panel = [NSBezierPath
          bezierPathWithRoundedRect:NSMakeRect(
                                        AUBMargin, panelTop, AUBContentWidth,
                                        234 + (shortcutConflict ? 18 : 0) +
                                            budgetSettingsHeight +
                                            24 *
                                                _snapshot->statusComponentCount)
                            xRadius:6
                            yRadius:6];
      [panel fill];
    }
    y += 10;
    if (draw) {
      AUBDrawCheckbox([_delegate usagePanelViewOpenAtLogin:self],
                      AUBMargin + 10, y + 1);
      AUBDrawText(@"Open at Login", AUBMargin + 28, y, _caption);
      AUBDrawText(@"Launch automatically when you log in", AUBMargin + 28,
                  y + 17, _caption2);
      [self
          addAction:AUBActionToggleLogin
               rect:NSMakeRect(AUBMargin + 6, y - 3, AUBContentWidth - 12, 38)];
    }
    y += 48;
    if (draw) {
      AUBDrawCheckbox([_delegate usagePanelViewShortcutEnabled:self],
                      AUBMargin + 10, y + 1);
      AUBDrawText(@"Keyboard Shortcut (⌘U)", AUBMargin + 28, y, _caption);
      AUBDrawText(@"Toggle this popup from anywhere", AUBMargin + 28, y + 17,
                  _caption2);
      [self
          addAction:AUBActionToggleShortcut
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
        AUBDrawText(@"Both providers report their own limits.", AUBMargin + 10,
                    y, _caption2);
      }
      y += 20;
    } else {
      const AUBProviderState *providers[] = {&_snapshot->claude,
                                             &_snapshot->codex};
      NSString *names[] = {@"Claude", @"Codex"};
      const AUBBudgetEditor editors[] = {
          AUBBudgetEditorClaude,
          AUBBudgetEditorCodex,
      };
      const AUBAction editActions[] = {
          AUBActionEditClaudeBudget,
          AUBActionEditCodexBudget,
      };
      const AUBAction setActions[] = {
          AUBActionSetClaudeBudget,
          AUBActionSetCodexBudget,
      };
      const AUBAction clearActions[] = {
          AUBActionClearClaudeBudget,
          AUBActionClearCodexBudget,
      };
      for (uint8_t index = 0; index < 2; index++) {
        const AUBProviderState *provider = providers[index];
        if (!AUBCanOverrideBudget(provider))
          continue;
        NSRect field = NSMakeRect(AUBMargin + 70, y - 3, 96, 22);
        if (draw) {
          AUBDrawText(names[index], AUBMargin + 10, y, _caption2);
          NSColor *border = _budgetEditor == editors[index]
                                ? NSColor.controlAccentColor
                                : NSColor.tertiaryLabelColor;
          [border setStroke];
          [[NSBezierPath bezierPathWithRoundedRect:field xRadius:4
                                           yRadius:4] stroke];
          NSString *input = @"";
          if (_budgetEditor == editors[index]) {
            input = AUBString(_budgetInput);
          } else if (provider->budget.overridden) {
            double value = (double)provider->budget.limitMinor /
                           (double)AUBScale(provider->budget.exponent);
            input = [NSString
                stringWithFormat:@"%.*f", provider->budget.exponent, value];
          }
          NSDictionary *inputAttributes =
              input.length == 0 ? _caption2 : _caption;
          AUBDrawText(input.length == 0 ? @"e.g. 1000" : input,
                      NSMinX(field) + 6, y, inputAttributes);
          [self addAction:editActions[index] rect:field];

          NSRect set = NSMakeRect(NSMaxX(field) + 8, y - 3, 34, 22);
          AUBDrawText(@"Set", NSMinX(set) + 6, y, _caption);
          [self addAction:setActions[index] rect:set];
          if (provider->budget.overridden) {
            NSRect clear = NSMakeRect(NSMaxX(set) + 6, y - 3, 44, 22);
            AUBDrawText(@"Clear", NSMinX(clear) + 4, y, _caption);
            [self addAction:clearActions[index] rect:clear];
          }
        }
        y += 34;
      }
    }

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
        [self addAction:AUBActionToggleStatusComponent
               argument:index
                   rect:NSMakeRect(AUBMargin + 6, y - 3, AUBContentWidth - 12,
                                   22)];
      }
      y += 24;
    }

    if (draw) {
      [NSColor.separatorColor setFill];
      NSRectFill(NSMakeRect(AUBMargin + 8, y, AUBContentWidth - 16, 1));
    }
    y += 14;
    if (draw)
      AUBDrawText(@"Appearance", AUBMargin + 10, y, _caption);
    y += 22;
    CGFloat segmentWidth = (AUBContentWidth - 20) / 3;
    AUBAppearanceMode selected = [_delegate usagePanelViewAppearanceMode:self];
    NSString *const labels[] = {@"System", @"Dark", @"Light"};
    const AUBAction actions[] = {
        AUBActionAppearanceSystem,
        AUBActionAppearanceDark,
        AUBActionAppearanceLight,
    };
    for (uint8_t index = 0; index < 3; index++) {
      NSRect segment = NSMakeRect(AUBMargin + 10 + segmentWidth * index, y,
                                  segmentWidth, 24);
      if (draw) {
        NSColor *fill = selected == index
                            ? NSColor.controlAccentColor
                            : [NSColor.labelColor colorWithAlphaComponent:0.08];
        [fill setFill];
        [[NSBezierPath bezierPathWithRoundedRect:segment xRadius:4
                                         yRadius:4] fill];
        NSDictionary *attributes = AUBAttributes(
            NSFont.smallSystemFontSize - 1, NSFontWeightRegular,
            selected == index ? NSColor.whiteColor : NSColor.labelColor);
        NSString *label = labels[index];
        NSSize size = [label sizeWithAttributes:attributes];
        AUBDrawText(label, NSMidX(segment) - size.width / 2,
                    NSMidY(segment) - size.height / 2, attributes);
        [self addAction:actions[index] rect:segment];
      }
    }
    y += 34;
  }

  _measuredHeight = y + AUBMargin + _scrollOffset;
}

- (CGFloat)provider:(const AUBProviderState *)provider
                  name:(NSString *)name
                     y:(CGFloat)y
                  draw:(bool)draw
       titleAttributes:(NSDictionary *)titleAttributes
     captionAttributes:(NSDictionary *)captionAttributes
    caption2Attributes:(NSDictionary *)caption2Attributes {
  if (provider->status == AUBProviderStatusSignedOut ||
      provider->status == AUBProviderStatusPending) {
    return y;
  }

  NSString *title = provider->plan[0] == '\0'
                        ? name
                        : [NSString stringWithFormat:@"%@ · %@", name,
                                                     AUBString(provider->plan)];
  if (draw)
    AUBDrawText(title, AUBMargin, y, titleAttributes);
  y += 24;

  if (provider->status == AUBProviderStatusFailed) {
    CGFloat height = AUBDrawWrapped(
        AUBString(provider->error),
        NSMakeRect(AUBMargin, y, AUBContentWidth, 0), _warning, draw);
    return y + height + 16;
  }

  for (uint8_t index = 0; index < provider->windowCount; index++) {
    const AUBWindow *window = &provider->windows[index];
    bool headline =
        strcmp(window->id, "session") == 0 || strcmp(window->id, "weekly") == 0;
    if (!headline && window->percent < 1)
      continue;

    if (draw) {
      AUBDrawText(AUBString(window->label), AUBMargin, y, titleAttributes);
      AUBDrawRight(AUBResetText(window), AUBWidth - AUBMargin, y,
                   captionAttributes);
      [self drawProgressAtY:y + 20 percent:window->percent];
      AUBDrawText([NSString stringWithFormat:@"%.0f%% used", window->percent],
                  AUBMargin, y + 30, captionAttributes);
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
      AUBDrawText(budgetTitle, AUBMargin, y, titleAttributes);
      NSString *manage = @"Manage →";
      AUBDrawRight(manage, AUBWidth - AUBMargin, y, titleAttributes);
      CGFloat width = ceil([manage sizeWithAttributes:titleAttributes].width);
      AUBAction action = [name isEqualToString:@"Claude"]
                             ? AUBActionManageClaude
                             : AUBActionManageCodex;
      [self addAction:action
                 rect:NSMakeRect(AUBWidth - AUBMargin - width - 4, y - 2,
                                 width + 8, 20)];
      [self drawProgressAtY:y + 20 percent:percent];

      int64_t remaining = MAX(0, budget->limitMinor - budget->spentMinor);
      NSString *detail =
          [NSString stringWithFormat:@"%@ of %@ · %@ left · %.0f%%",
                                     AUBAmount(budget->spentMinor, budget),
                                     AUBAmount(budget->limitMinor, budget),
                                     AUBAmount(remaining, budget), percent];
      AUBDrawText(detail, AUBMargin, y + 30, captionAttributes);
    }
    y += 52;

    if (budget->overridden) {
      if (draw) {
        AUBDrawText(
            @"Limit set by you in Settings, not reported by the provider.",
            AUBMargin, y, caption2Attributes);
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
      AUBDrawText(text, AUBMargin, y, captionAttributes);
    }
    y += 20;
  } else if (provider->budget.present) {
    NSString *message =
        @"No monthly limit reported. Set one in Settings to see percent used.";
    CGFloat height =
        AUBDrawWrapped(message, NSMakeRect(AUBMargin, y, AUBContentWidth, 0),
                       caption2Attributes, draw);
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

- (void)beginBudgetEditing:(AUBBudgetEditor)editor {
  _budgetEditor = editor;
  const AUBBudgetReading *budget = editor == AUBBudgetEditorClaude
                                       ? &_snapshot->claude.budget
                                       : &_snapshot->codex.budget;
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

- (void)commitBudgetEditor:(AUBBudgetEditor)editor {
  if (_budgetEditor != editor)
    [self beginBudgetEditing:editor];
  char *end = NULL;
  double value = strtod(_budgetInput, &end);
  const AUBBudgetReading *budget = editor == AUBBudgetEditorClaude
                                       ? &_snapshot->claude.budget
                                       : &_snapshot->codex.budget;
  int64_t scale = AUBScale(budget->exponent);
  if (_budgetInput[0] == '\0' || end == _budgetInput || *end != '\0' ||
      !isfinite(value) || value <= 0 ||
      value > (double)LLONG_MAX / (double)scale) {
    NSBeep();
    return;
  }
  int64_t minor = llround(value * (double)scale);
  AUBProviderKind provider = editor == AUBBudgetEditorClaude
                                 ? AUBProviderKindClaude
                                 : AUBProviderKindCodex;
  [_delegate usagePanelView:self
      setBudgetOverrideMinor:minor
                 forProvider:provider];
  _budgetEditor = AUBBudgetEditorClosed;
  _budgetInput[0] = '\0';
  [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  for (uint8_t index = 0; index < _actionCount; index++) {
    if (!NSPointInRect(point, _actions[index].rect))
      continue;
    switch (_actions[index].action) {
    case AUBActionRefresh:
      [_delegate usagePanelViewDidRequestRefresh:self];
      return;
    case AUBActionToggleSettings:
      _showingSettings = !_showingSettings;
      [_delegate usagePanelViewDidChangeContentHeight:self];
      [self reload];
      return;
    case AUBActionManageClaude:
      [NSWorkspace.sharedWorkspace
          openURL:[NSURL URLWithString:@"https://claude.ai/settings/usage"]];
      return;
    case AUBActionManageCodex:
      [NSWorkspace.sharedWorkspace
          openURL:[NSURL URLWithString:
                             @"https://chatgpt.com/codex/settings/usage"]];
      return;
    case AUBActionToggleLogin: {
      BOOL enabled = ![_delegate usagePanelViewOpenAtLogin:self];
      [_delegate usagePanelView:self setOpenAtLogin:enabled];
      [self reload];
      return;
    }
    case AUBActionToggleShortcut: {
      BOOL enabled = ![_delegate usagePanelViewShortcutEnabled:self];
      [_delegate usagePanelView:self setShortcutEnabled:enabled];
      [self reload];
      return;
    }
    case AUBActionEditClaudeBudget:
      [self beginBudgetEditing:AUBBudgetEditorClaude];
      return;
    case AUBActionSetClaudeBudget:
      [self commitBudgetEditor:AUBBudgetEditorClaude];
      return;
    case AUBActionClearClaudeBudget:
      _budgetEditor = AUBBudgetEditorClosed;
      [_delegate usagePanelView:self
          clearBudgetOverrideForProvider:AUBProviderKindClaude];
      return;
    case AUBActionEditCodexBudget:
      [self beginBudgetEditing:AUBBudgetEditorCodex];
      return;
    case AUBActionSetCodexBudget:
      [self commitBudgetEditor:AUBBudgetEditorCodex];
      return;
    case AUBActionClearCodexBudget:
      _budgetEditor = AUBBudgetEditorClosed;
      [_delegate usagePanelView:self
          clearBudgetOverrideForProvider:AUBProviderKindCodex];
      return;
    case AUBActionToggleStatusComponent:
      [_delegate usagePanelView:self
          toggleStatusComponentAtIndex:_actions[index].argument];
      return;
    case AUBActionAppearanceSystem:
      [_delegate usagePanelView:self setAppearanceMode:AUBAppearanceModeSystem];
      return;
    case AUBActionAppearanceDark:
      [_delegate usagePanelView:self setAppearanceMode:AUBAppearanceModeDark];
      return;
    case AUBActionAppearanceLight:
      [_delegate usagePanelView:self setAppearanceMode:AUBAppearanceModeLight];
      return;
    }
  }
}

- (void)keyDown:(NSEvent *)event {
  if (_budgetEditor == AUBBudgetEditorClosed) {
    [super keyDown:event];
    return;
  }
  if (event.keyCode == 36 || event.keyCode == 76) {
    [self commitBudgetEditor:_budgetEditor];
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
  CGFloat maximum = MAX(0, [self contentHeight] - self.bounds.size.height);
  _scrollOffset = MAX(0, MIN(maximum, _scrollOffset + event.scrollingDeltaY));
  [self setNeedsDisplay:YES];
}

@end
