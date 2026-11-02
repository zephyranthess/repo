#import "common.h"

// Hosts one app's live view inside a window on the car screen
// (or, in test mode, inside a fake "car screen" on the phone).
@interface CCHost : NSObject
@property (nonatomic, copy, readonly) NSString *bundleID;
@property (nonatomic, readonly) BOOL onPhone;
@property (nonatomic, readonly) BOOL dismissed;
@property (nonatomic, readonly) BOOL applyingFrame;
- (CGSize)wantedSceneSize;
@property (nonatomic, strong, readonly) id appViewController;

+ (instancetype)current;
+ (void)launchBundleID:(NSString *)bundleID onPhone:(BOOL)onPhone;
+ (void)launchBundleID:(NSString *)bundleID onPhone:(BOOL)onPhone simulatedSize:(CGSize)size;
- (BOOL)ownsScene:(id)scene;
+ (void)closeCurrent;
+ (id)carDisplay; // CADisplay of the CarPlay screen, or nil
+ (NSSet<NSString *> *)keepAliveBundleIDs;

- (void)dismiss;
- (void)settingsChanged; // re-layout with new dock side / text size
@end
