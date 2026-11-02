// Tidy: storage and memory cleaner.
#import <UIKit/UIKit.h>
#import <objc/message.h>

UIViewController *TDMakeRootController(void);

@interface TDAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation TDAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	self.window.rootViewController = TDMakeRootController();
	[self.window makeKeyAndVisible];
#ifdef XT_AUTOTEST
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
	// Test build only: save a picture of every tab (light and dark) once the scan has finished.
	UITabBarController *tabs = (UITabBarController *)self.window.rootViewController;
	__block NSInteger tab = 0;
	__block void (^next)(void);
	next = ^{
		if (tab >= (NSInteger)tabs.viewControllers.count * 2) {
			[@"done" writeToFile:@"/var/mobile/Library/Caches/tidy_autotest.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
			return;
		}
		BOOL dark = tab >= (NSInteger)tabs.viewControllers.count;
		self.window.overrideUserInterfaceStyle = dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
		tabs.selectedIndex = tab % tabs.viewControllers.count;
		if (tabs.selectedIndex == 3) {
			UIViewController *files = ((UINavigationController *)tabs.selectedViewController).topViewController;
			if (!dark) ((void (*)(id, SEL))objc_msgSend)(files, NSSelectorFromString(@"scan"));
		}
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((tabs.selectedIndex == 3 && !dark ? 12 : 2) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:self.window.bounds];
			UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
				[self.window.layer renderInContext:context.CGContext];
			}];
			[UIImagePNGRepresentation(image) writeToFile:[NSString stringWithFormat:@"/var/mobile/Library/Caches/tidy_tab%ld.png", (long)tab] atomically:YES];
			tab++;
			next();
		});
	};
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
#pragma clang diagnostic pop
#endif
	return YES;
}
@end

int main(int argc, char *argv[]) {
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([TDAppDelegate class]));
	}
}
