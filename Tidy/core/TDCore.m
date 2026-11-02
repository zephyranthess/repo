#import "TDCore.h"
#import <objc/message.h>
#include <fts.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <mach/mach.h>
#include <sqlite3.h>

// libproc (not in the iOS SDK headers)
extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);

#pragma mark - Settings

@implementation TDSettings

+ (NSMutableDictionary *)load {
	return [[NSDictionary dictionaryWithContentsOfFile:kTDSettingsPath] mutableCopy] ?: [NSMutableDictionary dictionary];
}

+ (void)save:(NSDictionary *)settings {
	[settings writeToFile:kTDSettingsPath atomically:YES];
}

+ (TDAutoClean)autoClean { return (TDAutoClean)[[self load][@"autoClean"] integerValue]; }

+ (double)lowSpaceGB {
	id value = [self load][@"lowSpaceGB"];
	return value ? MAX(1, [value doubleValue]) : 5;
}

+ (BOOL)whatsAppEnabled { return [[self load][@"whatsApp"] boolValue]; }

+ (NSSet<NSString *> *)protectedApps {
	NSArray *list = [self load][@"protectedApps"];
	if (![list isKindOfClass:[NSArray class]]) {
		// Apps that may keep offline downloads in their cache folders.
		list = @[@"com.spotify.client", @"com.netflix.Netflix", @"com.google.ios.youtube", @"com.google.ios.youtubemusic",
		         @"com.amazon.aiv.AIVApp", @"com.disney.disneyplus", @"com.hbo.hbonow", @"com.apple.podcasts",
		         @"com.deezer.Deezer", @"com.soundcloud.TouchApp", @"com.audible.iphone"];
	}
	return [NSSet setWithArray:list];
}

+ (BOOL)categoryEnabled:(NSString *)identifier defaultValue:(BOOL)value {
	NSDictionary *categories = [self load][@"categories"];
	id stored = [categories isKindOfClass:[NSDictionary class]] ? categories[identifier] : nil;
	return stored ? [stored boolValue] : value;
}

+ (void)recordClean:(unsigned long long)bytes automatic:(BOOL)automatic {
	NSMutableDictionary *settings = [self load];
	settings[@"lastClean"] = @{@"date": [NSDate date], @"bytes": @(bytes), @"automatic": @(automatic)};
	settings[@"totalCleaned"] = @([settings[@"totalCleaned"] unsignedLongLongValue] + bytes);
	[self save:settings];
}

@end

#pragma mark - Sizes and deleting

unsigned long long TDSizeOfPath(NSString *path) {
	if (!path.length) return 0;
	unsigned long long total = 0;
	char *paths[] = {(char *)path.fileSystemRepresentation, NULL};
	FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
	if (!fts) return 0;
	FTSENT *entry;
	while ((entry = fts_read(fts))) {
		if ((entry->fts_info == FTS_F || entry->fts_info == FTS_SL) && entry->fts_statp) {
			total += (unsigned long long)entry->fts_statp->st_blocks * 512;
		}
	}
	fts_close(fts);
	return total;
}

// Only ever delete inside the user's data area, and never whole top-level folders.
static BOOL TDPathAllowed(NSString *path) {
	NSString *p = path.stringByStandardizingPath;
	if ([p hasPrefix:@"/private/var/"]) p = [p substringFromIndex:8];
	if (![p hasPrefix:@"/var/mobile/"] && ![p hasPrefix:@"/var/tmp/"] && ![p isEqualToString:@"/var/tmp"]) return NO;
	NSArray *forbidden = @[@"/var/mobile", @"/var/mobile/Library", @"/var/mobile/Media", @"/var/mobile/Media/DCIM",
	                       @"/var/mobile/Media/PhotoData", @"/var/mobile/Containers", @"/var/mobile/Library/Preferences",
	                       @"/var/mobile/Library/Keychains", @"/var/mobile/Library/SMS", @"/var/mobile/Containers/Data/Application",
	                       @"/var/mobile/Containers/Shared/AppGroup"];
	return ![forbidden containsObject:p];
}

unsigned long long TDDeleteContents(NSString *path, NSTimeInterval minAge) {
	if (!TDPathAllowed(path)) return 0;
	BOOL isDir = NO;
	if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] || !isDir) return 0;
	unsigned long long freed = 0;
	time_t cutoff = time(NULL) - (time_t)minAge;
	char *paths[] = {(char *)path.fileSystemRepresentation, NULL};
	FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
	if (!fts) return 0;
	FTSENT *entry;
	while ((entry = fts_read(fts))) {
		if (entry->fts_level == 0) continue;
		if ((entry->fts_info == FTS_F || entry->fts_info == FTS_SL || entry->fts_info == FTS_SLNONE) && entry->fts_statp) {
			if (minAge > 0 && entry->fts_statp->st_mtime > cutoff) continue; // recently used: keep
			unsigned long long size = (unsigned long long)entry->fts_statp->st_blocks * 512;
			if (unlink(entry->fts_accpath) == 0) freed += size;
		} else if (entry->fts_info == FTS_DP) {
			rmdir(entry->fts_accpath); // only succeeds when empty
		}
	}
	fts_close(fts);
	return freed;
}

unsigned long long TDDeleteFile(NSString *path) {
	if (!TDPathAllowed([path stringByDeletingLastPathComponent]) && !TDPathAllowed(path)) return 0;
	struct stat st;
	if (lstat(path.fileSystemRepresentation, &st) != 0 || S_ISDIR(st.st_mode)) return 0;
	return unlink(path.fileSystemRepresentation) == 0 ? (unsigned long long)st.st_blocks * 512 : 0;
}

NSString *TDFormatBytes(unsigned long long bytes) {
	return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

#pragma mark - Apps

static id TDMsg(id obj, NSString *sel) {
	SEL s = NSSelectorFromString(sel);
	return [obj respondsToSelector:s] ? ((id (*)(id, SEL))objc_msgSend)(obj, s) : nil;
}

@implementation TDApp

+ (NSArray<TDApp *> *)installedApps {
	NSMutableArray *apps = [NSMutableArray array];
	id workspace = TDMsg(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
	for (id proxy in TDMsg(workspace, @"allInstalledApplications")) {
		TDApp *app = [TDApp new];
		app.bundleID = TDMsg(proxy, @"bundleIdentifier");
		if (!app.bundleID || [app.bundleID hasPrefix:@"com.yasin."]) continue;
		app.name = TDMsg(proxy, @"localizedName") ?: app.bundleID;
		app.bundleURL = TDMsg(proxy, @"bundleURL");
		app.dataURL = TDMsg(proxy, @"dataContainerURL");
		app.isUserApp = [TDMsg(proxy, @"applicationType") isEqualToString:@"User"];
		NSDictionary *groups = TDMsg(proxy, @"groupContainerURLs");
		app.groupURLs = [groups isKindOfClass:[NSDictionary class]] ? groups.allValues : @[];
		if (!app.isUserApp && !app.dataURL) continue; // system apps without data aren't interesting
		if (app.dataURL && ![[NSFileManager defaultManager] fileExistsAtPath:app.dataURL.path]) app.dataURL = nil;

		NSDictionary *info = app.bundleURL ? [NSDictionary dictionaryWithContentsOfURL:[app.bundleURL URLByAppendingPathComponent:@"Info.plist"]] : nil;
		NSDictionary *icon = info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"];
		if ([icon isKindOfClass:[NSDictionary class]]) {
			app.iconName = icon[@"CFBundleIconName"];
			app.iconFiles = icon[@"CFBundleIconFiles"];
		}
		[apps addObject:app];
	}
	return apps;
}

- (NSArray<NSURL *> *)ownGroupURLs {
	// Groups named after this app (not ones shared with other apps of the same developer).
	NSMutableArray *own = [NSMutableArray array];
	for (NSURL *url in self.groupURLs) {
		NSDictionary *meta = [NSDictionary dictionaryWithContentsOfURL:[url URLByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
		NSString *identifier = meta[@"MCMMetadataIdentifier"] ?: url.lastPathComponent;
		if ([identifier containsString:self.bundleID]) [own addObject:url];
	}
	return own;
}

- (void)computeSizes {
	self.appSize = (self.isUserApp && self.bundleURL) ? TDSizeOfPath(self.bundleURL.URLByDeletingLastPathComponent.path) : 0;
	unsigned long long data = self.dataURL ? TDSizeOfPath(self.dataURL.path) : 0;
	for (NSURL *group in [self ownGroupURLs]) data += TDSizeOfPath(group.path);
	self.dataSize = data;
	unsigned long long cache = 0;
	for (NSString *path in [self cachePaths]) cache += TDSizeOfPath(path);
	self.cacheSize = cache;
}

- (NSArray<NSString *> *)cachePaths {
	NSMutableArray *paths = [NSMutableArray array];
	if (self.dataURL) {
		NSString *data = self.dataURL.path;
		[paths addObject:[data stringByAppendingPathComponent:@"Library/Caches"]];
		[paths addObject:[data stringByAppendingPathComponent:@"tmp"]];
		[paths addObject:[data stringByAppendingPathComponent:@"Library/SplashBoard/Snapshots"]];
	}
	for (NSURL *group in self.groupURLs) [paths addObject:[group.path stringByAppendingPathComponent:@"Library/Caches"]];
	return paths;
}

- (unsigned long long)clearCache {
	unsigned long long freed = 0;
	for (NSString *path in [self cachePaths]) freed += TDDeleteContents(path, 0);
	return freed;
}

- (unsigned long long)clearAllData {
	if (!self.isUserApp || !self.dataURL) return 0;
	unsigned long long freed = 0;
	NSString *data = self.dataURL.path;
	for (NSString *sub in @[@"Documents", @"Library", @"tmp", @"SystemData"]) {
		freed += TDDeleteContents([data stringByAppendingPathComponent:sub], 0);
	}
	for (NSURL *group in [self ownGroupURLs]) {
		for (NSString *item in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:group.path error:nil]) {
			if ([item hasPrefix:@".com.apple.mobile_container_manager"]) continue;
			NSString *path = [group.path stringByAppendingPathComponent:item];
			BOOL isDir = NO;
			[[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
			freed += isDir ? TDDeleteContents(path, 0) : TDDeleteFile(path);
		}
	}
	// Folders apps expect to exist.
	for (NSString *sub in @[@"Documents", @"Library/Caches", @"Library/Preferences", @"tmp"]) {
		[[NSFileManager defaultManager] createDirectoryAtPath:[data stringByAppendingPathComponent:sub] withIntermediateDirectories:YES attributes:nil error:nil];
	}
	return freed;
}

@end

#pragma mark - Clean categories

@implementation TDTarget
+ (instancetype)path:(NSString *)path minAge:(NSTimeInterval)minAge {
	TDTarget *target = [TDTarget new];
	target.path = path;
	target.minAge = minAge;
	return target;
}
@end

@implementation TDCategory

+ (TDCategory *)identifier:(NSString *)identifier title:(NSString *)title detail:(NSString *)detail symbol:(NSString *)symbol on:(BOOL)on targets:(NSArray *)targets {
	TDCategory *category = [TDCategory new];
	category.identifier = identifier;
	category.title = title;
	category.detail = detail;
	category.symbol = symbol;
	category.defaultOn = on;
	category.targets = targets;
	return category;
}

static NSArray<TDTarget *> *TDExisting(NSArray<NSString *> *paths, NSTimeInterval minAge) {
	NSMutableArray *targets = [NSMutableArray array];
	for (NSString *path in paths) {
		if ([[NSFileManager defaultManager] fileExistsAtPath:path]) [targets addObject:[TDTarget path:path minAge:minAge]];
	}
	return targets;
}

+ (NSArray<TDCategory *> *)categoriesForApps:(NSArray<TDApp *> *)apps {
	NSSet *protectedApps = [TDSettings protectedApps];
	NSMutableArray *appCaches = [NSMutableArray array], *snapshots = [NSMutableArray array];
	NSString *safariData = nil;
	for (TDApp *app in apps) {
		if ([app.bundleID isEqualToString:@"com.apple.mobilesafari"]) safariData = app.dataURL.path;
		if (!app.dataURL) continue;
		[snapshots addObject:[app.dataURL.path stringByAppendingPathComponent:@"Library/SplashBoard/Snapshots"]];
		if (!app.isUserApp || [protectedApps containsObject:app.bundleID]) continue;
		[appCaches addObject:[app.dataURL.path stringByAppendingPathComponent:@"Library/Caches"]];
		[appCaches addObject:[app.dataURL.path stringByAppendingPathComponent:@"tmp"]];
		for (NSURL *group in app.groupURLs) [appCaches addObject:[group.path stringByAppendingPathComponent:@"Library/Caches"]];
	}
	[snapshots addObject:@"/var/mobile/Library/SplashBoard/Snapshots"];

	NSString *caches = @"/var/mobile/Library/Caches";
	NSMutableArray *web = [NSMutableArray array];
	if (safariData) [web addObjectsFromArray:@[[safariData stringByAppendingPathComponent:@"Library/Caches"], [safariData stringByAppendingPathComponent:@"tmp"]]];
	for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:caches error:nil]) {
		if ([name hasPrefix:@"com.apple.WebKit"] || [name hasPrefix:@"com.apple.Safari"]) [web addObject:[caches stringByAppendingPathComponent:name]];
	}

	NSArray *systemCaches = @[@"GeoServices", @"com.apple.geod", @"com.apple.QuickLook.thumbnailcache", @"com.apple.parsecd",
	                          @"com.apple.iBooksX", @"com.apple.Maps", @"com.apple.mobileslideshow", @"com.apple.AppStore"];
	NSMutableArray *system = [NSMutableArray array];
	for (NSString *name in systemCaches) [system addObject:[caches stringByAppendingPathComponent:name]];

	return @[
		[self identifier:@"appCaches" title:@"App caches" detail:@"Images, videos and data apps saved to load faster. Apps download them again when needed. Apps in your protected list are skipped." symbol:@"square.stack.3d.up" on:YES targets:TDExisting(appCaches, 3600)],
		[self identifier:@"web" title:@"Safari & web cache" detail:@"Saved website files. Logins and history are kept." symbol:@"safari" on:YES targets:TDExisting(web, 0)],
		[self identifier:@"system" title:@"System caches" detail:@"Map tiles, file previews and search caches. iOS rebuilds them automatically." symbol:@"gearshape.2" on:YES targets:TDExisting(system, 0)],
		[self identifier:@"snapshots" title:@"App switcher screenshots" detail:@"Pictures iOS keeps of each app for the app switcher. Recreated the next time you use the app." symbol:@"rectangle.on.rectangle" on:YES targets:TDExisting(snapshots, 0)],
		[self identifier:@"temp" title:@"Temporary files" detail:@"Files apps left behind. Only files older than a day are removed." symbol:@"clock.arrow.circlepath" on:YES targets:TDExisting(@[@"/var/mobile/tmp", @"/var/tmp"], 86400)],
		[self identifier:@"logs" title:@"Crash reports & logs" detail:@"Diagnostic reports from app crashes. Not needed unless you report a bug." symbol:@"doc.text" on:YES targets:TDExisting(@[@"/var/mobile/Library/Logs/CrashReporter"], 0)],
		[self identifier:@"ai" title:@"AI model cache" detail:@"Compiled machine-learning models. iOS rebuilds them, so features like Photos search or Siri may be slower the first time afterwards." symbol:@"cpu" on:NO targets:TDExisting(@[[caches stringByAppendingPathComponent:@"com.apple.aned"], [caches stringByAppendingPathComponent:@"com.apple.e5rt.e5bundlecache"]], 0)],
	];
}

- (void)measure {
	unsigned long long total = 0;
	for (TDTarget *target in self.targets) total += TDSizeOfPath(target.path);
	self.size = total;
}

- (unsigned long long)clean {
	unsigned long long freed = 0;
	for (TDTarget *target in self.targets) freed += TDDeleteContents(target.path, target.minAge);
	return freed;
}

@end

unsigned long long TDCleanEnabledCategories(void) {
	unsigned long long freed = 0;
	for (TDCategory *category in [TDCategory categoriesForApps:[TDApp installedApps]]) {
		if ([TDSettings categoryEnabled:category.identifier defaultValue:category.defaultOn]) freed += [category clean];
	}
	return freed;
}

#pragma mark - Storage overview

static NSArray<NSString *> *TDWhatsAppContainers(void) {
	NSMutableArray *found = [NSMutableArray array];
	NSString *root = @"/var/mobile/Containers/Shared/AppGroup";
	for (NSString *uuid in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil]) {
		NSString *dir = [root stringByAppendingPathComponent:uuid];
		NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
		NSString *identifier = meta[@"MCMMetadataIdentifier"];
		if ([identifier isEqualToString:@"group.net.whatsapp.WhatsApp.shared"] || [identifier isEqualToString:@"group.net.whatsapp.WhatsAppSMB.shared"]) {
			[found addObject:dir];
		}
	}
	return found;
}

@implementation TDStorage

+ (void)diskTotal:(unsigned long long *)total free:(unsigned long long *)free {
	NSURL *url = [NSURL fileURLWithPath:@"/private/var"];
	NSDictionary *values = [url resourceValuesForKeys:@[NSURLVolumeTotalCapacityKey, NSURLVolumeAvailableCapacityForImportantUsageKey, NSURLVolumeAvailableCapacityKey] error:nil];
	*total = [values[NSURLVolumeTotalCapacityKey] unsignedLongLongValue];
	unsigned long long important = [values[NSURLVolumeAvailableCapacityForImportantUsageKey] unsignedLongLongValue];
	*free = important ?: [values[NSURLVolumeAvailableCapacityKey] unsignedLongLongValue];
}

+ (instancetype)measureWithApps:(NSArray<TDApp *> *)apps {
	TDStorage *storage = [TDStorage new];
	unsigned long long total = 0, free = 0;
	[self diskTotal:&total free:&free];
	storage.total = total;
	storage.free = free;

	unsigned long long whatsAppMedia = 0;
	for (NSString *container in TDWhatsAppContainers()) whatsAppMedia += TDSizeOfPath([container stringByAppendingPathComponent:@"Message/Media"]);
	storage.messages = TDSizeOfPath(@"/var/mobile/Library/SMS") + whatsAppMedia;
	storage.photos = TDSizeOfPath(@"/var/mobile/Media/DCIM") + TDSizeOfPath(@"/var/mobile/Media/PhotoData");

	unsigned long long appsSize = 0, dataSize = 0;
	for (TDApp *app in apps) {
		if (app.appSize == 0 && app.dataSize == 0) [app computeSizes];
		appsSize += app.appSize;
		dataSize += app.dataSize;
	}
	storage.apps = appsSize;
	storage.appData = dataSize > whatsAppMedia ? dataSize - whatsAppMedia : 0;
	unsigned long long used = total > free ? total - free : 0;
	unsigned long long counted = storage.apps + storage.appData + storage.photos + storage.messages;
	storage.system = used > counted ? used - counted : 0;
	return storage;
}

@end

#pragma mark - Memory

@implementation TDMemory

+ (instancetype)current {
	TDMemory *memory = [TDMemory new];
	uint64_t total = 0;
	size_t length = sizeof(total);
	sysctlbyname("hw.memsize", &total, &length, NULL, 0);
	memory.total = total;

	vm_statistics64_data_t stats;
	mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
	if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&stats, &count) == KERN_SUCCESS) {
		unsigned long long page = vm_kernel_page_size;
		memory.wired = stats.wire_count * page;
		memory.compressed = stats.compressor_page_count * page;
		unsigned long long internal = stats.internal_page_count * page, purgeable = stats.purgeable_count * page;
		memory.appMemory = internal > purgeable ? internal - purgeable : 0;
		memory.cached = (stats.external_page_count + stats.purgeable_count) * page;
		memory.free = (stats.free_count + stats.speculative_count) * page;
		// Whatever isn't accounted for belongs to the system.
		unsigned long long counted = memory.wired + memory.compressed + memory.appMemory + memory.cached + memory.free;
		if (total > counted) memory.wired += total - counted;
	}
	int level = 0;
	length = sizeof(level);
	memory.pressureLevel = sysctlbyname("kern.memorystatus_level", &level, &length, NULL, 0) == 0 ? level : -1;
	return memory;
}

- (unsigned long long)available { return self.free + self.cached; }

+ (NSArray<NSDictionary *> *)topProcesses:(NSUInteger)count {
	int pids[4096];
	int n = proc_listallpids(pids, sizeof(pids));
	NSMutableArray *rows = [NSMutableArray array];
	for (int i = 0; i < n; i++) {
		struct rusage_info_v4 info;
		if (proc_pid_rusage(pids[i], RUSAGE_INFO_V4, (rusage_info_t *)&info) != 0) continue;
		char name[256] = {0};
		proc_name(pids[i], name, sizeof(name));
		if (!name[0]) continue;
		[rows addObject:@{@"name": @(name), @"bytes": @(info.ri_phys_footprint), @"pid": @(pids[i])}];
	}
	[rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"bytes"] compare:a[@"bytes"]]; }];
	return [rows subarrayWithRange:NSMakeRange(0, MIN(count, rows.count))];
}

@end

#pragma mark - WhatsApp

@implementation TDWhatsAppChat
- (unsigned long long)total { return self.photos + self.videos + self.audio + self.documents + self.other; }
@end

static TDMediaKind TDKindForExtension(NSString *ext) {
	ext = ext.lowercaseString;
	static NSSet *photos, *videos, *audio, *documents;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		photos = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"heic", @"webp", @"gif"]];
		videos = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v", @"3gp"]];
		audio = [NSSet setWithArray:@[@"opus", @"m4a", @"mp3", @"aac", @"ogg", @"wav", @"caf"]];
		documents = [NSSet setWithArray:@[@"pdf", @"doc", @"docx", @"xls", @"xlsx", @"ppt", @"pptx", @"txt", @"zip", @"rar", @"key", @"pages", @"numbers", @"csv", @"apk"]];
	});
	if ([photos containsObject:ext]) return TDMediaPhotos;
	if ([videos containsObject:ext]) return TDMediaVideos;
	if ([audio containsObject:ext]) return TDMediaAudio;
	if ([documents containsObject:ext]) return TDMediaDocuments;
	return TDMediaOther; // thumbnails, stickers…
}

static NSString *TDFormatJID(NSString *jid, BOOL *isGroup) {
	NSString *number = [jid componentsSeparatedByString:@"@"].firstObject;
	*isGroup = [jid hasSuffix:@"@g.us"];
	if (*isGroup) return [NSString stringWithFormat:@"Group %@", number.length > 6 ? [number substringFromIndex:number.length - 6] : number];
	if ([number isEqualToString:@"0"]) return @"WhatsApp";
	return [@"+" stringByAppendingString:number];
}

@implementation TDWhatsApp

+ (NSDictionary<NSString *, NSString *> *)chatNamesFromDatabase:(NSString *)path {
	NSMutableDictionary *names = [NSMutableDictionary dictionary];
	sqlite3 *db = NULL;
	// Read-only and "immutable": never writes to WhatsApp's database or its journal.
	NSString *uri = [NSString stringWithFormat:@"file:%@?mode=ro&immutable=1", [path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]];
	if (sqlite3_open_v2(uri.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) { sqlite3_close(db); return names; }
	sqlite3_stmt *statement = NULL;
	if (sqlite3_prepare_v2(db, "SELECT ZCONTACTJID, ZPARTNERNAME FROM ZWACHATSESSION", -1, &statement, NULL) == SQLITE_OK) {
		while (sqlite3_step(statement) == SQLITE_ROW) {
			const unsigned char *jid = sqlite3_column_text(statement, 0), *name = sqlite3_column_text(statement, 1);
			if (jid && name && name[0]) names[@((const char *)jid)] = @((const char *)name);
		}
	}
	sqlite3_finalize(statement);
	sqlite3_close(db);
	return names;
}

+ (instancetype)scan {
	TDWhatsApp *result = [TDWhatsApp new];
	result.chats = @[];
	NSString *container = TDWhatsAppContainers().firstObject;
	if (!container) return result;
	result.containerPath = container;

	NSString *database = [container stringByAppendingPathComponent:@"ChatStorage.sqlite"];
	NSDate *lastUsed = [[NSFileManager defaultManager] attributesOfItemAtPath:database error:nil].fileModificationDate;
	result.lastUsed = lastUsed;
	result.hasActiveAccount = lastUsed && [[NSDate date] timeIntervalSinceDate:lastUsed] < 30 * 86400;
	NSDictionary *names = [self chatNamesFromDatabase:database];

	NSString *media = [container stringByAppendingPathComponent:@"Message/Media"];
	NSMutableArray *chats = [NSMutableArray array];
	for (NSString *jid in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:media error:nil]) {
		TDWhatsAppChat *chat = [TDWhatsAppChat new];
		chat.jid = jid;
		chat.path = [media stringByAppendingPathComponent:jid];
		BOOL isGroup = NO;
		NSString *fallback = TDFormatJID(jid, &isGroup);
		chat.isGroup = isGroup;
		chat.displayName = names[jid] ?: fallback;

		char *paths[] = {(char *)chat.path.fileSystemRepresentation, NULL};
		FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
		FTSENT *entry;
		while (fts && (entry = fts_read(fts))) {
			if (entry->fts_info != FTS_F || !entry->fts_statp) continue;
			unsigned long long size = (unsigned long long)entry->fts_statp->st_blocks * 512;
			switch (TDKindForExtension(@(entry->fts_name).pathExtension)) {
				case TDMediaPhotos: chat.photos += size; break;
				case TDMediaVideos: chat.videos += size; break;
				case TDMediaAudio: chat.audio += size; break;
				case TDMediaDocuments: chat.documents += size; break;
				default: chat.other += size; break;
			}
		}
		if (fts) fts_close(fts);
		if (chat.total > 0) [chats addObject:chat];
	}
	[chats sortUsingComparator:^NSComparisonResult(TDWhatsAppChat *a, TDWhatsAppChat *b) { return [@(b.total) compare:@(a.total)]; }];
	result.chats = chats;
	return result;
}

+ (unsigned long long)mediaInChat:(TDWhatsAppChat *)chat kinds:(TDMediaKind)kinds olderThanDays:(NSInteger)days delete:(BOOL)doDelete count:(NSUInteger *)count {
	if (![chat.path containsString:@"/Message/Media/"]) return 0;
	unsigned long long bytes = 0;
	NSUInteger files = 0;
	time_t cutoff = days > 0 ? time(NULL) - (time_t)days * 86400 : 0;
	char *paths[] = {(char *)chat.path.fileSystemRepresentation, NULL};
	FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
	FTSENT *entry;
	while (fts && (entry = fts_read(fts))) {
		if (entry->fts_info != FTS_F || !entry->fts_statp) continue;
		if (!(TDKindForExtension(@(entry->fts_name).pathExtension) & kinds)) continue;
		if (cutoff && entry->fts_statp->st_mtime > cutoff) continue;
		unsigned long long size = (unsigned long long)entry->fts_statp->st_blocks * 512;
		if (doDelete) {
			if (unlink(entry->fts_accpath) != 0) continue;
			// Remove the matching preview image too.
			NSString *thumb = [[@(entry->fts_accpath) stringByDeletingPathExtension] stringByAppendingPathExtension:@"thumb"];
			unlink(thumb.fileSystemRepresentation);
		}
		bytes += size;
		files++;
	}
	if (fts) fts_close(fts);
	if (count) *count = files;
	return bytes;
}

@end
