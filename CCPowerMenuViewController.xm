#import "CCPowerMenuViewController.h"

// Declared by hand so no IOKit headers are needed; passing MACH_PORT_NULL as the port means the
// default one, which also avoids depending on the kIOMasterPortDefault symbol. This file is
// compiled as Objective-C++, so the declarations need C linkage to match the library.
#ifdef __cplusplus
extern "C" {
#endif
CFMutableDictionaryRef IOServiceMatching(const char *name);
mach_port_t IOServiceGetMatchingService(mach_port_t masterPort, CFDictionaryRef matching);
kern_return_t IORegistryEntryCreateCFProperties(mach_port_t entry, CFMutableDictionaryRef *properties, CFAllocatorRef allocator, uint32_t options);
kern_return_t IOObjectRelease(mach_port_t object);
#ifdef __cplusplus
}
#endif

static NSDictionary *CCPMBatteryProperties(void) {
    CFMutableDictionaryRef matching = IOServiceMatching("AppleSmartBattery");
    if (!matching) {
        return nil;
    }
    // IOServiceGetMatchingService consumes the matching dictionary.
    mach_port_t service = IOServiceGetMatchingService(MACH_PORT_NULL, matching);
    if (!service) {
        return nil;
    }

    CFMutableDictionaryRef properties = NULL;
    NSDictionary *result = nil;
    if (IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS && properties) {
        result = (__bridge_transfer NSDictionary *)properties;
    }
    IOObjectRelease(service);
    return result;
}

// Decimal GB throughout, so 256GB of storage reads as 256 rather than df's 1024-based 238.
static const double kBytesPerGigabyte = 1e9;

static NSString *CCPMUptimeText(void) {
    struct timeval boottime;
    size_t size = sizeof(boottime);
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};
    if (sysctl(mib, 2, &boottime, &size, NULL, 0) != 0 || boottime.tv_sec <= 0) {
        return nil;
    }

    NSTimeInterval uptime = [[NSDate date] timeIntervalSince1970] - (NSTimeInterval)boottime.tv_sec;
    if (uptime < 0.0) {
        uptime = 0.0;
    }
    long totalMinutes = (long)(uptime / 60.0);
    return [NSString stringWithFormat:@"%ld天%ld小时%ld分",
        totalMinutes / (24 * 60), (totalMinutes / 60) % 24, totalMinutes % 60];
}

@implementation CCPowerMenuViewController

// The stock header just said "Scroll down for more options". Show what CCPower shows there
// instead — battery, uptime, storage and memory — refreshed every time the module appears.
// Each entry is an SF Symbol name paired with its line of text. Symbols rather than emoji because
// this panel renders inside a vibrancy effect, which flattens everything drawn into a luminance
// mask — emoji come out as grey silhouettes, while template symbols are what the material expects
// (it is how the row glyphs are drawn).
- (NSArray *)deviceStatusEntries {
    NSMutableArray *entries = [NSMutableArray array];

    NSDictionary *battery = CCPMBatteryProperties();
    NSNumber *designCapacity = battery[@"DesignCapacity"];
    NSNumber *currentCapacity = battery[@"NominalChargeCapacity"] ?: battery[@"AppleRawMaxCapacity"];
    NSNumber *cycleCount = battery[@"CycleCount"];
    if (designCapacity.doubleValue > 0.0 && currentCapacity) {
        [entries addObject:@[@"battery.100", [NSString stringWithFormat:@"[电池] 健康度:%.2f%%,循环次数:%@",
            currentCapacity.doubleValue / designCapacity.doubleValue * 100.0,
            cycleCount ?: @"—"]]];
    }

    // Two different questions, so both get answered. 剩余 is statfs' f_bavail, the same free blocks
    // df reports. 可用 is what iOS reckons it could hand out after purging caches, offloadable apps
    // and evictable iCloud files, which runs tens of GB higher.
    struct statfs storage;
    if (statfs([NSHomeDirectory() fileSystemRepresentation], &storage) == 0) {
        double totalStorage = (double)((unsigned long long)storage.f_blocks * storage.f_bsize);
        double freeStorage = (double)((unsigned long long)storage.f_bavail * storage.f_bsize);

        NSNumber *purgeableAware = [[NSURL fileURLWithPath:NSHomeDirectory()]
            resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey] error:NULL][NSURLVolumeAvailableCapacityForImportantUsageKey];
        double availableStorage = purgeableAware ? purgeableAware.doubleValue : freeStorage;

        [entries addObject:@[@"internaldrive", [NSString stringWithFormat:@"[存储] 总:%.1fG,剩余:%.1fG,可用:%.1fG",
            totalStorage / kBytesPerGigabyte,
            freeStorage / kBytesPerGigabyte,
            availableStorage / kBytesPerGigabyte]]];
    }

    double totalMemory = (double)[NSProcessInfo processInfo].physicalMemory;
    vm_statistics64_data_t vmStats;
    mach_msg_type_number_t vmCount = HOST_VM_INFO64_COUNT;
    if (totalMemory > 0.0 && host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vmStats, &vmCount) == KERN_SUCCESS) {
        // Free pages alone sit near zero on iOS by design, which would peg usage at ~97% forever.
        // Count the pages the kernel can reclaim on demand as available too. free_count already
        // includes speculative pages, so they are not added again.
        double availableMemory = (double)(((uint64_t)vmStats.free_count
            + vmStats.inactive_count
            + vmStats.purgeable_count) * vm_kernel_page_size);
        if (availableMemory > totalMemory) {
            availableMemory = totalMemory;
        }
        [entries addObject:@[@"memorychip", [NSString stringWithFormat:@"[运存] 总:%.1fG,可用:%.1fG,使用率:%.0f%%",
            totalMemory / kBytesPerGigabyte,
            availableMemory / kBytesPerGigabyte,
            (1.0 - availableMemory / totalMemory) * 100.0]]];
    }

    NSString *uptime = CCPMUptimeText();
    if (uptime) {
        [entries addObject:@[@"clock", [NSString stringWithFormat:@"[运行时间] %@", uptime]]];
    }

#if CCPM_DEBUG_HEADER
    // Temporary: the header geometry the last height query saw, so the first expansion after a
    // respring can be compared against every later one without attaching to SpringBoard.
    [entries addObject:@[@"ladybug", [NSString stringWithFormat:@"[调试] label=%@ f=%.0f sep=%.0f est=%.0f rep=%.0f",
        self.statusLabel ? @"Y" : @"N",
        self.statusLabel ? self.statusLabel.font.pointSize : 0.0,
        self.lastSeparatorY,
        self.lastEstimatedHeaderHeight,
        self.lastReportedHeight]]];
#endif

    return entries;
}
// Plain text form, used both as the module's subtitle and to measure the header.
- (NSString *)deviceStatusText {
    NSMutableArray *lines = [NSMutableArray array];
    for (NSArray *entry in [self deviceStatusEntries]) {
        [lines addObject:entry[1]];
    }
    return [lines componentsJoinedByString:@"\n"];
}
- (UIFont *)deviceStatusFont {
    return [UIFont systemFontOfSize:kHeaderTextFontSize];
}
- (NSParagraphStyle *)deviceStatusParagraphStyle {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = NSTextAlignmentLeft;
    style.firstLineHeadIndent = kHeaderTextIndent;
    style.headIndent = kHeaderTextIndent;
    style.lineSpacing = 0.0;
    style.paragraphSpacing = 0.0;
    return style;
}
- (NSAttributedString *)attributedDeviceStatusText {
    UIFont *font = [self deviceStatusFont];
    // White is asked for, but do not expect it to show: this label sits in a secondary-style
    // vibrancy view, which re-maps whatever is drawn to its own brightness. Measured on device —
    // white, grey and semibold all render the same dimness, while the row titles are bright because
    // they live in a label-style vibrancy view. Kept so the colour is right if it ever moves.
    NSDictionary *attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSParagraphStyleAttributeName: [self deviceStatusParagraphStyle],
    };

    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    for (NSArray *entry in [self deviceStatusEntries]) {
        if (result.length > 0) {
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:attributes]];
        }

        UIImage *symbol = [UIImage systemImageNamed:entry[0]];
        if (symbol) {
            NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
            attachment.image = [symbol imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            CGFloat side = font.pointSize;
            CGFloat aspect = symbol.size.height > 0.0 ? symbol.size.width / symbol.size.height : 1.0;
            attachment.bounds = CGRectMake(0.0, font.descender, side * aspect, side);
            [result appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:attributes]];
        }
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:entry[1] attributes:attributes]];
    }

    // Covers the attachments too, so the symbols match the text wherever it is drawn.
    [result addAttributes:@{
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSParagraphStyleAttributeName: [self deviceStatusParagraphStyle],
    } range:NSMakeRange(0, result.length)];
    return result;
}
// The header label is one centred line by default. Find it once by the text we just handed over —
// after this it carries an attributed string, so matching by text would no longer work.
- (UILabel *)findSubtitleLabelInView:(UIView *)view matchingText:(NSString *)text {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UILabel class]] && [[(UILabel *)subview text] isEqualToString:text]) {
            return (UILabel *)subview;
        }
        UILabel *found = [self findSubtitleLabelInView:subview matchingText:text];
        if (found) {
            return found;
        }
    }
    return nil;
}
- (void)applyStatusLabelStyling {
    UILabel *label = self.statusLabel;
    if (!label) {
        return;
    }
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentLeft;
    label.font = [self deviceStatusFont];
    // No adjustsFontSizeToFitWidth: on a multi-line label it lays out at full size and then scales
    // down, which is visible as the text jumping from large to small every time the menu opens.
    // The status block is written to fit at this size instead.
    label.adjustsFontSizeToFitWidth = NO;
    label.textColor = [UIColor whiteColor];
    label.attributedText = [self attributedDeviceStatusText];
}
// The module puts the plain subtitle back at its own font during layout, and the swap is visible
// as the text jumping from large to small. Put ours back as soon as that happens.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UILabel *label = self.statusLabel;
    if (label && fabs(label.font.pointSize - kHeaderTextFontSize) > 0.5) {
        [self applyStatusLabelStyling];
    }
}
- (void)updateDeviceStatusHeader {
    NSString *status = [self deviceStatusText];
    if (!status.length) {
        return;
    }
    self.subtitle = status;

    if (!self.statusLabel) {
        self.statusLabel = [self findSubtitleLabelInView:self.view matchingText:status];
    }
    if (!self.statusLabel) {
        return;
    }
    [self applyStatusLabelStyling];

    // Lay the header out now rather than leaving it to the expansion. Until this runs the header
    // still measures as the single-line subtitle it started as, and the first expansion sizes the
    // panel from those stale metrics — too short for the rows, with a gap above them. Every later
    // expansion looked right only because by then the header had been laid out once.
    [self layoutHeaderIfNeeded];
}
- (void)layoutHeaderIfNeeded {
    UIView *separator = nil;
    @try {
        separator = [self valueForKey:@"_headerSeparatorView"];
    } @catch (__unused NSException *exception) {
    }

    UIView *host = separator.superview ?: self.view;
    [self.statusLabel setNeedsLayout];
    [host setNeedsLayout];
    [host layoutIfNeeded];
}
// The panel is measured as part of this transition, so refresh the header before it is.
- (void)willTransitionToExpandedContentMode:(BOOL)expanded {
    if (expanded) {
        [self updateDeviceStatusHeader];
    }
    [super willTransitionToExpandedContentMode:expanded];
}
// Expanding re-runs the header layout, which puts the plain subtitle back; restore the symbols.
- (void)didTransitionToExpandedContentMode:(BOOL)expanded {
    [super didTransitionToExpandedContentMode:expanded];
    if (expanded) {
        [self updateDeviceStatusHeader];
        [self rememberLaidOutHeaderHeight];
    }
}
// Now that the module has expanded once, its header is where it really goes. Keep that number so
// the next first-expansion sizes the panel from a fact rather than an estimate.
- (void)rememberLaidOutHeaderHeight {
    UIView *separator = nil;
    @try {
        separator = [self valueForKey:@"_headerSeparatorView"];
    } @catch (__unused NSException *exception) {
    }
    if (![separator isKindOfClass:[UIView class]]) {
        return;
    }

    CGFloat laidOut = CGRectGetMinY(separator.frame);
    if (laidOut <= 0.0) {
        return;
    }
    CGFloat stored = [[preferences objectForKey:@"headerHeight" inDomain:domain] doubleValue];
    if (fabs(stored - laidOut) > 1.0) {
        [preferences setObject:@(laidOut) forKey:@"headerHeight" inDomain:domain];
    }
}
- (instancetype)initWithNibName:(NSString *)name bundle:(NSBundle *)bundle {
    self = [super initWithNibName:name bundle:bundle];
    if (self) {
        self.title = @"电源选项";
        self.subtitle = [self deviceStatusText];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadItems) name:@"ccpowermenu/ReloadItems" object:nil];
    }
    return self;
}
- (void)viewWillTransitionToSize:(struct CGSize )arg0 withTransitionCoordinator:(id)arg1 {
    self.spinnerIndicatorView.hidden = arg0.width > self.view.bounds.size.height;
    [self loadItems];
}
- (void)loadItems {
    [self updateDeviceStatusHeader];
    [self removeAllActions];
    // Settings only persists itemOrder once a row is dragged, so fall back to the same default
    // order the settings list starts from — otherwise the menu comes up empty.
    NSArray *itemOrder = [preferences objectForKey:@"itemOrder" inDomain:domain];
    if (!itemOrder.count) {
        itemOrder = @[@"respring", @"safemode", @"userspace", @"reboot", @"shutdown"];
    }
    for (NSString *identifier in itemOrder) {
        [self addActionForIdentifier:identifier];
    }
}
// How long a press has to be held before it counts as a long press rather than a tap.
static const NSTimeInterval kLongPressDuration = 0.5;
// Only used if the private height APIs ever disappear.
static const CGFloat kEstimatedMenuItemHeight = 60.0;
static const CGFloat kFallbackHeaderHeight = 89.0;
// Title row above the status block, plus the padding used when measuring that block. Kept tight:
// the header had far more slack around the status lines than they needed.
static const CGFloat kTitleAreaHeight = 44.0;
static const CGFloat kHeaderTextInset = 8.0;
static const CGFloat kHeaderTextFontSize = 13.0;
// One character of breathing room on the left, since the block is left aligned.
static const CGFloat kHeaderTextIndent = 8.0;
// However tall the menu wants to be, never let it swallow the whole screen.
static const CGFloat kMaximumExpandedHeightRatio = 0.9;

// The header is the title/subtitle block above the first row. Its height is wherever the header
// separator sits; that view is laid out before the module is ever expanded.
- (CGFloat)menuHeaderHeight {
    CGFloat height = kFallbackHeaderHeight;
    UIView *separator = nil;
    @try {
        separator = [self valueForKey:@"_headerSeparatorView"];
    } @catch (__unused NSException *exception) {
    }
    if ([separator isKindOfClass:[UIView class]] && CGRectGetMinY(separator.frame) > 0.0) {
        height = CGRectGetMinY(separator.frame);
    }
    self.lastSeparatorY = height;

    // The module's header is effectively a fixed height — it does not shrink to fit fewer lines —
    // and on the first expansion after a respring the separator has not been placed there yet, so
    // reading its frame under-reports and the last row gets cut off. A header height learned from
    // a previous expansion is the reliable floor; it is remembered per device in the same domain
    // as the rest of the settings.
    CGFloat learned = [[preferences objectForKey:@"headerHeight" inDomain:domain] doubleValue];
    height = MAX(height, learned);

    // If the class exposes its own header height, that beats both.
    for (NSString *name in @[@"_headerHeight", @"headerHeight", @"_headerViewHeight"]) {
        SEL selector = NSSelectorFromString(name);
        if ([self respondsToSelector:selector]) {
            CGFloat reported = ((CGFloat (*)(id, SEL))objc_msgSend)(self, selector);
            if (reported > 0.0) {
                height = MAX(height, reported);
                break;
            }
        }
    }

    // The status block is several lines tall, so the header needs more room than the one-line
    // subtitle it replaced. Measure it rather than guessing at a line count.
    NSString *subtitle = self.subtitle;
    if (subtitle.length) {
        CGFloat width = _preferredExpandedContentWidth > 0.0 ? _preferredExpandedContentWidth : WIDTH * 0.8;
        UIFont *labelFont = self.statusLabel.font;
        CGFloat measuringSize = MAX(kHeaderTextFontSize, labelFont ? labelFont.pointSize : 0.0);
        CGRect bounds = [subtitle boundingRectWithSize:CGSizeMake(width - kHeaderTextIndent * 2.0, CGFLOAT_MAX)
                                               options:NSStringDrawingUsesLineFragmentOrigin
                                            attributes:@{
                                                NSFontAttributeName: [UIFont systemFontOfSize:measuringSize],
                                                NSParagraphStyleAttributeName: [self deviceStatusParagraphStyle],
                                            }
                                               context:nil];
        CGFloat estimated = kTitleAreaHeight + ceil(CGRectGetHeight(bounds)) + kHeaderTextInset;
        self.lastEstimatedHeaderHeight = estimated;
        height = MAX(height, estimated);
    }
    return height;
}

// The stock module sizes its expanded panel to a fixed fraction of the screen, which left a big
// empty area below five rows. Measure the rows instead and ask for exactly that much.
- (CGFloat)preferredExpandedContentHeight {
    CGFloat width = _preferredExpandedContentWidth > 0.0 ? _preferredExpandedContentWidth : WIDTH * 0.8;

    CGFloat itemsHeight = 0.0;
    if ([self respondsToSelector:@selector(_menuItemsHeightForWidth:)]) {
        itemsHeight = [self _menuItemsHeightForWidth:width];
    }
    if (itemsHeight <= 0.0) {
        CGFloat rowHeight = kEstimatedMenuItemHeight;
        if ([self respondsToSelector:@selector(_defaultMenuItemHeight)]) {
            CGFloat reported = [self _defaultMenuItemHeight];
            if (reported > 0.0) {
                rowHeight = reported;
            }
        }
        itemsHeight = rowHeight * (CGFloat)MAX((NSUInteger)1, [self menuItemViews].count);
    }

    CGFloat height = MIN([self menuHeaderHeight] + itemsHeight + [self _footerHeight],
        HEIGHT * kMaximumExpandedHeightRatio);
    self.lastReportedHeight = height;
    return height;
}

// self.expanded is not usable here: the superclass only sets it from its own _handlePressGesture:,
// which we bypass, so it stays false even with the menu wide open. Ask the container, which
// tracks the real state — otherwise touches meant for menu items get swallowed by this class and
// a finger resting on an item for half a second trips the long-press respring.
- (BOOL)isMenuExpanded {
    if (self.expanded) {
        return YES;
    }
    UIViewController *container = self.parentViewController;
    if ([container respondsToSelector:@selector(isExpanded)]) {
        return [(CCUIContentModuleContainerViewController *)container isExpanded];
    }
    return NO;
}

// Control Center hands the whole touch to this one recognizer (minimumPressDuration is 0, so it
// begins on touch-down), and stock behaviour is: tap does nothing, long press expands the menu.
// Take the gesture over completely to swap that around — tap opens the menu, long press resprings
// straight away. Deliberately does not call super for the collapsed case; super is what would
// expand on long press, which is exactly what we are replacing.
// ---- expanded menu: make the selection follow the finger ----

// Root view the whole platter lives in, so every menu row can be measured in one coordinate space.
- (UIView *)menuRootView {
    UIView *containerView = self.parentViewController.view;
    return containerView ?: self.view;
}
- (void)collectMenuItemViewsFrom:(UIView *)view into:(NSMutableArray *)found {
    Class itemViewClass = %c(CCUIMenuModuleItemView);
    for (UIView *subview in view.subviews) {
        if (itemViewClass && [subview isKindOfClass:itemViewClass]) {
            [found addObject:subview];
        }
        [self collectMenuItemViewsFrom:subview into:found];
    }
}
- (NSArray *)menuItemViews {
    NSMutableArray *found = [NSMutableArray array];
    UIView *root = [self menuRootView];
    [self collectMenuItemViewsFrom:root into:found];
    [found sortUsingComparator:^NSComparisonResult(UIView *first, UIView *second) {
        CGFloat firstY = [first convertPoint:CGPointZero toView:root].y;
        CGFloat secondY = [second convertPoint:CGPointZero toView:root].y;
        if (firstY < secondY) {
            return NSOrderedAscending;
        }
        return firstY > secondY ? NSOrderedDescending : NSOrderedSame;
    }];
    return found;
}
- (CCUIMenuModuleItemView *)menuItemViewAtLocation:(CGPoint)location {
    UIView *root = [self menuRootView];
    for (CCUIMenuModuleItemView *itemView in [self menuItemViews]) {
        if (CGRectContainsPoint([itemView convertRect:itemView.bounds toView:root], location)) {
            return itemView;
        }
    }
    return nil;
}
- (void)highlightMenuItemViewAtLocation:(CGPoint)location {
    CCUIMenuModuleItemView *hit = [self menuItemViewAtLocation:location];
    for (CCUIMenuModuleItemView *itemView in [self menuItemViews]) {
        itemView.highlighted = NO;
    }
    hit.highlighted = YES;
    self.highlightedMenuItemView = hit;
}
- (void)clearMenuItemHighlights {
    for (CCUIMenuModuleItemView *itemView in [self menuItemViews]) {
        itemView.highlighted = NO;
    }
    self.highlightedMenuItemView = nil;
}
- (void)performActionForMenuItemView:(CCUIMenuModuleItemView *)itemView {
    if (!itemView) {
        return;
    }

    CCUIMenuModuleItem *item = nil;
    if ([itemView respondsToSelector:@selector(menuItem)]) {
        item = [itemView menuItem];
    }
    if (!item && [self respondsToSelector:@selector(visibleMenuItems)]) {
        // Fall back to position: the rows are laid out in the same order as the items.
        NSUInteger index = [[self menuItemViews] indexOfObject:itemView];
        NSArray *items = [self visibleMenuItems];
        if (index != NSNotFound && index < items.count) {
            item = items[index];
        }
    }
    if (![item respondsToSelector:@selector(performAction)]) {
        return;
    }

    UIViewController *container = self.parentViewController;
    if ([container respondsToSelector:@selector(dismissExpandedModuleAnimated:)]) {
        [(CCUIContentModuleContainerViewController *)container dismissExpandedModuleAnimated:YES];
    }
    [item performAction];
}
// A row is a UIControl, so a quick tap fires its own action and runs the item without us. Record
// that so the gesture's own fallback does not run it a second time.
- (void)_handleActionTapped:(id)sender {
    self.actionTappedDuringGesture = YES;
    [super _handleActionTapped:sender];
}
- (void)handleExpandedMenuGesture:(UILongPressGestureRecognizer *)gesture {
    CGPoint location = [gesture locationInView:[self menuRootView]];
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            self.actionTappedDuringGesture = NO;
            [self highlightMenuItemViewAtLocation:location];
            break;
        case UIGestureRecognizerStateChanged:
            [self highlightMenuItemViewAtLocation:location];
            break;
        case UIGestureRecognizerStateEnded: {
            CCUIMenuModuleItemView *hit = self.highlightedMenuItemView;
            [self clearMenuItemHighlights];
            __weak typeof(self) weakSelf = self;
            // Deferred by one turn of the run loop: the row's own control action lands right after
            // the gesture ends, and it should win when it happens at all. Holding the press
            // cancels that action, which is the case this covers.
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!weakSelf.actionTappedDuringGesture) {
                    [weakSelf performActionForMenuItemView:hit];
                }
            });
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self clearMenuItemHighlights];
            break;
        default:
            break;
    }
}
- (void)_handlePressGesture:(UILongPressGestureRecognizer *)gesture {
    if ([self isMenuExpanded]) {
        // Not forwarded to super: super's drag-select expects the gesture to have started on the
        // collapsed icon and expanded mid-press. Ours starts with the menu already open, which
        // left rows stuck highlighted and never ran anything.
        [self handleExpandedMenuGesture:gesture];
        return;
    }

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            self.longPressFired = NO;
            self.pressInProgress = YES;
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLongPressDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (gesture.state != UIGestureRecognizerStateBegan && gesture.state != UIGestureRecognizerStateChanged) {
                    return;
                }
                // Re-check: if the menu opened under the finger meanwhile, this press belongs to
                // the menu, not to the respring shortcut.
                if ([weakSelf isMenuExpanded]) {
                    return;
                }
                weakSelf.longPressFired = YES;
                // No confirmation and no menu here — holding the icon is the shortcut, so it
                // resprings on the spot. The menu item still asks first.
                [weakSelf respringNow];
            });
            break;
        }
        case UIGestureRecognizerStateEnded:
            self.pressInProgress = NO;
            if (!self.longPressFired) {
                [self openMenu];
            }
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            self.pressInProgress = NO;
            self.longPressFired = NO;
            break;
        default:
            break;
    }
}
- (void)openMenu {
    UIViewController *container = self.parentViewController;
    if (![container respondsToSelector:@selector(expandModule)]) {
        return;
    }
    self.allowExpansion = YES;
    [(CCUIContentModuleContainerViewController *)container expandModule];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        weakSelf.allowExpansion = NO;
    });
}
- (void)respringNow {
    // Do NOT kill backboardd here: relaunching the render server needs
    // com.apple.appletv.pbs.allow-relaunch-backboardd (which is why sbreload carries it).
    // Killing it from SpringBoard just takes the display server down for good.
    // exitAndRelaunch: restarts SpringBoard only, which is what a respring is.
    FBSystemService *systemService = [%c(FBSystemService) sharedInstance];
    [systemService exitAndRelaunch:YES];
}
- (void)respringWithConfirmation {
    __weak typeof(self) weakSelf = self;
    [self confirmActionWithTitle:@"确定要注销设备吗?" message:@"SpringBoard 将会重新启动。" confirmTitle:@"注销" handler:^{
        [weakSelf respringNow];
    }];
}
// Every action here is destructive and one stray tap away, so each one goes through a
// confirmation first. Control Center has no view controller we can present on, so the alert gets
// its own window above the alert level — the same approach CCPower and PowerSelector use.
- (void)confirmActionWithTitle:(NSString *)title message:(NSString *)message confirmTitle:(NSString *)confirmTitle handler:(void (^)(void))handler {
    UIWindowScene *scene = nil;
    for (UIScene *candidate in [UIApplication sharedApplication].connectedScenes) {
        if ([candidate isKindOfClass:[UIWindowScene class]]) {
            scene = (UIWindowScene *)candidate;
            if (candidate.activationState == UISceneActivationStateForegroundActive) {
                break;
            }
        }
    }
    // Fail closed: with nowhere to ask, the action does not run.
    if (!scene) {
        return;
    }

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelAlert + 1;
    window.backgroundColor = [UIColor clearColor];
    window.rootViewController = [[UIViewController alloc] init];
    [window makeKeyAndVisible];
    self.confirmationWindow = window;

    __weak typeof(self) weakSelf = self;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){
        [weakSelf dismissConfirmation];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:confirmTitle style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        [weakSelf dismissConfirmation];
        if (handler) {
            handler();
        }
    }]];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
}
- (void)dismissConfirmation {
    self.confirmationWindow.hidden = YES;
    self.confirmationWindow = nil;
}
- (void)addActionForIdentifier:(NSString *)identifier {
    __weak typeof(self) weakSelf = self;
    NSDictionary *itemStates = [preferences objectForKey:@"itemStates" inDomain:domain];
    // No states written yet means nothing has been switched off, so everything is enabled.
    NSNumber *state = [itemStates objectForKey:identifier];
    if (!state || [state boolValue] == YES) {
        if ([identifier isEqualToString:@"respring"]) {
            [self addActionWithTitle:@"注销设备" subtitle:@"重新载入 SpringBoard" glyph:[UIImage systemImageNamed:@"arrow.clockwise.circle"] handler:^(void){
                [weakSelf respringWithConfirmation];
            }];
        } else if ([identifier isEqualToString:@"safemode"]) {
            [self addActionWithTitle:@"安全模式" subtitle:@"停用所有插件后注销" glyph:[UIImage systemImageNamed:@"exclamationmark.arrow.triangle.2.circlepath"] handler:^(void){
                [weakSelf confirmActionWithTitle:@"确定要进入安全模式吗?" message:@"SpringBoard 将在停用插件的状态下重启。" confirmTitle:@"安全模式" handler:^{
                    pid_t pid;
                    const char* args[] = {"killall", "-SEGV", "SpringBoard", NULL};
                    posix_spawn(&pid, ROOT_PATH("/usr/bin/killall"), NULL, NULL, (char* const*)args, NULL);
                }];
            }];
        } else if ([identifier isEqualToString:@"userspace"]) {
            [self addActionWithTitle:@"重启用户空间" subtitle:@"保留内核,仅重启用户态" glyph:[UIImage systemImageNamed:@"person.crop.circle.badge.checkmark"] handler:^(void){
                [weakSelf confirmActionWithTitle:@"确定要重启用户空间吗?" message:@"所有 App 都会关闭,用户态将重新启动,越狱保持有效。" confirmTitle:@"重启用户空间" handler:^{
                    pid_t pid;
                    const char* args[] = {"userspace-reboot", NULL};
                    posix_spawn(&pid, ROOT_PATH("/usr/libexec/userspace-reboot"), NULL, NULL, (char* const*)args, NULL);
                }];
            }];
        } else if ([identifier isEqualToString:@"reboot"]) {
            [self addActionWithTitle:@"重启设备" subtitle:@"正常重新启动设备" glyph:[UIImage systemImageNamed:@"power"] handler:^(void){
                [weakSelf confirmActionWithTitle:@"确定要重启设备吗?" message:@"设备将会重新启动。" confirmTitle:@"重启" handler:^{
                    FBSystemService *systemService = [%c(FBSystemService) sharedInstance];
                    [systemService shutdownAndReboot:YES];
                }];
            }];
        } else if ([identifier isEqualToString:@"shutdown"]) {
            [self addActionWithTitle:@"关闭设备" subtitle:@"关闭设备电源" glyph:[UIImage systemImageNamed:@"togglepower"] handler:^(void){
                [weakSelf confirmActionWithTitle:@"确定要关闭设备吗?" message:@"设备将会关闭电源。" confirmTitle:@"关闭设备" handler:^{
                    FBSystemService *systemService = [%c(FBSystemService) sharedInstance];
                    [systemService shutdownAndReboot:NO];
                }];
            }];
        }
    }
}
- (void)reloadItems {
    [self loadItems];
}
- (void)viewDidLoad {
    [super viewDidLoad];

    self.spinnerIndicatorView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinnerIndicatorView.frame = CGRectZero;
    self.spinnerIndicatorView.color = [UIColor whiteColor];
    self.spinnerIndicatorView.hidesWhenStopped = NO;
    self.spinnerIndicatorView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.spinnerIndicatorView];

    [NSLayoutConstraint activateConstraints:@[
        [self.spinnerIndicatorView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinnerIndicatorView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.spinnerIndicatorView.widthAnchor constraintEqualToConstant:37],
        [self.spinnerIndicatorView.heightAnchor constraintEqualToConstant:37],
    ]];

    _preferredExpandedContentWidth = WIDTH * 0.8;

    // viewWillTransitionToSize: never fires for a CC module on iOS 16, so it can't be the only
    // thing that populates the menu.
    [self loadItems];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadItems];
}
- (void)_updateMenuItemsSeparatorVisiblity {

}
- (NSUInteger)indentation {
    return 2;
}
- (BOOL)_toggleSelectionForMenuItem:(id)arg0 {
    return NO;
}
- (CGFloat)_footerHeight {
    return 0.0;
}
- (BOOL)_canShowWhileLocked {
	return YES;
}
- (BOOL)_shouldShowFooterSeparator {
    return NO;
}
// Control Center runs its own press-and-hold expansion through a _UIControlCenterClickInteraction
// on the container, in parallel with the gesture this class handles — traced: the menu opened
// with neither openMenu nor expandModule involved. While a finger is down on the icon that press
// belongs to the respring shortcut, so the gate stays shut; openMenu opens it for its own call.
// Any other time it answers YES, so nothing else that asks gets a surprise.
- (BOOL)shouldBeginTransitionToExpandedContentModule {
    if (self.allowExpansion) {
        return YES;
    }
    return !self.pressInProgress;
}
- (CGFloat)_separatorHeight {
    return 0.0;
}
- (BOOL)shouldPerformClickInteraction {
    return YES;
}
@end