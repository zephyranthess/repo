#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

static NSString *const kDomain = @"com.yasin.linefix";
#define kChangedNotification CFSTR("com.yasin.linefix/changed")

@interface LFRootListController : PSListController
@end

@implementation LFRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self bundle:[NSBundle bundleForClass:[self class]]];
	}
	return _specifiers;
}

- (void)nudgeKey:(NSString *)key by:(NSInteger)delta min:(NSInteger)min max:(NSInteger)max fallback:(NSInteger)fallback {
	id current = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
	NSInteger value = current ? [current integerValue] : fallback;
	value = MIN(max, MAX(min, value + delta));
	CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFNumberRef)@(value), (__bridge CFStringRef)kDomain);
	CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
	CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), kChangedNotification, NULL, NULL, YES);
	[self reloadSpecifiers];
}

- (void)xMinus10 { [self nudgeKey:@"x" by:-10 min:0 max:1241 fallback:1200]; }
- (void)xMinus1  { [self nudgeKey:@"x" by:-1  min:0 max:1241 fallback:1200]; }
- (void)xPlus1   { [self nudgeKey:@"x" by:1   min:0 max:1241 fallback:1200]; }
- (void)xPlus10  { [self nudgeKey:@"x" by:10  min:0 max:1241 fallback:1200]; }
- (void)widthMinus { [self nudgeKey:@"width" by:-1 min:1 max:30 fallback:1]; }
- (void)widthPlus  { [self nudgeKey:@"width" by:1  min:1 max:30 fallback:1]; }

- (void)resetColors {
	for (NSString *key in @[@"red", @"green", @"blue"]) {
		CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFNumberRef)@128, (__bridge CFStringRef)kDomain);
	}
	CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
	CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), kChangedNotification, NULL, NULL, YES);
	[self reloadSpecifiers];
}

@end
