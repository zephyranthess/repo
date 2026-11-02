// XS Tweaks: a small app that opens the LineFix, SpeedBoost and CarCast settings pages.
// Needed because PreferenceLoader can't add pages to the iOS 18 Settings app.

#import <UIKit/UIKit.h>
#import <objc/message.h>


// CarCast pages live in CarCastSettings.m.
@interface XTCarCastController : UITableViewController
@end

@interface XTMenuController : UITableViewController
@end

@implementation XTMenuController {
	NSArray<NSArray<NSString *> *> *_items; // title, subtitle, bundle name, controller class
}

- (instancetype)init {
	self = [super initWithStyle:UITableViewStyleInsetGrouped];
	if (self) {
		self.title = @"XS Tweaks";
		// Only show pages for tweaks that are installed.
		NSFileManager *fm = [NSFileManager defaultManager];
		NSMutableArray *items = [NSMutableArray array];
		if ([fm fileExistsAtPath:@"/var/jb/Library/PreferenceBundles/LineFixPrefs.bundle"])
			[items addObject:@[@"LineFix", @"Hide the green/pink screen line", @"LineFixPrefs", @"LFRootListController"]];
		if ([fm fileExistsAtPath:@"/var/jb/Library/PreferenceBundles/SpeedBoostPrefs.bundle"])
			[items addObject:@[@"SpeedBoost", @"Faster animations, less background work", @"SpeedBoostPrefs", @"SBRootListController"]];
		if ([fm fileExistsAtPath:@"/var/jb/Library/MobileSubstrate/DynamicLibraries/CarCast.dylib"])
			[items addObject:@[@"CarCast", @"Any app on CarPlay · try it on the phone", @"", @"XTCarCastController"]];
		_items = items;
	}
	return self;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return _items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
	NSArray *item = _items[indexPath.row];
	cell.textLabel.text = item[0];
	cell.detailTextLabel.text = item[1];
	cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
	cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	NSArray *item = _items[indexPath.row];
	if ([item[2] length] == 0) {
		UIViewController *builtIn = [NSClassFromString(item[3]) new];
		[self.navigationController pushViewController:builtIn animated:YES];
		return;
	}
	NSString *path = [NSString stringWithFormat:@"/var/jb/Library/PreferenceBundles/%@.bundle", item[2]];
	NSBundle *bundle = [NSBundle bundleWithPath:path];
	NSError *error = nil;
	Class cls = ([bundle loadAndReturnError:&error]) ? NSClassFromString(item[3]) : Nil;
	if (!cls) {
		UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't open settings"
			message:error.localizedDescription ?: path preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
		return;
	}
	UIViewController *controller = [cls new];
	controller.title = item[0];
	[self.navigationController pushViewController:controller animated:YES];
}

@end

@interface XTAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation XTAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[XTMenuController new]];
	nav.navigationBar.prefersLargeTitles = YES;
	self.window.rootViewController = nav;
	[self.window makeKeyAndVisible];
#ifdef XT_AUTOTEST
	// Test build only: open the CarCast page and scroll through the app list.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		UITableViewController *page = [NSClassFromString(@"XTCarCastController") new];
		[nav pushViewController:page animated:NO];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			UITableView *table = page.tableView;
			for (NSInteger section = 0; section < table.numberOfSections; section++) {
				NSInteger rows = [table numberOfRowsInSection:section];
				if (rows) [table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:rows - 1 inSection:section] atScrollPosition:UITableViewScrollPositionBottom animated:NO];
				[table layoutIfNeeded];
			}
			NSLog(@"XT_AUTOTEST ok sections=%ld apps=%ld", (long)table.numberOfSections, (long)[table numberOfRowsInSection:1]);
			[@"ok" writeToFile:@"/var/mobile/Library/Caches/xt_autotest.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
		});
	});
#endif
	return YES;
}
@end

int main(int argc, char *argv[]) {
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([XTAppDelegate class]));
	}
}
