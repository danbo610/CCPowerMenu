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
- (void)addActionForIdentifier:(NSString *)identifier {
    NSDictionary *itemStates = [preferences objectForKey:@"itemStates" inDomain:domain];
    // No states written yet means nothing has been switched off, so everything is enabled.
    NSNumber *state = [itemStates objectForKey:identifier];
    if (!state || [state boolValue] == YES) {
        if ([identifier isEqualToString:@"respring"]) {
            [self addActionWithTitle:@"Respring" subtitle:@"Reloads SpringBoard" glyph:[UIImage systemImageNamed:@"arrow.clockwise.circle"] handler:^(void){
                pid_t pid;
                const char* args[] = {"killall", "backboardd", NULL};
                posix_spawn(&pid, ROOT_PATH("/usr/bin/killall"), NULL, NULL, (char* const*)args, NULL);
            }];
        } else if ([identifier isEqualToString:@"safemode"]) {
            [self addActionWithTitle:@"Safe Mode" subtitle:@"Restarts SpringBoard in Safe Mode" glyph:[UIImage systemImageNamed:@"exclamationmark.arrow.triangle.2.circlepath"] handler:^(void){
                pid_t pid;
                const char* args[] = {"killall", "-SEGV", "SpringBoard", NULL};
                posix_spawn(&pid, ROOT_PATH("/usr/bin/killall"), NULL, NULL, (char* const*)args, NULL);	
            }];
        } else if ([identifier isEqualToString:@"userspace"]) {
            [self addActionWithTitle:@"Reboot Userspace" subtitle:@"Restarts userspace but keeps kernel loaded" glyph:[UIImage systemImageNamed:@"person.crop.circle.badge.checkmark"] handler:^(void){
                pid_t pid;
                const char* args[] = {"userspace-reboot", NULL};
                posix_spawn(&pid, ROOT_PATH("/usr/libexec/userspace-reboot"), NULL, NULL, (char* const*)args, NULL);	
            }];
        } else if ([identifier isEqualToString:@"reboot"]) {
            [self addActionWithTitle:@"Restart" subtitle:@"Reboots device normally" glyph:[UIImage systemImageNamed:@"power"] handler:^(void){
                FBSystemService *systemService = [%c(FBSystemService) sharedInstance];
                [systemService shutdownAndReboot:YES];
            }];
        } else if ([identifier isEqualToString:@"shutdown"]) {
            [self addActionWithTitle:@"Shutdown" subtitle:@"Powers off device" glyph:[UIImage systemImageNamed:@"togglepower"] handler:^(void){
                FBSystemService *systemService = [%c(FBSystemService) sharedInstance];
                [systemService shutdownAndReboot:NO];
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