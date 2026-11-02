// CarCast: run any app on CarPlay (iOS 18 port of carplay-cast by Ethan Arbuckle, Apache-2.0).
#pragma once

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

@interface NSDistributedNotificationCenter : NSNotificationCenter
+ (instancetype)defaultCenter;
- (void)postNotificationName:(NSString *)name object:(NSString *)object userInfo:(NSDictionary *)userInfo deliverImmediately:(BOOL)deliverImmediately;
@end

// Private initializers, declared so ARC handles alloc/init ownership correctly.
@interface NSObject (CCPrivateInits)
- (id)initWithIdentifier:(id)identifier andApplicationSceneEntity:(id)entity;
- (id)initWithApplicationSceneHandle:(id)handle;
- (id)initWithCADisplay:(id)display isMainDisplay:(BOOL)isMain;
- (id)initWithCADisplay:(id)display;
- (id)initWithDisplayConfiguration:(id)configuration;
- (id)initWithSceneID:(id)sceneID;
@end

// Cross-process messages
#define kCCLaunchNotification      @"com.yasin.carcast.launch"       // userInfo: bundleID, target ("car" | "phone")
#define kCCCloseNotification       @"com.yasin.carcast.close"
#define kCCSnapshotNotification    @"com.yasin.carcast.snapshot"     // SpringBoard saves a screenshot
#define kCCLogNotification         @"com.yasin.carcast.log"          // userInfo: line
#define kCCOrientationNotification @"com.yasin.carcast.orientation"  // object: bundleID, userInfo: orientation

// Written by SpringBoard just before hosting an app; read by the app at launch.
#define kCCHostedPlistPath @"/var/jb/var/mobile/Library/Preferences/com.yasin.carcast.hosted.plist"
#define kCCLogPath      @"/var/mobile/Library/Logs/CarCast.log"
#define kCCSnapshotPath @"/var/mobile/Library/Caches/CarCast-snapshot.png"

#ifdef __cplusplus
extern "C" {
#endif
void CCLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void CCLogStartWriter(void); // SpringBoard only: writes log lines from all processes to kCCLogPath
#ifdef __cplusplus
}
#endif

// Safe dynamic calls: return nil / 0 instead of crashing when a method is missing.
static inline BOOL CCResponds(id obj, NSString *sel) {
	return obj && [obj respondsToSelector:NSSelectorFromString(sel)];
}
#define CCMsg(obj, sel) (CCResponds(obj, sel) ? ((id (*)(id, SEL))objc_msgSend)(obj, NSSelectorFromString(sel)) : nil)
#define CCMsgT(type, obj, sel) (CCResponds(obj, sel) ? ((type (*)(id, SEL))objc_msgSend)(obj, NSSelectorFromString(sel)) : (type)0)
#define CCMsg1(obj, sel, a) (CCResponds(obj, sel) ? ((id (*)(id, SEL, typeof(a)))objc_msgSend)(obj, NSSelectorFromString(sel), a) : nil)
#define CCMsg2(obj, sel, a, b) (CCResponds(obj, sel) ? ((id (*)(id, SEL, typeof(a), typeof(b)))objc_msgSend)(obj, NSSelectorFromString(sel), a, b) : nil)
#define CCMsg3(obj, sel, a, b, c) (CCResponds(obj, sel) ? ((id (*)(id, SEL, typeof(a), typeof(b), typeof(c)))objc_msgSend)(obj, NSSelectorFromString(sel), a, b, c) : nil)
#define CCVoid0(obj, sel) do { if (CCResponds(obj, sel)) ((void (*)(id, SEL))objc_msgSend)(obj, NSSelectorFromString(sel)); } while (0)
#define CCVoid1(obj, sel, a) do { if (CCResponds(obj, sel)) ((void (*)(id, SEL, typeof(a)))objc_msgSend)(obj, NSSelectorFromString(sel), a); } while (0)
#define CCVoid3(obj, sel, a, b, c) do { if (CCResponds(obj, sel)) ((void (*)(id, SEL, typeof(a), typeof(b), typeof(c)))objc_msgSend)(obj, NSSelectorFromString(sel), a, b, c); } while (0)

static inline id CCIvar(id obj, NSString *name) {
	if (!obj) return nil;
	Ivar ivar = class_getInstanceVariable(object_getClass(obj), name.UTF8String);
	if (!ivar) return nil;
	const char *type = ivar_getTypeEncoding(ivar);
	if (!type || type[0] != '@') return nil;
	return object_getIvar(obj, ivar);
}

static inline void CCSetIvarInteger(id obj, NSString *name, long long value) {
	if (!obj) return;
	Ivar ivar = class_getInstanceVariable(object_getClass(obj), name.UTF8String);
	if (!ivar) return;
	const char *type = ivar_getTypeEncoding(ivar);
	if (type && (type[0] == 'q' || type[0] == 'Q')) {
		*(long long *)((uint8_t *)(__bridge void *)obj + ivar_getOffset(ivar)) = value;
	}
}

// ---------- User settings (written by the CarCast app) ----------
// Stored in the jailbreak's preferences folder so every process (SpringBoard,
// CarPlay, apps) can read it.
#define kCCSettingsPath @"/var/jb/var/mobile/Library/Preferences/com.yasin.carcast.plist"

typedef NS_ENUM(NSInteger, CCPadMode) {
	CCPadModeAutomatic = 0, // iPad layout if the app has an iPad version and the global switch is on
	CCPadModeAlways = 1,
	CCPadModeNever = 2,
};

static inline NSDictionary *CCSettings(void) {
	static NSDictionary *cached;
	static NSDate *cachedDate;
	@synchronized ([NSFileManager class]) {
		NSDate *modified = [[[NSFileManager defaultManager] attributesOfItemAtPath:kCCSettingsPath error:nil] fileModificationDate];
		if (!cached || (modified && ![modified isEqualToDate:cachedDate]) || (!modified && cachedDate)) {
			cached = [NSDictionary dictionaryWithContentsOfFile:kCCSettingsPath] ?: @{};
			cachedDate = modified;
		}
		return cached;
	}
}

// Is this app allowed on CarPlay? (default: yes)
static inline BOOL CCAppEnabled(NSString *bundleID) {
	NSArray *disabled = CCSettings()[@"disabledApps"];
	return !([disabled isKindOfClass:[NSArray class]] && [disabled containsObject:bundleID]);
}

static inline CCPadMode CCPadModeForApp(NSString *bundleID) {
	NSDictionary *modes = CCSettings()[@"padLayoutApps"];
	if (![modes isKindOfClass:[NSDictionary class]]) return CCPadModeAutomatic;
	return (CCPadMode)[modes[bundleID] integerValue];
}

static inline BOOL CCPadLayoutGlobal(void) {
	id value = CCSettings()[@"padLayout"];
	return value ? [value boolValue] : YES;
}

static inline BOOL CCDockOnRight(void) {
	return [CCSettings()[@"dockSide"] isEqual:@"right"];
}

// Height (in points) of the app's window on the car screen. Smaller = larger text.
static inline CGFloat CCMaxAppHeight(void) {
	id value = CCSettings()[@"appHeight"];
	CGFloat height = value ? [value doubleValue] : 480;
	return MIN(900, MAX(300, height));
}

// Apps that should never be offered on CarPlay.
static inline BOOL CCIsExcludedBundleID(NSString *bundleID) {
	if (!bundleID.length) return YES;
	if ([bundleID hasPrefix:@"com.apple."] || [bundleID hasPrefix:@"com.opa334."] || [bundleID hasPrefix:@"com.yasin."]) return YES;
	static NSSet *excluded;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		excluded = [NSSet setWithArray:@[@"org.coolstar.SileoStore"]];
	});
	return [excluded containsObject:bundleID];
}
