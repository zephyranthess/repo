// carcastctl: test helper for CarCast.
//   carcastctl launch <bundleID> [phone|car] [WxH]
//   carcastctl close
//   carcastctl snapshot
#import <Foundation/Foundation.h>
@interface NSDistributedNotificationCenter : NSNotificationCenter
+ (instancetype)defaultCenter;
- (void)postNotificationName:(NSString *)name object:(NSString *)object userInfo:(NSDictionary *)userInfo deliverImmediately:(BOOL)deliverImmediately;
@end
int main(int argc, char **argv) {
	@autoreleasepool {
		if (argc < 2) { printf("usage: carcastctl launch <bundleID> [phone|car] | close | snapshot\n"); return 1; }
		NSString *cmd = @(argv[1]);
		NSDistributedNotificationCenter *c = [NSDistributedNotificationCenter defaultCenter];
		if ([cmd isEqual:@"launch"] && argc >= 3) {
			NSString *target = argc >= 4 ? @(argv[3]) : @"phone";
			NSMutableDictionary *info = [@{@"bundleID": @(argv[2]), @"target": target} mutableCopy];
			if (argc >= 5) info[@"size"] = @(argv[4]); // e.g. 1280x720 (test mode)
			[c postNotificationName:@"com.yasin.carcast.launch" object:nil userInfo:info deliverImmediately:YES];
		} else if ([cmd isEqual:@"close"]) {
			[c postNotificationName:@"com.yasin.carcast.close" object:nil userInfo:nil deliverImmediately:YES];
		} else if ([cmd isEqual:@"sizeclass"] && argc >= 4) {
			[c postNotificationName:@"com.yasin.carcast.sizeclass" object:@(argv[2]) userInfo:@{@"sizeClass": @(atoi(argv[3]))} deliverImmediately:YES];
		} else if ([cmd isEqual:@"cpdebug"]) {
			[c postNotificationName:@"com.yasin.carcast.cpdebug" object:nil userInfo:nil deliverImmediately:YES];
		} else if ([cmd isEqual:@"wake"]) {
			[c postNotificationName:@"com.yasin.carcast.wake" object:nil userInfo:nil deliverImmediately:YES];
		} else if ([cmd isEqual:@"snapshot"]) {
			[c postNotificationName:@"com.yasin.carcast.snapshot" object:nil userInfo:nil deliverImmediately:YES];
		} else { printf("unknown command\n"); return 1; }
		[NSThread sleepForTimeInterval:0.3];
	}
	return 0;
}
