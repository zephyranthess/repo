#import "CCHost.h"
#import <signal.h>

static CCHost *gCurrent;
static NSMutableSet<NSString *> *gKeepAlive;


typedef NS_ENUM(NSInteger, CCScaleMode) {
	CCScaleModeFit = 0,   // keep the app's proportions (black bars)
	CCScaleModeFill = 1,  // stretch to fill the screen
};

// Root view that tells the host whenever its size or safe area changes.
@interface CCHostRootView : UIView
@property (nonatomic, copy) void (^onLayout)(void);
@end

@implementation CCHostRootView
- (void)layoutSubviews {
	[super layoutSubviews];
	if (self.onLayout) self.onLayout();
}
- (void)safeAreaInsetsDidChange {
	[super safeAreaInsetsDidChange];
	[self setNeedsLayout];
}
@end

@interface CCHost ()
@property (nonatomic, copy, readwrite) NSString *bundleID;
@property (nonatomic, readwrite) BOOL onPhone;
@property (nonatomic, strong, readwrite) id appViewController;
@property (nonatomic, strong) id application;
@property (nonatomic, strong) id sceneHandle;
@property (nonatomic, strong) id sceneMonitor;
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) CCHostRootView *rootView;
@property (nonatomic, strong) UIView *contentView;   // area next to the dock
@property (nonatomic, strong) UIView *appHolder;     // holds the app view, scaled to fit
@property (nonatomic, strong) UIView *dockView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic) UIInterfaceOrientation orientation;
@property (nonatomic) CCScaleMode scaleMode;
@property (nonatomic, readwrite) BOOL dismissed;
@property (nonatomic) BOOL wide;
@property (nonatomic) BOOL applyingFrame;
@property (nonatomic) CGSize simulatedCarSize;      // test mode only
@property (nonatomic) CGFloat virtualScale;         // app points per on-screen point (1 on a real car)
@property (nonatomic) CGSize lastContentSize;
@property (nonatomic) CGSize lastAppSize;
@property (nonatomic, strong) NSTimer *watchdog;
@property (nonatomic, strong) NSArray<UIButton *> *dockButtons;
@property (nonatomic) BOOL padLayout;   // app was started in iPad mode for this session
@property (nonatomic) BOOL sawScene;
@end


static NSArray *CCProcessesFor(NSString *bundleID) {
	id manager = CCMsg(objc_getClass("FBProcessManager"), @"sharedInstance");
	NSArray *processes = CCMsg1(manager, @"processesForBundleIdentifier:", bundleID);
	return [processes isKindOfClass:[NSArray class]] ? processes : @[];
}

static void CCKillApp(NSString *bundleID) {
	for (id process in CCProcessesFor(bundleID)) {
		int pid = CCMsgT(int, process, @"pid");
		if (pid > 0) {
			CCLog(@"restarting %@ (pid %d)", bundleID, pid);
			kill(pid, SIGKILL);
		}
	}
}

@implementation CCHost

+ (instancetype)current { return gCurrent; }

+ (NSSet<NSString *> *)keepAliveBundleIDs { return gKeepAlive; }

+ (id)carDisplay {
	id device = CCMsg(objc_getClass("AVExternalDevice"), @"currentCarPlayExternalDevice");
	if (!device) return nil;
	NSArray *screenIDs = CCMsg(device, @"screenIDs");
	NSString *carScreenID = [screenIDs isKindOfClass:[NSArray class]] ? screenIDs.firstObject : nil;
	if (!carScreenID) return nil;
	for (id display in CCMsg(objc_getClass("CADisplay"), @"displays")) {
		if ([carScreenID isEqualToString:CCMsg(display, @"uniqueId")]) return display;
	}
	return nil;
}

+ (void)launchBundleID:(NSString *)bundleID onPhone:(BOOL)onPhone {
	[self launchBundleID:bundleID onPhone:onPhone simulatedSize:CGSizeMake(800, 480)];
}

+ (void)launchBundleID:(NSString *)bundleID onPhone:(BOOL)onPhone simulatedSize:(CGSize)size {
	if (!gKeepAlive) gKeepAlive = [NSMutableSet set];
	if (gCurrent) [gCurrent dismiss];
	@try {
		CCHost *host = [[CCHost alloc] initWithBundleID:bundleID onPhone:onPhone simulatedSize:size];
		gCurrent = host;
	} @catch (NSException *e) {
		CCLog(@"launch failed: %@ %@", e.name, e.reason);
		gCurrent = nil;
	}
}

+ (void)closeCurrent {
	[gCurrent dismiss];
}

#pragma mark - iOS version differences
// iOS 17-26 and iOS 27 reach the same things through different objects.
// Each helper tries the older route first, then the newer one.

static id CCMainWindowScene(void) {
	id app = [UIApplication sharedApplication];
	return CCMsg(app, @"embeddedDisplayWindowScene") ?: CCMsg(app, @"_mainDisplayWindowScene");
}

// The SpringBoard scene manager for the phone's own screen.
static id CCMainSceneManager(void) {
	id manager = CCMsg(objc_getClass("SBSceneManagerCoordinator"), @"mainDisplaySceneManager"); // iOS 17-26
	Class sceneManagerClass = objc_getClass("SBSceneManager");
	if (!manager) {
		id candidate = CCMsg([UIApplication sharedApplication], @"sceneManager");               // iOS 27
		if ([candidate isKindOfClass:sceneManagerClass]) manager = candidate;
	}
	if (!manager) {
		id candidate = CCMsg(CCMsg([UIApplication sharedApplication], @"windowSceneManager"), @"sceneManager");
		if ([candidate isKindOfClass:sceneManagerClass]) manager = candidate;
	}
	return manager;
}

static id CCMainDisplayIdentity(id sceneManager) {
	return CCMsg(sceneManager, @"displayIdentity") ?: CCMsg(CCMainWindowScene(), @"displayIdentity");
}

// "Scene identity" = which of the app's windows to show. Different owners per iOS version.
static id CCSceneIdentityForApplication(id sceneManager, id application) {
	id switcher = CCMsg(CCMainWindowScene(), @"switcherController");
	NSArray *providers = @[sceneManager ?: [NSNull null],                          // iOS 17-26
	                       CCIvar(switcher, @"_sceneIdentityProvider") ?: [NSNull null], // iOS 27
	                       switcher ?: [NSNull null]];
	NSString *role = @"UIWindowSceneSessionRoleApplication";
	for (id provider in providers) {
		if (provider == [NSNull null]) continue;
		SEL primary = NSSelectorFromString(@"sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:");
		if ([provider respondsToSelector:primary]) {
			id identity = ((id (*)(id, SEL, id, BOOL, id))objc_msgSend)(provider, primary, application, YES, role);
			if (identity) { CCLog(@"scene identity via %@ (primary)", [provider class]); return identity; }
		}
		SEL withRole = NSSelectorFromString(@"sceneIdentityForApplication:uniqueIdentifier:targetContentIdentifier:sceneSessionRole:");
		if ([provider respondsToSelector:withRole]) {
			id identity = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(provider, withRole, application, nil, nil, role);
			if (identity) { CCLog(@"scene identity via %@ (role)", [provider class]); return identity; }
		}
		id identity = CCMsg1(provider, @"sceneIdentityForApplication:", application);
		if (identity) { CCLog(@"scene identity via %@ (simple)", [provider class]); return identity; }
	}
	return nil;
}

// FBSDisplayConfiguration for the car screen.
static id CCCarDisplayConfiguration(id carDisplay) {
	Class configClass = objc_getClass("FBSDisplayConfiguration");
	id configuration = nil;
	if (carDisplay && [configClass instancesRespondToSelector:NSSelectorFromString(@"initWithCADisplay:isMainDisplay:")]) {
		configuration = [[configClass alloc] initWithCADisplay:carDisplay isMainDisplay:NO];   // iOS 17-26
	} else if (carDisplay && [configClass instancesRespondToSelector:NSSelectorFromString(@"initWithCADisplay:")]) {
		configuration = [[configClass alloc] initWithCADisplay:carDisplay];                    // iOS 27
	}
	if (!configuration) {
		// Fallback: UIKit's own CarPlay screen object.
		id carScreen = CCMsg([UIScreen class], @"_carScreen");
		configuration = CCMsg(carScreen, @"displayConfiguration");
	}
	return configuration;
}

static NSString *CCFrontmostBundleID(void) {
	id frontmost = CCMsg([UIApplication sharedApplication], @"_accessibilityFrontMostApplication");
	return CCMsg(frontmost, @"bundleIdentifier"); // nil on iOS 27 (method removed): treated as "not open on the phone"
}

#pragma mark - Setup

- (instancetype)initWithBundleID:(NSString *)bundleID onPhone:(BOOL)onPhone simulatedSize:(CGSize)simulatedSize {
	if (!(self = [super init])) return nil;
	_simulatedCarSize = (simulatedSize.width > 0 && simulatedSize.height > 0) ? simulatedSize : CGSizeMake(800, 480);
	_virtualScale = 1;
	_bundleID = [bundleID copy];
	_onPhone = onPhone;
	_orientation = UIInterfaceOrientationLandscapeRight;
	_scaleMode = CCScaleModeFit;
	_wide = YES;

	CCLog(@"host %@ on %@", bundleID, onPhone ? @"PHONE (test mode)" : @"CAR");

	id appController = CCMsg(objc_getClass("SBApplicationController"), @"sharedInstance");
	_application = CCMsg1(appController, @"applicationWithBundleIdentifier:", bundleID);
	if (!_application) {
		CCLog(@"no SBApplication for %@", bundleID);
		return nil;
	}

	if (![self createWindow]) return nil;
	[self buildInterface];
	[self layoutAll];
	self.window.alpha = 0;
	self.window.hidden = NO;
	[UIView animateWithDuration:0.4 animations:^{ self.window.alpha = 1; }];

	// iPad layout: the app reads this at launch, so a running app has to restart.
	switch (CCPadModeForApp(bundleID)) {
		case CCPadModeAlways: self.padLayout = YES; break;
		case CCPadModeNever: self.padLayout = NO; break;
		default: self.padLayout = CCPadLayoutGlobal() && [self appSupportsPad]; break;
	}
	[self writeHostedSettings];
	BOOL needsRestart = self.padLayout && CCProcessesFor(bundleID).count > 0;
	if (needsRestart) CCKillApp(bundleID);
	CCLog(@"iPad layout=%d restart=%d", self.padLayout, needsRestart);

	__weak CCHost *weakHost = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((needsRestart ? 0.7 : 0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		CCHost *host = weakHost;
		if (!host || host.dismissed) return;
		if (![host hostApplication]) {
			host.statusLabel.text = @"Couldn't start the app";
			return;
		}
		[host layoutApp];
	});

	// Let video and animations keep playing while the phone screen is off.
	if (!onPhone) {
		int (*setBlanked)(int) = (int (*)(int))dlsym(RTLD_DEFAULT, "BKSDisplayServicesSetScreenBlanked");
		if (setBlanked) setBlanked(0);
	}

	// Keep the app's window at the right size if iOS changes it back.
	__weak CCHost *weakSelf = self;
	self.watchdog = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *timer) {
		[weakSelf checkSceneFrame];
	}];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[self logState:@"3s after launch"];
	});
	return self;
}

- (BOOL)createWindow {
	if (self.onPhone) {
		// Test mode: a fake car screen in the middle of the phone, with the simulated car's proportions.
		UIWindowScene *scene = nil;
		for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
			if ([s isKindOfClass:[UIWindowScene class]] && ((UIWindowScene *)s).screen == [UIScreen mainScreen]) { scene = (UIWindowScene *)s; break; }
		}
		if (!scene) { CCLog(@"no main window scene"); return NO; }
		CGRect screen = [UIScreen mainScreen].bounds;
		CGFloat width = screen.size.width;
		CGFloat height = round(width * self.simulatedCarSize.height / self.simulatedCarSize.width);
		self.virtualScale = self.simulatedCarSize.width / width;
		CCLog(@"simulating a %@ car screen (scale %.2f)", NSStringFromCGSize(self.simulatedCarSize), self.virtualScale);
		self.window = [[UIWindow alloc] initWithWindowScene:scene];
		self.window.frame = CGRectMake(0, (screen.size.height - height) / 2, width, height);
		self.window.windowLevel = 1050;
		return YES;
	}

	id carDisplay = [CCHost carDisplay];
	if (!carDisplay && !CCMsg([UIScreen class], @"_carScreen")) { CCLog(@"no CarPlay display found"); return NO; }
	id configuration = CCCarDisplayConfiguration(carDisplay);
	if (!configuration) { CCLog(@"no display configuration"); return NO; }
	self.window = (UIWindow *)[[objc_getClass("UIRootSceneWindow") alloc] initWithDisplayConfiguration:configuration];
	if (!self.window) { CCLog(@"UIRootSceneWindow failed"); return NO; }
	CCLog(@"car window %@", NSStringFromCGRect(self.window.frame));
	return YES;
}

- (void)buildInterface {
	UIWindow *window = self.window;
	window.backgroundColor = [UIColor blackColor];
	window.clipsToBounds = YES;

	self.rootView = [[CCHostRootView alloc] initWithFrame:window.bounds];
	self.rootView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	self.rootView.backgroundColor = [UIColor blackColor];
	__weak CCHost *weakSelf = self;
	self.rootView.onLayout = ^{ [weakSelf layoutAll]; };
	[window addSubview:self.rootView];

	self.contentView = [[UIView alloc] initWithFrame:CGRectZero];
	self.contentView.clipsToBounds = YES;
	self.contentView.backgroundColor = [UIColor blackColor];
	[self.rootView addSubview:self.contentView];

	self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
	self.statusLabel.textAlignment = NSTextAlignmentCenter;
	self.statusLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1];
	self.statusLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
	self.statusLabel.text = @"Loading…";
	self.statusLabel.numberOfLines = 0;
	self.statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[self.contentView addSubview:self.statusLabel];

	self.appHolder = [[UIView alloc] initWithFrame:CGRectZero];
	self.appHolder.backgroundColor = [UIColor clearColor];
	[self.contentView addSubview:self.appHolder];

	self.dockView = [[UIView alloc] initWithFrame:CGRectZero];
	self.dockView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
	[self.rootView addSubview:self.dockView];

	NSArray *items = @[
		@[@"house.fill", NSStringFromSelector(@selector(dismiss))],
		@[@"rectangle.portrait.arrowtriangle.2.outward", NSStringFromSelector(@selector(rotate))],
		@[@"arrow.up.left.and.arrow.down.right", NSStringFromSelector(@selector(toggleScaleMode))],
	];
	NSMutableArray *buttons = [NSMutableArray array];
	for (NSArray *item in items) {
		UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
		UIImage *image = [UIImage systemImageNamed:item[0]] ?: [UIImage systemImageNamed:@"circle"];
		[button setImage:image forState:UIControlStateNormal];
		button.tintColor = [UIColor whiteColor];
		[button addTarget:self action:NSSelectorFromString(item[1]) forControlEvents:UIControlEventTouchUpInside];
		[self.dockView addSubview:button];
		[buttons addObject:button];
	}
	self.dockButtons = buttons;
}

// Lays out the dock and the app area from the current window size and safe area.
// Called on every size change, so any car screen resolution works.
- (void)layoutAll {
	if (!self.rootView || self.dismissed) return;
	CGRect bounds = self.rootView.bounds;
	if (bounds.size.width < 1 || bounds.size.height < 1) return;
	UIEdgeInsets safe = self.rootView.safeAreaInsets;
	CGRect usable = UIEdgeInsetsInsetRect(bounds, safe);

	// Dock: about 7% of the width, between 44 and 72 points.
	CGFloat dockWidth = round(MIN(72, MAX(44, usable.size.width * 0.07)));
	BOOL dockRight = CCDockOnRight();
	// Dock column (in usable coordinates) and the area left for the app.
	CGFloat dockX = dockRight ? CGRectGetMaxX(usable) - dockWidth : usable.origin.x;
	CGFloat contentX = dockRight ? usable.origin.x : usable.origin.x + dockWidth;
	self.dockView.frame = dockRight
		? CGRectMake(dockX, 0, bounds.size.width - dockX, bounds.size.height)
		: CGRectMake(0, 0, usable.origin.x + dockWidth, bounds.size.height);
	CGFloat dockInset = dockX - self.dockView.frame.origin.x; // dock column offset inside the dock view
	// Room for all buttons plus a gap between the top group and the home button.
	CGFloat buttonSize = MIN(dockWidth - 8, (usable.size.height - 16 - 6 * self.dockButtons.count) / (self.dockButtons.count + 0.5));
	buttonSize = MAX(buttonSize, 20);
	UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:round(buttonSize * 0.45) weight:UIImageSymbolWeightMedium];
	CGFloat y = usable.origin.y + 8;
	for (UIButton *button in self.dockButtons) {
		button.frame = CGRectMake(dockInset + (dockWidth - buttonSize) / 2, y, buttonSize, buttonSize);
		[button setPreferredSymbolConfiguration:config forImageInState:UIControlStateNormal];
		y += buttonSize + 6;
	}
	// Home button at the bottom, like CarPlay.
	UIButton *home = self.dockButtons.firstObject;
	home.frame = CGRectMake(home.frame.origin.x, CGRectGetMaxY(usable) - buttonSize - 8, buttonSize, buttonSize);

	CGRect content = CGRectMake(contentX, usable.origin.y, usable.size.width - dockWidth, usable.size.height);
	self.contentView.frame = content;
	self.statusLabel.frame = self.contentView.bounds;

	if (!CGSizeEqualToSize(content.size, self.lastContentSize)) {
		CCLog(@"window %@ safe %@ -> app area %@", NSStringFromCGSize(bounds.size), NSStringFromUIEdgeInsets(safe), NSStringFromCGSize(content.size));
		self.lastContentSize = content.size;
		[self layoutApp];
	}
}

- (BOOL)hostApplication {
	@try {
		id sceneManager = CCMainSceneManager();
		id displayIdentity = CCMainDisplayIdentity(sceneManager);
		id sceneIdentity = CCSceneIdentityForApplication(sceneManager, self.application);
		CCLog(@"sceneManager=%@ identity=%@", [sceneManager class], sceneIdentity);
		if (!sceneIdentity) return NO;

		id request = CCMsg3(objc_getClass("SBApplicationSceneHandleRequest"), @"defaultRequestForApplication:sceneIdentity:displayIdentity:",
			self.application, sceneIdentity, displayIdentity);
		self.sceneHandle = CCMsg1(sceneManager, @"fetchOrCreateApplicationSceneHandleForRequest:", request);
		CCLog(@"sceneHandle=%@", [self.sceneHandle class]);
		if (!self.sceneHandle) return NO;

		id entity = [[objc_getClass("SBDeviceApplicationSceneEntity") alloc] initWithApplicationSceneHandle:self.sceneHandle];
		if (!entity) return NO;

		self.appViewController = [[objc_getClass("SBAppViewController") alloc] initWithIdentifier:self.bundleID andApplicationSceneEntity:entity];
		if (!self.appViewController) return NO;
		CCVoid1(self.appViewController, @"setIgnoresOcclusions:", (BOOL)NO);
		CCSetIvarInteger(self.appViewController, @"_currentMode", 2);
		CCVoid0(CCIvar(self.appViewController, @"_activationSettings"), @"clearActivationSettings");

		id transaction = CCMsg2(self.appViewController, @"_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:", entity, (BOOL)YES);
		NSMutableSet *activeTransitions = CCIvar(self.appViewController, @"_activeTransitions");
		CCLog(@"transaction=%@ activeTransitions=%@", [transaction class], [activeTransitions class]);
		if (transaction) {
			__weak id weakTransaction = transaction;
			__weak CCHost *weakSelf = self;
			void (^completion)(BOOL) = ^(BOOL finished) {
				id strongTransaction = weakTransaction;
				if (strongTransaction && [activeTransitions respondsToSelector:@selector(removeObject:)]) [activeTransitions removeObject:strongTransaction];
				dispatch_async(dispatch_get_main_queue(), ^{
					CCHost *host = weakSelf;
					if (!host || host.dismissed) return;
					CCLog(@"scene transaction finished (%d)", finished);
					host.statusLabel.hidden = YES;
					[host layoutApp];
				});
			};
			CCVoid1(transaction, @"setCompletionBlock:", completion);
			if ([activeTransitions respondsToSelector:@selector(addObject:)]) [activeTransitions addObject:transaction];
			CCVoid0(transaction, @"begin");
		}

		CCVoid0(self.appViewController, @"_createSceneViewController");
		id animationFactory = CCMsg(objc_getClass("SBApplicationSceneView"), @"defaultDisplayModeAnimationFactory");
		id appView = CCMsg(self.appViewController, @"appView");
		if (appView) {
			((void (*)(id, SEL, long long, id, id))objc_msgSend)(appView, NSSelectorFromString(@"setDisplayMode:animationFactory:completion:"), 4, animationFactory, nil);
		}
		UIView *appVCView = CCMsg(self.appViewController, @"view");
		appVCView.backgroundColor = [UIColor clearColor];
		[self.appHolder addSubview:appVCView];

		[gKeepAlive addObject:self.bundleID];

		NSString *sceneID = CCMsg(self.sceneHandle, @"sceneIdentifier");
		if (sceneID && objc_getClass("FBSceneMonitor")) {
			self.sceneMonitor = [[objc_getClass("FBSceneMonitor") alloc] initWithSceneID:sceneID];
			CCVoid1(self.sceneMonitor, @"setDelegate:", self);
		}
		CCLog(@"hosting started, sceneID=%@", sceneID);
		return YES;
	} @catch (NSException *e) {
		CCLog(@"hostApplication exception: %@ %@", e.name, e.reason);
		return NO;
	}
}

#pragma mark - iPad layout

- (BOOL)appSupportsPad {
	id info = CCMsg(self.application, @"info");
	NSURL *bundleURL = CCMsg(info, @"bundleURL");
	if (![bundleURL isKindOfClass:[NSURL class]]) return NO;
	NSDictionary *plist = [NSDictionary dictionaryWithContentsOfURL:[bundleURL URLByAppendingPathComponent:@"Info.plist"]];
	NSArray *families = plist[@"UIDeviceFamily"];
	return [families isKindOfClass:[NSArray class]] && [families containsObject:@2];
}

- (void)writeHostedSettings {
	NSDictionary *settings = @{
		@"bundleID": self.bundleID,
		@"sizeClass": @(self.padLayout ? 2 : 0),
		@"method": @2,
		@"padIdiom": @(self.padLayout),
	};
	[settings writeToFile:kCCHostedPlistPath atomically:YES];
}

#pragma mark - Layout

// Wide mode (default): the app gets a window shaped like the car screen and lays
// itself out to fill it. Phone mode: the app keeps its normal phone-sized portrait
// window, scaled down to fit.
- (CGSize)appSize {
	if (self.wide) {
		CGSize area = self.contentView.bounds.size;
		CGSize size = CGSizeMake(area.width * self.virtualScale, area.height * self.virtualScale);
		// Cap the app's height so text stays readable on big car screens and the
		// phone doesn't render a huge window. The result is scaled up to fill the screen.
		CGFloat shrink = MIN(1.0, CCMaxAppHeight() / MAX(size.height, 1));
		return CGSizeMake(round(size.width * shrink), round(size.height * shrink));
	}
	CGSize phone = [UIScreen mainScreen].bounds.size;
	return CGSizeMake(MIN(phone.width, phone.height), MAX(phone.width, phone.height));
}

- (void)applySceneFrame:(CGSize)size {
	id scene = CCMsg(self.sceneHandle, @"sceneIfExists");
	if (!CCResponds(scene, @"updateSettingsWithBlock:")) return;
	self.applyingFrame = YES;
	void (^update)(id) = ^(id settings) {
		SEL setFrame = NSSelectorFromString(@"setFrame:");
		if ([settings respondsToSelector:setFrame]) {
			((void (*)(id, SEL, CGRect))objc_msgSend)(settings, setFrame, CGRectMake(0, 0, size.width, size.height));
		}
		SEL setOrientation = NSSelectorFromString(@"setInterfaceOrientation:");
		if ([settings respondsToSelector:setOrientation]) {
			((void (*)(id, SEL, long long))objc_msgSend)(settings, setOrientation, (long long)UIInterfaceOrientationPortrait);
		}
	};
	@try {
		CCVoid1(scene, @"updateSettingsWithBlock:", update);
	} @catch (NSException *e) {
		CCLog(@"applySceneFrame error: %@", e);
	}
	self.applyingFrame = NO;
}

- (CGSize)wantedSceneSize {
	return [self appSize];
}

- (void)layoutApp {
	UIView *appVCView = CCMsg(self.appViewController, @"view");
	if (!appVCView) return;

	CGSize appSize = [self appSize];
	CGSize area = self.contentView.bounds.size;
	if (appSize.width < 1 || appSize.height < 1) return;
	self.lastAppSize = appSize;
	CGFloat scaleX = area.width / appSize.width, scaleY = area.height / appSize.height;
	if (!self.wide && self.scaleMode == CCScaleModeFit) scaleX = scaleY = MIN(scaleX, scaleY);

	self.appHolder.transform = CGAffineTransformIdentity;
	self.appHolder.frame = CGRectMake(0, 0, appSize.width, appSize.height);
	appVCView.frame = self.appHolder.bounds;
	self.appHolder.transform = CGAffineTransformMakeScale(scaleX, scaleY);
	self.appHolder.center = CGPointMake(area.width / 2, area.height / 2);

	SEL refSel = NSSelectorFromString(@"setContentReferenceSize:withContentOrientation:andContainerOrientation:");
	if ([self.appViewController respondsToSelector:refSel]) {
		((void (*)(id, SEL, CGSize, long long, long long))objc_msgSend)(self.appViewController, refSel, appSize, (long long)UIInterfaceOrientationPortrait, (long long)UIInterfaceOrientationPortrait);
	}
	[self applySceneFrame:appSize];
}

- (void)settingsChanged {
	self.lastContentSize = CGSizeZero; // forces the app to be re-laid out
	[UIView animateWithDuration:0.25 animations:^{ [self layoutAll]; }];
}

- (BOOL)ownsScene:(id)scene {
	return scene && scene == CCMsg(self.sceneHandle, @"sceneIfExists");
}

- (void)checkSceneFrame {
	if (self.dismissed) return;
	id scene = CCMsg(self.sceneHandle, @"sceneIfExists");
	// The app quit or crashed (FBSceneMonitor, which reported this, is gone on iOS 26+).
	if (scene) self.sawScene = YES;
	else if (self.sawScene) { CCLog(@"app scene is gone, closing"); [self dismiss]; return; }
	if (CGSizeEqualToSize(self.lastAppSize, CGSizeZero)) return;
	id settings = CCMsg(scene, @"settings");
	if (!CCResponds(settings, @"frame")) return;
	CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(settings, NSSelectorFromString(@"frame"));
	if (!CGSizeEqualToSize(frame.size, self.lastAppSize)) {
		CCLog(@"app window was %@, restoring %@", NSStringFromCGSize(frame.size), NSStringFromCGSize(self.lastAppSize));
		[self applySceneFrame:self.lastAppSize];
	}
}

#pragma mark - Dock actions

// Switch between wide (car-shaped) and phone-shaped layout.
- (void)rotate {
	self.wide = !self.wide;
	CCLog(@"layout -> %@", self.wide ? @"wide" : @"phone");
	[UIView animateWithDuration:0.25 animations:^{ [self layoutApp]; }];
}

- (void)toggleScaleMode {
	if (self.wide) return; // wide layout always fills the screen
	self.scaleMode = self.scaleMode == CCScaleModeFit ? CCScaleModeFill : CCScaleModeFit;
	CCLog(@"scale mode -> %@", self.scaleMode == CCScaleModeFit ? @"fit" : @"fill");
	[UIView animateWithDuration:0.25 animations:^{ [self layoutApp]; }];
}

- (void)sendOrientationToApp:(long long)orientation {
	[[NSDistributedNotificationCenter defaultCenter] postNotificationName:kCCOrientationNotification object:self.bundleID
		userInfo:@{@"orientation": @(orientation)} deliverImmediately:YES];
}

#pragma mark - Teardown

// FBSceneMonitor delegate: the app died or was killed from the app switcher.
- (void)sceneMonitor:(id)monitor sceneWasDestroyed:(id)sceneID {
	CCLog(@"scene destroyed");
	dispatch_async(dispatch_get_main_queue(), ^{ [self dismiss]; });
}

- (void)dismiss {
	if (self.dismissed) return;
	self.dismissed = YES;
	CCLog(@"dismiss %@", self.bundleID);

	[self.watchdog invalidate];
	self.watchdog = nil;
	CCVoid0(self.sceneMonitor, @"invalidate");
	self.sceneMonitor = nil;
	[self sendOrientationToApp:-1];
	[gKeepAlive removeObject:self.bundleID];
	[[NSFileManager defaultManager] removeItemAtPath:kCCHostedPlistPath error:nil];

	// Send the app to the background unless it is open on the phone.
	@try {
		id scene = CCMsg(self.sceneHandle, @"sceneIfExists");
		BOOL openOnPhone = [CCFrontmostBundleID() isEqualToString:self.bundleID];
		if (scene && !openOnPhone && CCResponds(scene, @"updateSettingsWithBlock:")) {
			void (^update)(id) = ^(id settings) {
				CCVoid1(settings, @"setForeground:", (BOOL)NO);
			};
			CCVoid1(scene, @"updateSettingsWithBlock:", update);
		}
	} @catch (NSException *e) {
		CCLog(@"background error: %@", e);
	}

	@try {
		((void (*)(id, SEL, long long))objc_msgSend)(self.appViewController, NSSelectorFromString(@"_setCurrentMode:"), 0);
	} @catch (NSException *e) {}

	UIWindow *window = self.window;
	[UIView animateWithDuration:0.3 animations:^{ window.alpha = 0; } completion:^(BOOL finished) {
		window.hidden = YES;
		[CCMsg(self.appViewController, @"view") removeFromSuperview];
		CCVoid0(self.appViewController, @"invalidate");
		// Don't restart it if CarCast has just opened the same app again.
		BOOL reopened = gCurrent && gCurrent != self && [gCurrent.bundleID isEqualToString:self.bundleID];
		if (self.padLayout && !reopened) {
			if (![CCFrontmostBundleID() isEqualToString:self.bundleID]) CCKillApp(self.bundleID);
		}
		self.appViewController = nil;
		self.window = nil;
		if (gCurrent == self) gCurrent = nil;
	}];
}

#pragma mark - Diagnostics

- (void)logState:(NSString *)when {
	@try {
		id appVC = self.appViewController;
		id scene = CCMsg(self.sceneHandle, @"sceneIfExists");
		id settings = CCMsg(scene, @"settings");
		CCLog(@"state (%@): displayMode=%lld currentMode=%lld hosting=%d scene=%@ foreground=%d frame=%@",
			when,
			CCMsgT(long long, appVC, @"displayMode"),
			CCMsgT(long long, appVC, @"currentMode"),
			CCMsgT(BOOL, appVC, @"isHostingAnApp"),
			scene ? @"yes" : @"no",
			CCMsgT(BOOL, settings, @"isForeground"),
			NSStringFromCGRect(CCResponds(settings, @"frame") ? ((CGRect (*)(id, SEL))objc_msgSend)(settings, NSSelectorFromString(@"frame")) : CGRectZero));
	} @catch (NSException *e) {
		CCLog(@"logState error %@", e);
	}
}

@end
