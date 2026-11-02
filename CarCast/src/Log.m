#import "common.h"

static BOOL gIsWriter = NO;
static dispatch_queue_t gLogQueue;

static void CCWriteLine(NSString *line) {
	dispatch_async(gLogQueue, ^{
		NSFileManager *fm = [NSFileManager defaultManager];
		if (![fm fileExistsAtPath:kCCLogPath]) {
			[fm createFileAtPath:kCCLogPath contents:nil attributes:nil];
		}
		// Keep the log small: start over past 512 KB.
		NSDictionary *attrs = [fm attributesOfItemAtPath:kCCLogPath error:nil];
		if ([attrs fileSize] > 512 * 1024) {
			[@"" writeToFile:kCCLogPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
		}
		NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:kCCLogPath];
		[handle seekToEndOfFile];
		[handle writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
		[handle closeFile];
	});
}

void CCLog(NSString *format, ...) {
	va_list args;
	va_start(args, format);
	NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
	va_end(args);

	static NSDateFormatter *formatter;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		formatter = [NSDateFormatter new];
		formatter.dateFormat = @"HH:mm:ss.SSS";
	});
	NSString *line = [NSString stringWithFormat:@"%@ [%@] %@", [formatter stringFromDate:[NSDate date]],
		[[NSProcessInfo processInfo] processName], message];
	NSLog(@"[CarCast] %@", line);

	if (gIsWriter) {
		CCWriteLine(line);
	} else {
		// Backup copy for the CarPlay process, in case its messages can't reach SpringBoard.
		if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"CarPlay"]) {
			static dispatch_queue_t backupQueue;
			static dispatch_once_t onceBackup;
			dispatch_once(&onceBackup, ^{ backupQueue = dispatch_queue_create("com.yasin.carcast.backuplog", DISPATCH_QUEUE_SERIAL); });
			dispatch_async(backupQueue, ^{
				for (NSString *path in @[@"/var/mobile/Library/Logs/CarCast-CarPlay.log", @"/var/tmp/CarCast-CarPlay.log"]) {
					NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
					if (!handle && [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil]) {
						handle = [NSFileHandle fileHandleForWritingAtPath:path];
					}
					if (!handle) continue;
					[handle seekToEndOfFile];
					[handle writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
					[handle closeFile];
					break;
				}
			});
		}
		[[NSDistributedNotificationCenter defaultCenter] postNotificationName:kCCLogNotification object:nil
			userInfo:@{@"line": line} deliverImmediately:YES];
	}
}

void CCLogStartWriter(void) {
	gIsWriter = YES;
	gLogQueue = dispatch_queue_create("com.yasin.carcast.log", DISPATCH_QUEUE_SERIAL);
	[[NSDistributedNotificationCenter defaultCenter] addObserverForName:kCCLogNotification object:nil queue:nil
		usingBlock:^(NSNotification *note) {
			NSString *line = note.userInfo[@"line"];
			if ([line isKindOfClass:[NSString class]]) CCWriteLine(line);
		}];
}
