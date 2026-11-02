// Tidy's SpringBoard part: closes background apps on request and runs auto-clean.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "../core/TDCore.h"

@interface NSDistributedNotificationCenter : NSNotificationCenter
+ (instancetype)defaultCenter;
- (void)postNotificationName:(NSString *)name object:(NSString *)object userInfo:(NSDictionary *)userInfo deliverImmediately:(BOOL)deliverImmediately;
@end

static id TDMsg(id obj, NSString *sel) {
	SEL s = NSSelectorFromString(sel);
	return [obj respondsToSelector:s] ? ((id (*)(id, SEL))objc_msgSend)(obj, s) : nil;
}

static NSArray *TDProcessesFor(NSString *bundleID) {
	id manager = TDMsg(NSClassFromString(@"FBProcessManager"), @"sharedInstance");
	SEL sel = NSSelectorFromString(@"processesForBundleIdentifier:");
	NSArray *processes = [manager respondsToSelector:sel] ? ((id (*)(id, SEL, id))objc_msgSend)(manager, sel, bundleID) : nil;
	return [processes isKindOfClass:[NSArray class]] ? processes : @[];
}

static NSInteger TDKill(NSString *bundleID) {
	NSInteger killed = 0;
	for (id process in TDProcessesFor(bundleID)) {
		SEL pidSel = NSSelectorFromString(@"pid");
		int pid = [process respondsToSelector:pidSel] ? ((int (*)(id, SEL))objc_msgSend)(process, pidSel) : 0;
		if (pid > 0 && kill(pid, SIGKILL) == 0) killed++;
	}
	return killed;
}

static void TDKillBackgroundApps(void) {
	NSMutableSet *keep = [NSMutableSet setWithArray:@[
		@"com.yasin.tidy", @"com.apple.mobilephone", @"com.apple.InCallService",
		// Navigation apps keep guiding you in the background.
		@"com.apple.Maps", @"com.waze.iphone", @"com.google.Maps", @"ru.yandex.traffic", @"com.sygic.aura"]];
	id frontmost = TDMsg([UIApplication sharedApplication], @"_accessibilityFrontMostApplication");
	if (TDMsg(frontmost, @"bundleIdentifier")) [keep addObject:TDMsg(frontmost, @"bundleIdentifier")];
	id nowPlaying = TDMsg(TDMsg(NSClassFromString(@"SBMediaController"), @"sharedInstance"), @"nowPlayingApplication");
	if (TDMsg(nowPlaying, @"bundleIdentifier")) [keep addObject:TDMsg(nowPlaying, @"bundleIdentifier")];

	NSInteger count = 0;
	id workspace = TDMsg(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
	for (id proxy in TDMsg(workspace, @"allInstalledApplications")) {
		NSString *bundleID = TDMsg(proxy, @"bundleIdentifier");
		if (!bundleID || [keep containsObject:bundleID]) continue;
		count += TDKill(bundleID);
	}
	[[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"com.yasin.tidy.killbackground.done" object:nil userInfo:@{@"count": @(count)} deliverImmediately:YES];
}

static void TDMaybeAutoClean(void) {
	TDAutoClean mode = [TDSettings autoClean];
	if (mode == TDAutoCleanOff) return;
	NSDate *lastAuto = [TDSettings load][@"lastAutoClean"];
	NSTimeInterval since = lastAuto ? -[lastAuto timeIntervalSinceNow] : DBL_MAX;
	BOOL due = NO;
	if (mode == TDAutoCleanWeekly) {
		due = since > 7 * 86400;
	} else {
		unsigned long long total = 0, free = 0;
		[TDStorage diskTotal:&total free:&free];
		due = since > 6 * 3600 && free < (unsigned long long)([TDSettings lowSpaceGB] * 1e9);
	}
	if (!due) return;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
		unsigned long long freed = TDCleanEnabledCategories();
		NSMutableDictionary *settings = [TDSettings load];
		settings[@"lastAutoClean"] = [NSDate date];
		[TDSettings save:settings];
		[TDSettings recordClean:freed automatic:YES];
		NSLog(@"[Tidy] auto-clean freed %llu bytes", freed);
	});
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
	%orig;
	NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
	NSOperationQueue *main = [NSOperationQueue mainQueue];
	[center addObserverForName:kTDKillBackgroundNotification object:nil queue:main usingBlock:^(NSNotification *note) {
		TDKillBackgroundApps();
	}];
	[center addObserverForName:kTDKillAppNotification object:nil queue:main usingBlock:^(NSNotification *note) {
		NSString *bundleID = note.userInfo[@"bundleID"];
		if ([bundleID isKindOfClass:[NSString class]]) TDKill(bundleID);
	}];
	// Auto-clean check: 10 minutes after startup, then every 3 hours.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		TDMaybeAutoClean();
		[NSTimer scheduledTimerWithTimeInterval:3 * 3600 repeats:YES block:^(NSTimer *timer) { TDMaybeAutoClean(); }];
	});
}
%end
