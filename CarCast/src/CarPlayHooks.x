// Runs inside the CarPlay process (DashBoard). Makes every user app appear on the
// CarPlay home screen, and hands taps on those apps to SpringBoard to host.

#import "common.h"

static NSMutableSet<NSString *> *gForcedApps;    // apps we added to CarPlay
static char kForcedDeclarationKey;
static CFAbsoluteTime gLastLaunchTime;
static NSString *gLastLaunchID;

static BOOL CCAppInfoQualifies(id info) {
	NSString *bundleID = CCMsg(info, @"bundleIdentifier");
	if (CCIsExcludedBundleID(bundleID)) return NO;
	if (!CCAppEnabled(bundleID)) return NO;
	if (CCMsgT(BOOL, info, @"isHidden")) return NO;
	if (CCMsgT(BOOL, info, @"isFirstParty")) return NO;
	return YES;
}

static id CCMakeDeclaration(NSString *bundleID, id bundleURL) {
	id declaration = [objc_getClass("CRCarPlayAppDeclaration") new];
	if (!declaration) return nil;
	// Not template-based: otherwise CarPlay's template host keeps looking for a template and crashing.
	CCVoid1(declaration, @"setSupportsTemplates:", (BOOL)NO);
	CCVoid1(declaration, @"setSupportsMaps:", (BOOL)YES);
	CCVoid1(declaration, @"setBundleIdentifier:", bundleID);
	NSString *path = [bundleURL isKindOfClass:[NSURL class]] ? [bundleURL path] : bundleURL;
	if (path) CCVoid1(declaration, @"setBundlePath:", path);
	objc_setAssociatedObject(declaration, &kForcedDeclarationKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	return declaration;
}

static BOOL CCIsForcedDeclaration(id declaration) {
	return declaration && objc_getAssociatedObject(declaration, &kForcedDeclarationKey) != nil;
}

static id CCPatchPolicy(id declaration, id policy) {
	if (!CCIsForcedDeclaration(declaration)) return policy;
	if (!policy) policy = [objc_getClass("CRCarPlayAppPolicy") new];
	CCVoid1(policy, @"setCarPlaySupported:", (BOOL)YES);
	CCVoid1(policy, @"setCarPlayCapable:", (BOOL)YES);
	CCVoid1(policy, @"setCanDisplayOnCarScreen:", (BOOL)YES);
	CCVoid1(policy, @"setLaunchUsingTemplateUI:", (BOOL)NO);
	CCVoid1(policy, @"setLaunchUsingMusicUIService:", (BOOL)NO);
	CCVoid1(policy, @"setLaunchUsingSiri:", (BOOL)NO);
	return policy;
}

static BOOL CCClassImplements(Class cls, SEL sel) {
	if (!cls) return NO;
	unsigned int count = 0;
	Method *methods = class_copyMethodList(cls, &count);
	BOOL found = NO;
	for (unsigned int i = 0; i < count && !found; i++) found = method_getName(methods[i]) == sel;
	free(methods);
	return found;
}

// Was this app added by CarCast (as opposed to having its own CarPlay support)?
static BOOL CCApplicationIsForced(id application) {
	id info = CCMsg(application, @"info") ?: application; // iOS 18+: DBApplication.info, iOS 17: DBApplicationInfo
	id declaration = CCIvar(info, @"_carPlayDeclaration");
	if (declaration) return CCIsForcedDeclaration(declaration);
	NSString *bundleID = CCMsg(application, @"bundleIdentifier");
	return bundleID && [gForcedApps containsObject:bundleID];
}

// Returns YES if the launch was taken over by CarCast.
static BOOL CCHandleLaunchOfApplication(id application, NSString *source) {
	NSString *bundleID = CCMsg(application, @"bundleIdentifier");
	if (!bundleID || !CCApplicationIsForced(application)) return NO;

	// The same tap can arrive through more than one path; only act once.
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if ([gLastLaunchID isEqualToString:bundleID] && now - gLastLaunchTime < 1.0) return YES;
	gLastLaunchID = bundleID;
	gLastLaunchTime = now;

	CCLog(@"launch %@ (via %@) -> asking SpringBoard to host it", bundleID, source);
	[[NSDistributedNotificationCenter defaultCenter] postNotificationName:kCCLaunchNotification object:nil
		userInfo:@{@"bundleID": bundleID, @"target": @"car"} deliverImmediately:YES];
	return YES;
}

%group CarPlay

// The app list: iOS 18 filters apps twice (by identity, then by installed app).
// Wrap both filters so user apps get through.
static NSString *CCBundleIDOf(id object) {
	NSString *bundleID = CCMsg(object, @"bundleIdentifier");
	if (![bundleID isKindOfClass:[NSString class]]) bundleID = CCMsg(object, @"bundleID");
	return [bundleID isKindOfClass:[NSString class]] ? bundleID : nil;
}

static BOOL CCShouldLetThrough(id object) {
	NSString *bundleID = CCBundleIDOf(object);
	if (CCIsExcludedBundleID(bundleID)) return NO;
	if (!CCAppEnabled(bundleID)) return NO;
	NSArray *tags = CCMsg(object, @"appTags");
	if ([tags isKindOfClass:[NSArray class]] && [tags containsObject:@"hidden"]) return NO;
	return YES;
}

static id CCWrapFilter(id filter, NSString *name) {
	if (!filter) return nil;
	BOOL (^original)(id, id) = [filter copy];
	__block int logged = 0;
	return [^BOOL(id object, id extra) {
		BOOL result = original(object, extra);
		if (!result && CCShouldLetThrough(object)) {
			if (logged++ < 3) CCLog(@"%@ filter: letting %@ through (%@)", name, CCBundleIDOf(object), [object class]);
			return YES;
		}
		return result;
	} copy];
}

%hook FBSApplicationLibraryConfiguration
- (void)setInstalledApplicationFilter:(id)filter {
	%orig(CCWrapFilter(filter, @"installed"));
}
- (void)setApplicationIdentityFilter:(id)filter {
	%orig(CCWrapFilter(filter, @"identity"));
}
%end

// Give each user app a fake "supports CarPlay" declaration.
static BOOL gLoaderHookRan = NO; // a normal loading path exists on this iOS version

static void CCForceDeclaration(id info) {
	@try {
		if (CCIvar(info, @"_carPlayDeclaration") != nil || !CCAppInfoQualifies(info)) return;
		NSString *bundleID = CCMsg(info, @"bundleIdentifier");
		id declaration = CCMakeDeclaration(bundleID, CCMsg(info, @"bundleURL"));
		Ivar ivar = class_getInstanceVariable(object_getClass(info), "_carPlayDeclaration");
		if (declaration && ivar) {
			object_setIvarWithStrongDefault(info, ivar, declaration);
			@synchronized (gForcedApps) { [gForcedApps addObject:bundleID]; }
			CCLog(@"added %@ to CarPlay", bundleID);
		}
	} @catch (NSException *e) {
		CCLog(@"declaration error: %@", e);
	}
}

%hook DBApplicationInfo
// iOS 18+
- (void)_loadFromRecord:(id)record {
	%orig;
	gLoaderHookRan = YES;
	CCForceDeclaration(self);
}
// Fallback only for iOS versions where neither loader above exists, because the
// getter can run before an app's own (native) CarPlay declaration is loaded.
- (id)carPlayDeclaration {
	id declaration = %orig;
	if (!declaration && !gLoaderHookRan) {
		CCForceDeclaration(self);
		declaration = CCIvar(self, @"_carPlayDeclaration");
	}
	return declaration;
}
%end

// Allow those apps on the car screen.
%hook CRCarPlayAppPolicyEvaluator
- (id)effectivePolicyForAppDeclaration:(id)declaration {
	return CCPatchPolicy(declaration, %orig);
}
- (id)effectivePolicyForAppDeclaration:(id)declaration inVehicleWithCertificateSerial:(id)serial {
	return CCPatchPolicy(declaration, %orig);
}
%end



// Taps on the CarPlay home screen.
%hook DBDashboard
- (void)handleEvent:(id)event {
	@try {
		id context = CCMsg(event, @"context");
		if ([context isKindOfClass:objc_getClass("DBApplicationLaunchInfo")]) {
			if (CCHandleLaunchOfApplication(CCMsg(context, @"application"), @"handleEvent")) return;
		}
	} @catch (NSException *e) {
		CCLog(@"handleEvent error: %@", e);
	}
	%orig;
}

- (void)_handleOpenApplicationEvent:(id)event {
	@try {
		id context = CCMsg(event, @"context");
		if ([context isKindOfClass:objc_getClass("DBApplicationLaunchInfo")]) {
			if (CCHandleLaunchOfApplication(CCMsg(context, @"application"), @"openApplicationEvent")) return;
		}
	} @catch (NSException *e) {
		CCLog(@"_handleOpenApplicationEvent error: %@", e);
	}
	%orig;
}
%end

// Diagnostics: see which launch path is used.
%hook DBApplicationLaunchInfo
+ (id)launchInfoForApplication:(id)application withActivationSettings:(id)settings {
	CCLog(@"launchInfo for %@", CCMsg(application, @"bundleIdentifier"));
	return %orig;
}
%end

%end // CarPlay

// iOS 17 loads app info through _loadFromProxy:. Only hooked where DBApplicationInfo
// implements it itself: on iOS 18+ it is inherited and runs too early.
%group CarPlayProxyLoader
%hook DBApplicationInfo
- (void)_loadFromProxy:(id)proxy {
	%orig;
	gLoaderHookRan = YES;
	CCForceDeclaration(self);
}
%end
%end

%group CarPlayIcons
// Show their icons.
%hook DBIconModel
- (BOOL)isIconVisible:(id)icon {
	BOOL visible = %orig;
	NSString *bundleID = CCMsg(icon, @"applicationBundleID");
	if (bundleID && [gForcedApps containsObject:bundleID]) return CCAppEnabled(bundleID);
	return visible;
}
%end
%end

%ctor {
	if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.CarPlayApp"]) return;
	gForcedApps = [NSMutableSet set];
	// iOS 26+ renamed DBIconModel (rewritten in Swift).
	Class iconModel = objc_getClass("DBIconModel") ?: objc_getClass("_TtC9DashBoard11DBIconModel");
	%init(CarPlay);
	if (CCClassImplements(objc_getClass("DBApplicationInfo"), @selector(_loadFromProxy:))) {
		%init(CarPlayProxyLoader);
	}
	if (iconModel) {
		%init(CarPlayIcons, DBIconModel = iconModel);
	}

#if CC_DEBUG
	// Debug: list which apps CarPlay would show and whether they're allowed on the car screen.
	[[NSDistributedNotificationCenter defaultCenter] addObserverForName:@"com.yasin.carcast.cpdebug" object:nil
		queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
			@try {
				id controller = CCMsg(objc_getClass("DBApplicationController"), @"sharedInstance");
				NSArray *apps = CCMsg(controller, @"allApplications");
				CCLog(@"debug: %lu apps in CarPlay library, %lu added by CarCast", (unsigned long)apps.count, (unsigned long)gForcedApps.count);
				for (id app in apps) {
					id policy = CCMsg(app, @"appPolicy");
					CCLog(@"debug: %@ supported=%d onCarScreen=%d templates=%d",
						CCMsg(app, @"bundleIdentifier"),
						CCMsgT(BOOL, policy, @"isCarPlaySupported"),
						CCMsgT(BOOL, policy, @"canDisplayOnCarScreen"),
						CCMsgT(BOOL, policy, @"launchUsingTemplateUI"));
				}
			} @catch (NSException *e) {
				CCLog(@"debug error: %@", e);
			}
		}];
#endif
	CCLog(@"CarPlay hooks loaded on iOS %@ (DBApplicationInfo=%d, DBDashboard=%d, icon model=%@)",
		[UIDevice currentDevice].systemVersion, objc_getClass("DBApplicationInfo") != nil, objc_getClass("DBDashboard") != nil,
		iconModel ? NSStringFromClass(iconModel) : @"MISSING");
}
