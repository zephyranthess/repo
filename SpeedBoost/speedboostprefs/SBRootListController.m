#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <dlfcn.h>

// System accessibility switches (same as Settings > Accessibility).
typedef Boolean (*AXGetter)(void);
typedef void (*AXSetter)(Boolean);

static void *AXLib(void) {
	static void *handle;
	if (!handle) handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_LAZY);
	return handle;
}

@interface SBRootListController : PSListController
@end

@implementation SBRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self bundle:[NSBundle bundleForClass:[self class]]];
	}
	return _specifiers;
}

- (NSNumber *)reduceTransparency:(PSSpecifier *)specifier {
	AXGetter get = (AXGetter)dlsym(AXLib(), "_AXSEnhanceBackgroundContrastEnabled");
	return @(get ? get() : NO);
}

- (void)setReduceTransparency:(NSNumber *)value specifier:(PSSpecifier *)specifier {
	AXSetter set = (AXSetter)dlsym(AXLib(), "_AXSSetEnhanceBackgroundContrastEnabled");
	if (set) set([value boolValue]);
}

- (NSNumber *)reduceMotion:(PSSpecifier *)specifier {
	AXGetter get = (AXGetter)dlsym(AXLib(), "_AXSReduceMotionEnabled");
	return @(get ? get() : NO);
}

- (void)setReduceMotion:(NSNumber *)value specifier:(PSSpecifier *)specifier {
	AXSetter set = (AXSetter)dlsym(AXLib(), "_AXSSetReduceMotionEnabled");
	if (set) set([value boolValue]);
}

@end
