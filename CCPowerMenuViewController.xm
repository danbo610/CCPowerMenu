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

// Control Center hands the whole touch to this one recognizer (minimumPressDuration is 0, so it
// begins on touch-down), and stock behaviour is: tap does nothing, long press expands the menu.
// Take the gesture over completely to swap that around — tap opens the menu, long press resprings
// straight away. Deliberately does not call super for the collapsed case; super is what would
// expand on long press, which is exactly what we are replacing.
- (void)_handlePressGesture:(UILongPressGestureRecognizer *)gesture {
    if (self.expanded) {
        [super _handlePressGesture:gesture];
        return;
    }

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            self.longPressFired = NO;
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLongPressDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (gesture.state != UIGestureRecognizerStateBegan && gesture.state != UIGestureRecognizerStateChanged) {
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
            if (!self.longPressFired) {
                [self openMenu];
            }
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            self.longPressFired = NO;
            break;
        default:
            break;
    }
}
- (void)openMenu {
    UIViewController *container = self.parentViewController;
    if ([container respondsToSelector:@selector(expandModule)]) {
        [(CCUIContentModuleContainerViewController *)container expandModule];
    }
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
    _preferredExpandedContentHeight = HEIGHT * 0.8;

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
- (BOOL)shouldBeginTransitionToExpandedContentModule {
    return YES;
}
- (CGFloat)_separatorHeight {
    return 0.0;
}
- (BOOL)shouldPerformClickInteraction {
    return YES;
}
@end