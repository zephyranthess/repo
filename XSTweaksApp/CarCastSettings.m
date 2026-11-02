// CarCast settings pages for the XS Tweaks app.
// Settings are saved to a plist that SpringBoard, the CarPlay process and apps can read.

#import <UIKit/UIKit.h>
#import <objc/message.h>

@interface NSDistributedNotificationCenter : NSNotificationCenter
+ (instancetype)defaultCenter;
- (void)postNotificationName:(NSString *)name object:(NSString *)object userInfo:(NSDictionary *)userInfo deliverImmediately:(BOOL)deliverImmediately;
@end

static NSString *const kSettingsPath = @"/var/jb/var/mobile/Library/Preferences/com.yasin.carcast.plist";

typedef NS_ENUM(NSInteger, XTPadMode) { XTPadModeAutomatic = 0, XTPadModeAlways = 1, XTPadModeNever = 2 };

#pragma mark - Settings store

@interface XTCarCastSettings : NSObject
+ (NSMutableDictionary *)load;
+ (void)save:(NSDictionary *)settings;
+ (BOOL)appEnabled:(NSString *)bundleID;
+ (void)setApp:(NSString *)bundleID enabled:(BOOL)enabled;
+ (XTPadMode)padModeForApp:(NSString *)bundleID;
+ (void)setPadMode:(XTPadMode)mode forApp:(NSString *)bundleID;
@end

@implementation XTCarCastSettings
+ (NSMutableDictionary *)load {
	return [[NSDictionary dictionaryWithContentsOfFile:kSettingsPath] mutableCopy] ?: [NSMutableDictionary dictionary];
}

+ (void)save:(NSDictionary *)settings {
	[settings writeToFile:kSettingsPath atomically:YES];
	[[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"com.yasin.carcast.settings" object:nil userInfo:nil deliverImmediately:YES];
}

+ (BOOL)appEnabled:(NSString *)bundleID {
	return ![[self load][@"disabledApps"] containsObject:bundleID];
}

+ (void)setApp:(NSString *)bundleID enabled:(BOOL)enabled {
	NSMutableDictionary *settings = [self load];
	NSMutableSet *disabled = [NSMutableSet setWithArray:settings[@"disabledApps"] ?: @[]];
	if (enabled) [disabled removeObject:bundleID]; else [disabled addObject:bundleID];
	settings[@"disabledApps"] = disabled.allObjects;
	[self save:settings];
}

+ (XTPadMode)padModeForApp:(NSString *)bundleID {
	return (XTPadMode)[[self load][@"padLayoutApps"][bundleID] integerValue];
}

+ (void)setPadMode:(XTPadMode)mode forApp:(NSString *)bundleID {
	NSMutableDictionary *settings = [self load];
	NSMutableDictionary *modes = [settings[@"padLayoutApps"] mutableCopy] ?: [NSMutableDictionary dictionary];
	if (mode == XTPadModeAutomatic) [modes removeObjectForKey:bundleID]; else modes[bundleID] = @(mode);
	settings[@"padLayoutApps"] = modes;
	[self save:settings];
}
@end

#pragma mark - Installed apps

// name, bundleID, supportsPad (BOOL), nativeCarPlay (BOOL)
static NSArray<NSDictionary *> *XTLoadApps(void) {
	NSMutableArray *apps = [NSMutableArray array];
	id workspace = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"LSApplicationWorkspace"), NSSelectorFromString(@"defaultWorkspace"));
	NSArray *proxies = ((id (*)(id, SEL))objc_msgSend)(workspace, NSSelectorFromString(@"allInstalledApplications"));
	for (id proxy in proxies) {
		NSString *type = [proxy valueForKey:@"applicationType"];
		NSString *bundleID = [proxy valueForKey:@"bundleIdentifier"];
		if (![type isEqualToString:@"User"] || !bundleID || [bundleID hasPrefix:@"com.apple."]) continue;
		NSString *name = [proxy valueForKey:@"localizedName"] ?: bundleID;

		NSURL *bundleURL = [proxy valueForKey:@"bundleURL"];
		NSDictionary *info = bundleURL ? [NSDictionary dictionaryWithContentsOfURL:[bundleURL URLByAppendingPathComponent:@"Info.plist"]] : nil;
		BOOL supportsPad = [info[@"UIDeviceFamily"] containsObject:@2];

		// Apps with their own CarPlay support have a CarPlay entitlement.
		BOOL native = NO;
		NSDictionary *entitlements = nil;
		@try { entitlements = [proxy valueForKey:@"entitlements"]; } @catch (NSException *e) {}
		for (NSString *key in entitlements) {
			if ([key hasPrefix:@"com.apple.developer.carplay"] || [key hasPrefix:@"com.apple.developer.playable-content"]) { native = YES; break; }
		}
		NSMutableDictionary *entry = [@{@"name": name, @"bundleID": bundleID, @"supportsPad": @(supportsPad), @"native": @(native)} mutableCopy];
		if (bundleURL) entry[@"bundleURL"] = bundleURL;
		NSDictionary *primary = info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"];
		if ([primary isKindOfClass:[NSDictionary class]]) {
			if (primary[@"CFBundleIconName"]) entry[@"iconName"] = primary[@"CFBundleIconName"];
			if (primary[@"CFBundleIconFiles"]) entry[@"iconFiles"] = primary[@"CFBundleIconFiles"];
		}
		[apps addObject:entry];
	}
	[apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
		return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
	}];
	return apps;
}

// Loads the app's icon from its own bundle. (The private IconServices route crashes
// in this app on some setups, so it's avoided.)
static UIImage *XTIcon(NSDictionary *app) {
	static NSCache *cache;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ cache = [NSCache new]; });
	UIImage *cached = [cache objectForKey:app[@"bundleID"]];
	if (cached) return cached;

	NSBundle *bundle = app[@"bundleURL"] ? [NSBundle bundleWithURL:app[@"bundleURL"]] : nil;
	UIImage *image = nil;
	if (bundle && app[@"iconName"]) {
		image = [UIImage imageNamed:app[@"iconName"] inBundle:bundle compatibleWithTraitCollection:nil];
	}
	for (NSString *file in [app[@"iconFiles"] reverseObjectEnumerator]) {
		if (image) break;
		image = [UIImage imageNamed:file inBundle:bundle compatibleWithTraitCollection:nil];
		if (!image) {
			NSString *path = [bundle pathForResource:[file stringByAppendingString:@"@2x"] ofType:@"png"] ?: [bundle pathForResource:file ofType:@"png"];
			if (path) image = [UIImage imageWithContentsOfFile:path];
		}
	}
	// Draw at list size with rounded corners; a grey tile if no icon was found.
	CGSize size = CGSizeMake(29, 29);
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
	UIImage *result = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
		UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height) cornerRadius:6.5];
		[clip addClip];
		if (image) {
			[image drawInRect:CGRectMake(0, 0, size.width, size.height)];
		} else {
			[[UIColor systemGray4Color] setFill];
			[clip fill];
		}
	}];
	[cache setObject:result forKey:app[@"bundleID"]];
	return result;
}

static void XTTestOnPhone(NSString *bundleID, NSString *size) {
	[[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"com.yasin.carcast.launch" object:nil
		userInfo:@{@"bundleID": bundleID, @"target": @"phone", @"size": size ?: @"800x480"} deliverImmediately:YES];
}

static NSString *XTPadModeName(XTPadMode mode) {
	switch (mode) {
		case XTPadModeAlways: return @"Always";
		case XTPadModeNever: return @"Never";
		default: return @"Automatic";
	}
}

#pragma mark - One app

@interface XTCarCastAppController : UITableViewController
- (instancetype)initWithApp:(NSDictionary *)app testSize:(NSString *)testSize;
@end

@implementation XTCarCastAppController {
	NSDictionary *_app;
	NSString *_testSize;
}

- (instancetype)initWithApp:(NSDictionary *)app testSize:(NSString *)testSize {
	self = [super initWithStyle:UITableViewStyleInsetGrouped];
	if (self) {
		_app = app;
		_testSize = testSize;
		self.title = app[@"name"];
	}
	return self;
}

- (NSString *)bundleID { return _app[@"bundleID"]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return section == 1 ? 3 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	return section == 1 ? @"iPad layout" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	if (section == 0) return @"Changes to which apps appear take effect the next time you connect to CarPlay.";
	if (section == 1) {
		return [_app[@"supportsPad"] boolValue]
			? @"This app has an iPad version. Automatic uses its iPad design on CarPlay when \"iPad layout\" is on in CarCast settings."
			: @"This app is iPhone-only. Automatic keeps the iPhone design. \"Always\" forces the iPad design, which may not work for this app.";
	}
	return @"Opens the app inside a fake car screen on the phone, using the simulated screen size from the CarCast page.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	if (indexPath.section == 0) {
		cell.textLabel.text = @"Show on CarPlay";
		UISwitch *toggle = [UISwitch new];
		toggle.on = [XTCarCastSettings appEnabled:self.bundleID];
		[toggle addTarget:self action:@selector(enabledChanged:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = toggle;
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
	} else if (indexPath.section == 1) {
		XTPadMode mode = (XTPadMode)indexPath.row;
		cell.textLabel.text = XTPadModeName(mode);
		cell.accessoryType = [XTCarCastSettings padModeForApp:self.bundleID] == mode ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	} else {
		cell.textLabel.text = @"Test on phone";
		cell.textLabel.textColor = self.view.tintColor;
	}
	return cell;
}

- (void)enabledChanged:(UISwitch *)toggle {
	[XTCarCastSettings setApp:self.bundleID enabled:toggle.on];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (indexPath.section == 1) {
		[XTCarCastSettings setPadMode:(XTPadMode)indexPath.row forApp:self.bundleID];
		[tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
	} else if (indexPath.section == 2) {
		XTTestOnPhone(self.bundleID, _testSize);
	}
}

@end

#pragma mark - CarCast main page

typedef NS_ENUM(NSInteger, XTSection) { XTSectionGeneral, XTSectionApps, XTSectionNative, XTSectionTest, XTSectionCount };

@interface XTCarCastController : UITableViewController
@end

@implementation XTCarCastController {
	NSArray<NSDictionary *> *_apps;    // apps CarCast can add
	NSArray<NSDictionary *> *_native;  // apps with their own CarPlay support
	NSArray<NSString *> *_sizes;
	NSUInteger _sizeIndex;
}

- (instancetype)init {
	self = [super initWithStyle:UITableViewStyleInsetGrouped];
	if (self) {
		self.title = @"CarCast";
		_sizes = @[@"800x480", @"1280x720", @"1920x720"];
		NSArray *all = XTLoadApps();
		_apps = [all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"native == NO"]];
		_native = [all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"native == YES"]];
	}
	return self;
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self.tableView reloadData]; // reflect changes made on an app's page
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return XTSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	switch (section) {
		case XTSectionGeneral: return 3;
		case XTSectionApps: return _apps.count + 1; // + "Show all / Hide all"
		case XTSectionNative: return _native.count;
		default: return 2;
	}
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	switch (section) {
		case XTSectionGeneral: return @"General";
		case XTSectionApps: return @"Apps on CarPlay";
		case XTSectionNative: return _native.count ? @"Already on CarPlay" : nil;
		default: return @"Test on the phone";
	}
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	switch (section) {
		case XTSectionGeneral:
			return @"iPad layout: apps that also exist for iPad (YouTube, Netflix…) use their iPad design on CarPlay, e.g. a video grid instead of one big video. The app restarts when you open or close it on CarPlay.\n\nText size changes how much the app is zoomed on the car screen.";
		case XTSectionApps:
			return @"Tap an app for more options. Changes to which apps appear take effect the next time you connect to CarPlay.";
		case XTSectionNative:
			return _native.count ? @"These apps have their own CarPlay version. CarCast leaves them alone." : nil;
		default:
			return @"Runs an app inside a fake car screen on the phone. The house button closes it.";
	}
}

- (UITableViewCell *)generalCellForRow:(NSInteger)row {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	NSDictionary *settings = [XTCarCastSettings load];
	if (row == 0) {
		cell.textLabel.text = @"iPad layout";
		UISwitch *toggle = [UISwitch new];
		toggle.on = settings[@"padLayout"] ? [settings[@"padLayout"] boolValue] : YES;
		[toggle addTarget:self action:@selector(padLayoutChanged:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = toggle;
	} else if (row == 1) {
		cell.textLabel.text = @"Dock side";
		UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:@[@"Left", @"Right"]];
		control.selectedSegmentIndex = [settings[@"dockSide"] isEqual:@"right"] ? 1 : 0;
		[control addTarget:self action:@selector(dockSideChanged:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = control;
	} else {
		cell.textLabel.text = @"Text size";
		UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:@[@"Large", @"Normal", @"Small"]];
		NSInteger height = settings[@"appHeight"] ? [settings[@"appHeight"] integerValue] : 480;
		control.selectedSegmentIndex = height <= 400 ? 0 : (height >= 600 ? 2 : 1);
		[control addTarget:self action:@selector(textSizeChanged:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = control;
	}
	[cell.accessoryView sizeToFit];
	return cell;
}

- (UITableViewCell *)appCell:(NSDictionary *)app native:(BOOL)native {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
	cell.textLabel.text = app[@"name"];
	cell.imageView.image = XTIcon(app);
	cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
	if (native) {
		cell.detailTextLabel.text = @"Uses its own CarPlay app";
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
		return cell;
	}
	BOOL enabled = [XTCarCastSettings appEnabled:app[@"bundleID"]];
	XTPadMode mode = [XTCarCastSettings padModeForApp:app[@"bundleID"]];
	NSString *pad = mode == XTPadModeAutomatic
		? ([app[@"supportsPad"] boolValue] ? @"iPad layout: Automatic" : @"iPhone-only")
		: [@"iPad layout: " stringByAppendingString:XTPadModeName(mode)];
	cell.detailTextLabel.text = enabled ? pad : @"Hidden";
	cell.textLabel.alpha = enabled ? 1 : 0.45;
	cell.imageView.alpha = enabled ? 1 : 0.45;

	UISwitch *toggle = [UISwitch new];
	toggle.on = enabled;
	toggle.accessibilityIdentifier = app[@"bundleID"];
	[toggle addTarget:self action:@selector(appToggled:) forControlEvents:UIControlEventValueChanged];
	cell.accessoryView = toggle;
	return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	switch (indexPath.section) {
		case XTSectionGeneral:
			return [self generalCellForRow:indexPath.row];
		case XTSectionApps: {
			if (indexPath.row == 0) {
				UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
				BOOL anyEnabled = NO;
				for (NSDictionary *app in _apps) anyEnabled |= [XTCarCastSettings appEnabled:app[@"bundleID"]];
				cell.textLabel.text = anyEnabled ? @"Hide all" : @"Show all";
				cell.textLabel.textColor = self.view.tintColor;
				return cell;
			}
			return [self appCell:_apps[indexPath.row - 1] native:NO];
		}
		case XTSectionNative:
			return [self appCell:_native[indexPath.row] native:YES];
		default: {
			UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
			if (indexPath.row == 0) {
				cell.textLabel.text = @"Simulated car screen";
				cell.detailTextLabel.text = [_sizes[_sizeIndex] stringByReplacingOccurrencesOfString:@"x" withString:@" × "];
			} else {
				cell.textLabel.text = @"Close test window";
				cell.textLabel.textColor = [UIColor systemRedColor];
			}
			return cell;
		}
	}
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (indexPath.section == XTSectionApps) {
		if (indexPath.row == 0) {
			[self toggleAll];
			return;
		}
		XTCarCastAppController *page = [[XTCarCastAppController alloc] initWithApp:_apps[indexPath.row - 1] testSize:_sizes[_sizeIndex]];
		[self.navigationController pushViewController:page animated:YES];
	} else if (indexPath.section == XTSectionTest) {
		if (indexPath.row == 0) {
			_sizeIndex = (_sizeIndex + 1) % _sizes.count;
			[tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
		} else {
			[[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"com.yasin.carcast.close" object:nil userInfo:nil deliverImmediately:YES];
		}
	}
}

#pragma mark Actions

- (void)toggleAll {
	BOOL anyEnabled = NO;
	for (NSDictionary *app in _apps) anyEnabled |= [XTCarCastSettings appEnabled:app[@"bundleID"]];
	NSMutableDictionary *settings = [XTCarCastSettings load];
	settings[@"disabledApps"] = anyEnabled ? [_apps valueForKey:@"bundleID"] : @[];
	[XTCarCastSettings save:settings];
	[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:XTSectionApps] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)appToggled:(UISwitch *)toggle {
	[XTCarCastSettings setApp:toggle.accessibilityIdentifier enabled:toggle.on];
	[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:XTSectionApps] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)padLayoutChanged:(UISwitch *)toggle {
	NSMutableDictionary *settings = [XTCarCastSettings load];
	settings[@"padLayout"] = @(toggle.on);
	[XTCarCastSettings save:settings];
}

- (void)dockSideChanged:(UISegmentedControl *)control {
	NSMutableDictionary *settings = [XTCarCastSettings load];
	settings[@"dockSide"] = control.selectedSegmentIndex == 1 ? @"right" : @"left";
	[XTCarCastSettings save:settings];
}

- (void)textSizeChanged:(UISegmentedControl *)control {
	NSMutableDictionary *settings = [XTCarCastSettings load];
	settings[@"appHeight"] = @[@400, @480, @600][control.selectedSegmentIndex];
	[XTCarCastSettings save:settings];
}

@end
