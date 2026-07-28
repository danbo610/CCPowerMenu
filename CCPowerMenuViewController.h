#import <UIKit/UIKit.h>
#import <sys/utsname.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "spawn.h"
#include <rootless.h>
#include <sys/sysctl.h>

#define WIDTH [UIScreen mainScreen].bounds.size.width
#define HEIGHT [UIScreen mainScreen].bounds.size.height

// NB: never do [[NSUserDefaults standardUserDefaults] initWithSuiteName:...] — that re-inits the
// host process' shared singleton in place and swaps its search domain, which nukes SpringBoard's
// own defaults. Read through objectForKey:inDomain: instead; it doesn't touch the singleton.
#define preferences [NSUserDefaults standardUserDefaults]

static NSString *domain = @"com.mtac.ccpowermenu";

typedef struct CCUILayoutSize {
	unsigned long long width;
	unsigned long long height;
} CCUILayoutSize;

@interface NSUserDefaults (CCPowerMenu)
- (id)objectForKey:(NSString *)key inDomain:(NSString *)domain;
- (void)setObject:(id)value forKey:(NSString *)key inDomain:(NSString *)domain;
@end

@interface UIActivityIndicatorView (CCPowerMenu)
@property (retain, nonatomic) UIColor *color;
@end

@interface CCUIButtonModuleView : UIControl
@property (retain, nonatomic) UIImage *glyphImage;
@end

@interface CCUIButtonModuleViewController : UIViewController
@property (retain, nonatomic) UIImage *glyphImage;
@property (retain, nonatomic) UIColor *glyphColor;
@property (retain, nonatomic) UIImage *selectedGlyphImage;
@property (readonly, nonatomic) CCUIButtonModuleView *buttonView;
@end

@interface CCUIMenuModuleViewController : CCUIButtonModuleViewController {
    NSMutableArray *_menuItems;
}
@property (copy, nonatomic) NSString *subtitle;
@property (copy, nonatomic) NSString *title;
@property (readonly, nonatomic) BOOL hasFooterButton;
@property (readonly, nonatomic) BOOL hasGlyph;
- (void)addActionWithTitle:(id)arg0 glyph:(id)arg1 handler:(id)arg2;
- (void)addActionWithTitle:(id)arg0 subtitle:(id)arg1 glyph:(id)arg2 handler:(id)arg3;
- (void)setMenuItems:(id)arg0;
- (void)removeAllActions;
- (void)_handlePressGesture:(id)arg0;
@end

// The module's own container — the object that opens the expanded menu, and the one that
// actually knows whether it is open.
@interface CCUIContentModuleContainerViewController : UIViewController
- (void)expandModule;
- (BOOL)isExpanded;
@end

@interface CCUIMenuModuleItem : NSObject
@property (copy, nonatomic) NSString *identifier;
@property (copy, nonatomic) NSString *subtitle;
@property (copy, nonatomic) NSString *title;
- (id)initWithTitle:(id)arg0 identifier:(id)arg1 handler:(id)arg2;
- (BOOL)performAction;
@end

@protocol CCUIContentModuleContentViewController <NSObject>
@end

@protocol CCUIContentModule <NSObject>
@end

@interface CCPowerMenuButtonController: UIViewController
- (void)setModuleSize:(UISegmentedControl *)control;
@end

@interface CCPowerMenuViewController : CCUIMenuModuleViewController
@property (nonatomic, readonly) CGFloat preferredExpandedContentHeight;
@property (nonatomic, readonly) CGFloat preferredExpandedContentWidth;
@property (nonatomic, readonly) BOOL expanded;
@property (nonatomic, strong) UIActivityIndicatorView *spinnerIndicatorView;
@property (nonatomic, strong) UIWindow *confirmationWindow;
@property (nonatomic, assign) BOOL longPressFired;
- (void)confirmActionWithTitle:(NSString *)title message:(NSString *)message confirmTitle:(NSString *)confirmTitle handler:(void (^)(void))handler;
- (void)respringWithConfirmation;
- (void)respringNow;
- (BOOL)isMenuExpanded;
@end

@interface FBSystemService : NSObject
+ (id)sharedInstance;
- (void)shutdownAndReboot:(BOOL)arg0;
- (void)exitAndRelaunch:(BOOL)arg0;
@end