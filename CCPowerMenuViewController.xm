#import "CCPowerMenuViewController.h"

@implementation CCPowerMenuViewController
- (instancetype)initWithNibName:(NSString *)name bundle:(NSBundle *)bundle {
    self = [super initWithNibName:name bundle:bundle];
    if (self) {
        self.title = @"Power Options";
        self.subtitle = @"Scroll down for more options";

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadItems) name:@"ccpowermenu/ReloadItems" object:nil];
    }
    return self;
}
- (void)viewWillTransitionToSize:(struct CGSize )arg0 withTransitionCoordinator:(id)arg1 {
    self.spinnerIndicatorView.hidden = arg0.width > self.view.bounds.size.height;
    [self loadItems];
}
- (void)loadItems {
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
// However tall the menu wants to be, never let it swallow the whole screen.
static const CGFloat kMaximumExpandedHeightRatio = 0.9;

// The header is the title/subtitle block above the first row. Its height is wherever the header
// separator sits; that view is laid out before the module is ever expanded.
- (CGFloat)menuHeaderHeight {
    UIView *separator = nil;
    @try {
        separator = [self valueForKey:@"_headerSeparatorView"];
    } @catch (__unused NSException *exception) {
    }
    if ([separator isKindOfClass:[UIView class]] && CGRectGetMinY(separator.frame) > 0.0) {
        return CGRectGetMinY(separator.frame);
    }
    return kFallbackHeaderHeight;
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

    CGFloat height = [self menuHeaderHeight] + itemsHeight + [self _footerHeight];
    return MIN(height, HEIGHT * kMaximumExpandedHeightRatio);
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
    [self confirmActionWithTitle:@"确定要注销吗?" message:@"SpringBoard 将会重新启动。" confirmTitle:@"注销" handler:^{
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
            [self addActionWithTitle:@"Respring" subtitle:@"Reloads SpringBoard" glyph:[UIImage systemImageNamed:@"arrow.clockwise.circle"] handler:^(void){
                [weakSelf respringWithConfirmation];
            }];
        } else if ([identifier isEqualToString:@"safemode"]) {
            [self addActionWithTitle:@"Safe Mode" subtitle:@"Restarts SpringBoard in Safe Mode" glyph:[UIImage systemImageNamed:@"exclamationmark.arrow.triangle.2.circlepath"] handler:^(void){
                [weakSelf confirmActionWithTitle:@"确定要进入安全模式吗?" message:@"SpringBoard 将在停用插件的状态下重启。" confirmTitle:@"安全模式" handler:^{
                    pid_t pid;
                    const char* args[] = {"killall", "-SEGV", "SpringBoard", NULL};
                    posix_spawn(&pid, ROOT_PATH("/usr/bin/killall"), NULL, NULL, (char* const*)args, NULL);
                }];
            }];
        } else if ([identifier isEqualToString:@"userspace"]) {
            [self addActionWithTitle:@"Reboot Userspace" subtitle:@"Restarts userspace but keeps kernel loaded" glyph:[UIImage systemImageNamed:@"person.crop.circle.badge.checkmark"] handler:^(void){
                [weakSelf confirmActionWithTitle:@"确定要重启用户态吗?" message:@"所有 App 都会关闭,用户态将重新启动,越狱保持有效。" confirmTitle:@"重启用户态" handler:^{
                    pid_t pid;
                    const char* args[] = {"userspace-reboot", NULL};
                    posix_spawn(&pid, ROOT_PATH("/usr/libexec/userspace-reboot"), NULL, NULL, (char* const*)args, NULL);
                }];
            }];
        } else if ([identifier isEqualToString:@"reboot"]) {
            [self addActionWithTitle:@"Restart" subtitle:@"Reboots device normally" glyph:[UIImage systemImageNamed:@"power"] handler:^(void){
                [weakSelf confirmActionWithTitle:@"确定要重启设备吗?" message:@"设备将会重新启动。" confirmTitle:@"重启" handler:^{
                    FBSystemService *systemService = [%c(FBSystemService) sharedInstance];
                    [systemService shutdownAndReboot:YES];
                }];
            }];
        } else if ([identifier isEqualToString:@"shutdown"]) {
            [self addActionWithTitle:@"Shutdown" subtitle:@"Powers off device" glyph:[UIImage systemImageNamed:@"togglepower"] handler:^(void){
                [weakSelf confirmActionWithTitle:@"确定要关机吗?" message:@"设备将会关闭电源。" confirmTitle:@"关机" handler:^{
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