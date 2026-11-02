// Small home-screen app that shows one tweak's settings.
// Needed because PreferenceLoader (2.2.8) doesn't load into the iOS 18 Settings app.
//
// Build settings (compiler defines):
//   XT_CARCAST                      show the CarCast settings (CarCastSettings.m)
//   XT_PREFS_BUNDLE / XT_PREFS_CLASS / XT_TITLE
//                                   otherwise: load this preference bundle and show its controller

#import <UIKit/UIKit.h>

#ifdef XT_CARCAST
@interface XTCarCastController : UITableViewController
@end
#endif

#ifndef XT_CARCAST
static UIViewController *XTMessageController(NSString *title, NSString *message) {
	UIViewController *controller = [UIViewController new];
	controller.title = title;
	controller.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
	UILabel *label = [UILabel new];
	label.text = message;
	label.numberOfLines = 0;
	label.textAlignment = NSTextAlignmentCenter;
	label.textColor = [UIColor secondaryLabelColor];
	label.translatesAutoresizingMaskIntoConstraints = NO;
	[controller.view addSubview:label];
	[NSLayoutConstraint activateConstraints:@[
		[label.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
		[label.leadingAnchor constraintEqualToAnchor:controller.view.leadingAnchor constant:32],
		[label.trailingAnchor constraintEqualToAnchor:controller.view.trailingAnchor constant:-32],
	]];
	return controller;
}

#endif

static UIViewController *XTRootController(void) {
#ifdef XT_CARCAST
	return [XTCarCastController new];
#else
	NSString *path = @"/var/jb/Library/PreferenceBundles/" XT_PREFS_BUNDLE ".bundle";
	NSBundle *bundle = [NSBundle bundleWithPath:path];
	NSError *error = nil;
	Class controllerClass = [bundle loadAndReturnError:&error] ? NSClassFromString(@XT_PREFS_CLASS) : Nil;
	if (!controllerClass) {
		return XTMessageController(@XT_TITLE, [NSString stringWithFormat:@"Couldn't load the settings.\n%@", error.localizedDescription ?: path]);
	}
	UIViewController *controller = [controllerClass new];
	controller.title = @XT_TITLE;
	return controller;
#endif
}

@interface XTAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation XTAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:XTRootController()];
	nav.navigationBar.prefersLargeTitles = YES;
	self.window.rootViewController = nav;
	[self.window makeKeyAndVisible];
	return YES;
}
@end

int main(int argc, char *argv[]) {
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([XTAppDelegate class]));
	}
}
