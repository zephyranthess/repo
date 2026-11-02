// LineFix: draws a thin strip over a broken pixel column so it blends in.
// The strip lives in its own tiny always-on-top SpringBoard window, so it
// covers every app, the home screen and the lock screen, and ignores touches.

#import <UIKit/UIKit.h>

static NSString *const kDomain = @"com.yasin.linefix";
#define kChangedNotification "com.yasin.linefix/changed"

static id LFPref(NSString *key, id fallback) {
	id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
	return value ?: fallback;
}

@interface LFWindow : UIWindow
@end

@implementation LFWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
- (BOOL)_ignoresHitTest { return YES; }
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)_canBecomeKeyWindow { return NO; }
- (BOOL)_shouldCreateContextAsSecure { return YES; } // stay visible on the lock screen
+ (BOOL)_isSecure { return YES; }
@end

@interface LFRootViewController : UIViewController
@end

@implementation LFRootViewController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (BOOL)shouldAutorotate { return NO; }
- (BOOL)prefersStatusBarHidden { return NO; }
@end

static LFWindow *gWindow;

static UIWindowScene *LFMainScene(void) {
	for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
		if ([scene isKindOfClass:[UIWindowScene class]] && ((UIWindowScene *)scene).screen == [UIScreen mainScreen]) {
			return (UIWindowScene *)scene;
		}
	}
	return nil;
}

static void LFApply(void) {
	CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);

	BOOL enabled  = [LFPref(@"enabled", @YES) boolValue];
	BOOL findMode = [LFPref(@"findMode", @YES) boolValue];
	CGFloat x     = [LFPref(@"x", @1200) doubleValue];     // in physical pixels
	CGFloat width = MAX(1.0, [LFPref(@"width", @1) doubleValue]);
	CGFloat r     = [LFPref(@"red", @128) doubleValue] / 255.0;
	CGFloat g     = [LFPref(@"green", @128) doubleValue] / 255.0;
	CGFloat b     = [LFPref(@"blue", @128) doubleValue] / 255.0;

	if (!gWindow) {
		UIWindowScene *scene = LFMainScene();
		if (!scene) return;
		gWindow = [[LFWindow alloc] initWithWindowScene:scene];
		gWindow.windowLevel = 10000000;
		gWindow.userInteractionEnabled = NO;
		gWindow.rootViewController = [LFRootViewController new];
		gWindow.rootViewController.view.userInteractionEnabled = NO;
	}

	// Work in the screen's fixed (portrait, physical) coordinates so the strip
	// stays on the same physical column whatever the app's orientation is.
	UIScreen *screen = [UIScreen mainScreen];
	CGFloat scale = screen.nativeScale;
	CGRect fixed = screen.fixedCoordinateSpace.bounds;
	gWindow.frame = CGRectMake(x / scale, 0, width / scale, fixed.size.height);

	UIColor *color = findMode ? [UIColor colorWithRed:1 green:0 blue:0 alpha:1]
	                          : [UIColor colorWithRed:r green:g blue:b alpha:1];
	gWindow.backgroundColor = color;
	gWindow.rootViewController.view.backgroundColor = color;
	gWindow.hidden = !enabled;
}

static void LFPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	dispatch_async(dispatch_get_main_queue(), ^{ LFApply(); });
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
	%orig;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		LFApply();
	});
}
%end

%ctor {
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, LFPrefsChanged,
		CFSTR(kChangedNotification), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
