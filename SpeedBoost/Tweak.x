// SpeedBoost: speeds up SpringBoard animations (app open/close, app switcher,
// folders, Control Center, notifications) by raising each animation's speed.

#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>

static NSString *const kDomain = @"com.yasin.speedboost";
#define kChangedNotification "com.yasin.speedboost/changed"

static BOOL gEnabled = YES;
static float gSpeed = 1.6f;

static void SBLoadPrefs(void) {
	CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
	id enabled = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("enabled"), (__bridge CFStringRef)kDomain));
	id speed = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("speed"), (__bridge CFStringRef)kDomain));
	gEnabled = enabled ? [enabled boolValue] : YES;
	gSpeed = speed ? [speed floatValue] : 1.6f;
	gSpeed = MIN(4.0f, MAX(1.0f, gSpeed));
}

// Interactive transitions pause a parent layer (speed 0) and scrub it by hand.
// Leave those alone so the animation keeps following the finger correctly.
static BOOL SBInsidePausedLayer(CALayer *layer) {
	for (CALayer *l = layer; l; l = l.superlayer) {
		if (l.speed == 0) return YES;
	}
	return NO;
}

%hook CALayer
- (void)addAnimation:(CAAnimation *)animation forKey:(NSString *)key {
	if (gEnabled && gSpeed > 1.01f && animation && animation.speed != 0 && !SBInsidePausedLayer(self)) {
		CAAnimation *faster = [animation copy]; // CALayer copies the animation anyway
		faster.speed = animation.speed * gSpeed;
		%orig(faster, key);
		return;
	}
	%orig;
}
%end

static void SBPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	SBLoadPrefs();
}

%ctor {
	SBLoadPrefs();
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, SBPrefsChanged,
		CFSTR(kChangedNotification), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
