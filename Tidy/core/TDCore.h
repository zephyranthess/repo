// Tidy core: measuring and cleaning storage, reading memory stats.
// Shared by the Tidy app and the SpringBoard component (auto-clean).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define kTDSettingsPath @"/var/jb/var/mobile/Library/Preferences/com.yasin.tidy.plist"
#define kTDKillBackgroundNotification @"com.yasin.tidy.killbackground"   // reply: com.yasin.tidy.killbackground.done (userInfo: count)
#define kTDKillAppNotification        @"com.yasin.tidy.killapp"          // userInfo: bundleID

#pragma mark - Settings

typedef NS_ENUM(NSInteger, TDAutoClean) { TDAutoCleanOff = 0, TDAutoCleanWeekly = 1, TDAutoCleanLowSpace = 2 };

@interface TDSettings : NSObject
+ (NSMutableDictionary *)load;
+ (void)save:(NSDictionary *)settings;
+ (TDAutoClean)autoClean;
+ (double)lowSpaceGB;                         // threshold for TDAutoCleanLowSpace (default 5)
+ (BOOL)whatsAppEnabled;                      // default NO
+ (NSSet<NSString *> *)protectedApps;         // caches of these apps are never cleaned automatically
+ (BOOL)categoryEnabled:(NSString *)identifier defaultValue:(BOOL)value;
+ (void)recordClean:(unsigned long long)bytes automatic:(BOOL)automatic;
@end

#pragma mark - Sizes and deleting

unsigned long long TDSizeOfPath(NSString *path);
// Deletes everything inside `path` (not the folder itself). Files modified within `minAge`
// seconds are kept (in use). Returns the number of bytes freed.
unsigned long long TDDeleteContents(NSString *path, NSTimeInterval minAge);
unsigned long long TDDeleteFile(NSString *path);
NSString *TDFormatBytes(unsigned long long bytes);

#pragma mark - Apps

@interface TDApp : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong, nullable) NSURL *bundleURL;
@property (nonatomic, strong, nullable) NSURL *dataURL;
@property (nonatomic, copy) NSArray<NSURL *> *groupURLs;   // only groups that belong to this app
@property (nonatomic) BOOL isUserApp;
@property (nonatomic) unsigned long long appSize, dataSize, cacheSize;
@property (nonatomic, copy, nullable) NSString *iconName;
@property (nonatomic, copy, nullable) NSArray<NSString *> *iconFiles;

+ (NSArray<TDApp *> *)installedApps;          // user apps + Apple apps that have data
- (void)computeSizes;
- (NSArray<NSString *> *)cachePaths;         // Library/Caches, tmp, app-switcher snapshots, group caches
- (unsigned long long)clearCache;
- (unsigned long long)clearAllData;          // resets the app (user apps only)
@end

#pragma mark - Clean categories

@interface TDTarget : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic) NSTimeInterval minAge;
+ (instancetype)path:(NSString *)path minAge:(NSTimeInterval)minAge;
@end

@interface TDCategory : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic) BOOL defaultOn;
@property (nonatomic, copy) NSArray<TDTarget *> *targets;
@property (nonatomic) unsigned long long size;

+ (NSArray<TDCategory *> *)categoriesForApps:(NSArray<TDApp *> *)apps;
- (void)measure;
- (unsigned long long)clean;
@end

// Measures and cleans the enabled categories (used by auto-clean).
unsigned long long TDCleanEnabledCategories(void);

#pragma mark - Storage overview

@interface TDStorage : NSObject
@property (nonatomic) unsigned long long total, free;
@property (nonatomic) unsigned long long apps, appData, photos, messages, system;
+ (instancetype)measureWithApps:(NSArray<TDApp *> *)apps;   // slow: walks app folders
+ (void)diskTotal:(unsigned long long *)total free:(unsigned long long *)free;
@end

#pragma mark - Memory

@interface TDMemory : NSObject
@property (nonatomic) unsigned long long total;
@property (nonatomic) unsigned long long appMemory, wired, compressed, cached, free;
@property (nonatomic) int pressureLevel;   // 0-100: share of memory iOS considers available
+ (instancetype)current;
- (unsigned long long)available;          // free + cached (what apps can get quickly)
// Biggest processes by memory footprint: @[@{@"name", @"bytes", @"pid"}]
+ (NSArray<NSDictionary *> *)topProcesses:(NSUInteger)count;
@end

#pragma mark - WhatsApp media (off by default)

@interface TDWhatsAppChat : NSObject
@property (nonatomic, copy) NSString *jid;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic) BOOL isGroup;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) unsigned long long photos, videos, audio, documents, other;
- (unsigned long long)total;
@end

typedef NS_OPTIONS(NSUInteger, TDMediaKind) {
	TDMediaPhotos = 1 << 0, TDMediaVideos = 1 << 1, TDMediaAudio = 1 << 2, TDMediaDocuments = 1 << 3, TDMediaOther = 1 << 4,
	TDMediaAll = 0x1F,
};

@interface TDWhatsApp : NSObject
@property (nonatomic, copy, nullable) NSString *containerPath;   // nil if WhatsApp isn't installed
@property (nonatomic) BOOL hasActiveAccount;            // chat database changed in the last 30 days
@property (nonatomic, strong, nullable) NSDate *lastUsed;
@property (nonatomic, copy) NSArray<TDWhatsAppChat *> *chats;
+ (instancetype)scan;
// Count/size of matching files without deleting (preview), or delete them.
+ (unsigned long long)mediaInChat:(TDWhatsAppChat *)chat kinds:(TDMediaKind)kinds olderThanDays:(NSInteger)days delete:(BOOL)doDelete count:(NSUInteger *_Nullable)count;
@end

NS_ASSUME_NONNULL_END
