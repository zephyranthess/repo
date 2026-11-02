// Runs inside SpringBoard. Receives launch requests and keeps hosted apps alive.

#import "common.h"
#import "CCHost.h"

static NSString *CCSceneBundleID(id scene) {
	id process = CCMsg(scene, @"clientProcess");
	return CCMsg(process, @"bundleIdentifier");
}

#if CC_DEBUG
static void CCSaveSnapshot(void) {
	UIImage *(*createScreenImage)(void) = (UIImage *(*)(void))dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
	if (!createScreenImage) { CCLog(@"snapshot: function missing"); return; }
	UIImage *image = createScreenImage();
	NSData *png = UIImagePNGRepresentation(image);
	BOOL ok = [png writeToFile:kCCSnapshotPath atomically:YES];
	float (*backlight)(void) = (float (*)(void))dlsym(RTLD_DEFAULT, "BKSHIDServicesGetBacklightFactor");
	BOOL locked = CCMsgT(BOOL, [UIApplication sharedApplication], @"isLocked");
	CCLog(@"snapshot saved=%d size=%@ backlight=%.2f locked=%d", ok, NSStringFromCGSize(image.size), backlight ? backlight() : -1, locked);
}
#endif

%group SpringBoard

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
	%orig;
	CCLogStartWriter();
	NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
	NSOperationQueue *main = [NSOperationQueue mainQueue];

	[center addObserverForName:kCCLaunchNotification object:nil queue:main usingBlock:^(NSNotification *note) {
		NSString *bundleID = note.userInfo[@"bundleID"];
		BOOL onPhone = [note.userInfo[@"target"] isEqual:@"phone"];
		if (![bundleID isKindOfClass:[NSString class]]) return;
		CGSize size = CGSizeZero;
		NSString *sizeString = note.userInfo[@"size"]; // "WxH", test mode only
		if ([sizeString isKindOfClass:[NSString class]]) {
			NSArray *parts = [sizeString componentsSeparatedByString:@"x"];
			if (parts.count == 2) size = CGSizeMake([parts[0] doubleValue], [parts[1] doubleValue]);
		}
		[CCHost launchBundleID:bundleID onPhone:onPhone simulatedSize:size];
	}];
	[center addObserverForName:kCCCloseNotification object:nil queue:main usingBlock:^(NSNotification *note) {
		[CCHost closeCurrent];
	}];
	[center addObserverForName:@"com.yasin.carcast.settings" object:nil queue:main usingBlock:^(NSNotification *note) {
		[[CCHost current] settingsChanged];
	}];
#if CC_DEBUG
	// Test helpers (debug builds only): screenshots and waking the screen.
	[center addObserverForName:kCCSnapshotNotification object:nil queue:main usingBlock:^(NSNotification *note) {
		CCSaveSnapshot();
	}];
	// Test helper: turn the screen on, and open the home screen if the phone has no passcode.
	[center addObserverForName:@"com.yasin.carcast.wake" object:nil queue:main usingBlock:^(NSNotification *note) {
		id backlight = CCMsg(objc_getClass("SBBacklightController"), @"sharedInstance");
		SEL turnOn = NSSelectorFromString(@"turnOnScreenFullyWithBacklightSource:");
		if ([backlight respondsToSelector:turnOn]) ((void (*)(id, SEL, long long))objc_msgSend)(backlight, turnOn, 0);
		id lockManager = CCMsg(objc_getClass("SBLockScreenManager"), @"sharedInstance");
		SEL unlock = NSSelectorFromString(@"unlockUIFromSource:withOptions:");
		if ([lockManager respondsToSelector:unlock]) ((BOOL (*)(id, SEL, int, id))objc_msgSend)(lockManager, unlock, 0, nil);
		CCLog(@"wake requested, locked=%d", CCMsgT(BOOL, [UIApplication sharedApplication], @"isLocked"));
	}];

#endif

	// Close the car window when CarPlay disconnects.
	[[NSNotificationCenter defaultCenter] addObserverForName:@"CarPlayIsConnectedDidChange" object:nil queue:main usingBlock:^(NSNotification *note) {
		CCHost *host = [CCHost current];
		BOOL connected = [CCHost carDisplay] != nil;
		CCLog(@"CarPlay connected=%d", connected);
		if (host && !host.onPhone && !connected) [host dismiss];
	}];
	CCLog(@"SpringBoard hooks loaded on iOS %@ (scene manager route: %@)", [UIDevice currentDevice].systemVersion,
		objc_getClass("SBSceneManagerCoordinator") ? @"coordinator (iOS 17-26)" : @"window scene (iOS 27+)");
}
%end



// Don't let other parts of SpringBoard push the hosted app to the background.
%hook FBScene
- (void)updateSettings:(id)settings withTransitionContext:(id)context completion:(id)completion {
	if ([CCHost keepAliveBundleIDs].count && CCResponds(settings, @"isForeground") && !CCMsgT(BOOL, settings, @"isForeground")) {
		NSString *bundleID = CCSceneBundleID(self);
		CCHost *host = [CCHost current];
		if (bundleID && [[CCHost keepAliveBundleIDs] containsObject:bundleID] && host && !host.dismissed) {
			CCLog(@"blocked background request for %@", bundleID);
			return;
		}
	}
	%orig;
}
%end

%end // SpringBoard

// iOS 27: lock suspension moved to a per-scene component.
%group LockKeepAlive27
%hook SBSuspendedUnderLockHostComponent
- (BOOL)_shouldBeUnderLock {
	BOOL underLock = %orig;
	if (underLock && [CCHost keepAliveBundleIDs].count) {
		id scene = CCMsg(self, @"scene") ?: CCIvar(self, @"_scene");
		NSString *bundleID = CCSceneBundleID(scene);
		if (bundleID && [[CCHost keepAliveBundleIDs] containsObject:bundleID]) return NO;
	}
	return underLock;
}
%end
%end

%group LockKeepAlive
// Keep the hosted app running when the phone locks.
%hook SBSuspendedUnderLockManager
- (BOOL)_shouldBeBackgroundUnderLockForScene:(id)scene withSettings:(id)settings {
	BOOL background = %orig;
	if (background && [CCHost keepAliveBundleIDs].count) {
		NSString *bundleID = CCSceneBundleID(scene);
		if (bundleID && [[CCHost keepAliveBundleIDs] containsObject:bundleID]) return NO;
	}
	return background;
}
%end
%end

%ctor {
	if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
	%init(SpringBoard);
	if (objc_getClass("SBSuspendedUnderLockManager")) {        // iOS 17-26
		%init(LockKeepAlive);
	}
	if (objc_getClass("SBSuspendedUnderLockHostComponent")) {  // iOS 27
		%init(LockKeepAlive27);
	}
}
