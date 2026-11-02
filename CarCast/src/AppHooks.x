// Runs inside user apps. Lets CarCast force an app into landscape while it is on CarPlay.

#import "common.h"

static long long gOrientationOverride = -1;
static long long gForcedSizeClass = 0; // 0 = leave alone, 2 = regular ("iPad-like" layouts)
static long long gSizeClassMethod = 1;  // 1 = scene trait overrides, 2 = hook every trait collection

// iOS 17+: override the size class for the whole app through its window scenes.
static void CCApplySizeClass(void) {
	Class traitClass = NSClassFromString(@"UITraitHorizontalSizeClass");
	for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
		if (![scene isKindOfClass:[UIWindowScene class]]) continue;
		id overrides = CCMsg(scene, @"traitOverrides");
		if (!overrides) { CCLog(@"traitOverrides not available"); continue; }
		if (gForcedSizeClass > 0) {
			CCVoid1(overrides, @"setHorizontalSizeClass:", (long long)gForcedSizeClass);
		} else if (traitClass) {
			CCVoid1(overrides, @"removeTrait:", (id)traitClass);
		}
		UIWindow *window = ((UIWindowScene *)scene).windows.firstObject;
		CCLog(@"%@: size class override=%lld, now=%ld, window=%@", [[NSBundle mainBundle] bundleIdentifier],
			gForcedSizeClass, (long)window.traitCollection.horizontalSizeClass, NSStringFromCGSize(window.bounds.size));
	}
}

static void CCApplyOrientation(void) {
	long long orientation = gOrientationOverride;
	if (orientation <= 0) orientation = MAX(1, (long long)[UIDevice currentDevice].orientation);
	for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
		if (![scene isKindOfClass:[UIWindowScene class]]) continue;
		for (UIWindow *window in ((UIWindowScene *)scene).windows) {
			SEL sel = NSSelectorFromString(@"_setRotatableViewOrientation:duration:force:");
			if ([window respondsToSelector:sel]) {
				((void (*)(id, SEL, long long, double, BOOL))objc_msgSend)(window, sel, orientation, 0.0, YES);
			}
		}
	}
}

%group SizeClassHook
%hook UITraitCollection
- (UIUserInterfaceSizeClass)horizontalSizeClass {
	if (gForcedSizeClass > 0) return (UIUserInterfaceSizeClass)gForcedSizeClass;
	return %orig;
}
%end
%end

// Experimental: make the app believe it runs on an iPad (universal apps then use their iPad layouts).
%group PadIdiomHook
%hook UIDevice
- (UIUserInterfaceIdiom)userInterfaceIdiom { return UIUserInterfaceIdiomPad; }
%end
%hook UITraitCollection
- (UIUserInterfaceIdiom)userInterfaceIdiom {
	UIUserInterfaceIdiom idiom = %orig;
	return idiom == UIUserInterfaceIdiomPhone ? UIUserInterfaceIdiomPad : idiom;
}
%end
%end

%group Apps
%hook UIWindow
- (void)_setRotatableViewOrientation:(long long)orientation duration:(double)duration force:(BOOL)force {
	if (gOrientationOverride > 0) {
		%orig(gOrientationOverride, duration, force);
		return;
	}
	%orig;
}
%end
%end

%ctor {
	NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
	NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
	if (![bundlePath hasSuffix:@".app"] || CCIsExcludedBundleID(bundleID)) return;

	%init(Apps);

	// Hosted by CarCast? Apply the size class before the app builds its interface.
	NSDictionary *hosted = [NSDictionary dictionaryWithContentsOfFile:kCCHostedPlistPath];
	if ([hosted[@"bundleID"] isEqual:bundleID] && [hosted[@"sizeClass"] longLongValue] > 0) {
		gForcedSizeClass = [hosted[@"sizeClass"] longLongValue];
		gSizeClassMethod = hosted[@"method"] ? [hosted[@"method"] longLongValue] : 1;
		if (gSizeClassMethod == 2) {
			%init(SizeClassHook);
		}
		if ([hosted[@"padIdiom"] boolValue]) {
			%init(PadIdiomHook);
		}
		[[NSNotificationCenter defaultCenter] addObserverForName:UISceneWillConnectNotification object:nil
			queue:nil usingBlock:^(NSNotification *note) {
				dispatch_async(dispatch_get_main_queue(), ^{ CCApplySizeClass(); });
				if (gSizeClassMethod == 1) {
					id overrides = CCMsg(note.object, @"traitOverrides");
					CCVoid1(overrides, @"setHorizontalSizeClass:", (long long)gForcedSizeClass);
				}
			}];
		CCLog(@"%@ launched for CarCast: size class %lld (method %lld) padIdiom=%d", bundleID, gForcedSizeClass, gSizeClassMethod, [hosted[@"padIdiom"] boolValue]);
	}
	[[NSDistributedNotificationCenter defaultCenter] addObserverForName:@"com.yasin.carcast.sizeclass" object:bundleID
		queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
			gForcedSizeClass = [note.userInfo[@"sizeClass"] longLongValue];
			CCApplySizeClass();
		}];
	[[NSDistributedNotificationCenter defaultCenter] addObserverForName:kCCOrientationNotification object:bundleID
		queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
			gOrientationOverride = [note.userInfo[@"orientation"] longLongValue];
			CCApplyOrientation();
		}];
}
