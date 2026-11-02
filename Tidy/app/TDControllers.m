// Tidy app screens.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "TDViews.h"
#import "../core/TDCore.h"

@interface NSDistributedNotificationCenter : NSNotificationCenter
+ (instancetype)defaultCenter;
- (void)postNotificationName:(NSString *)name object:(NSString *)object userInfo:(NSDictionary *)userInfo deliverImmediately:(BOOL)deliverImmediately;
@end

static NSString *const TDDataChangedNotification = @"TDDataChanged";

static NSString *TDBytes(double bytes) { return TDFormatBytes((unsigned long long)MAX(0, bytes)); }

static void TDAlert(UIViewController *presenter, NSString *title, NSString *message) {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
	[presenter presentViewController:alert animated:YES completion:nil];
}

static void TDConfirm(UIViewController *presenter, NSString *title, NSString *message, NSString *action, BOOL destructive, void (^handler)(void)) {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:action style:destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault handler:^(UIAlertAction *a) { handler(); }]];
	[presenter presentViewController:alert animated:YES completion:nil];
}

// Shows a spinner over the view while `work` runs in the background.
static void TDRunWithSpinner(UIViewController *controller, NSString *text, id (^work)(void), void (^done)(id result)) {
	UIView *host = controller.navigationController.view ?: controller.view;
	UIView *overlay = [[UIView alloc] initWithFrame:host.bounds];
	overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.35];
	overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	UIView *box = [UIView new];
	box.backgroundColor = [UIColor secondarySystemBackgroundColor];
	box.layer.cornerRadius = 16;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
	[spinner startAnimating];
	UILabel *label = [UILabel new];
	label.text = text;
	label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
	UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[spinner, label]];
	stack.axis = UILayoutConstraintAxisVertical;
	stack.spacing = 12;
	stack.alignment = UIStackViewAlignmentCenter;
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	[box addSubview:stack];
	[overlay addSubview:box];
	[NSLayoutConstraint activateConstraints:@[
		[box.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
		[box.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
		[stack.topAnchor constraintEqualToAnchor:box.topAnchor constant:24],
		[stack.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-24],
		[stack.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:32],
		[stack.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-32],
	]];
	[host addSubview:overlay];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		id result = work();
		dispatch_async(dispatch_get_main_queue(), ^{
			[overlay removeFromSuperview];
			done(result);
		});
	});
}

static void TDKillApp(NSString *bundleID) {
	[[NSDistributedNotificationCenter defaultCenter] postNotificationName:kTDKillAppNotification object:nil userInfo:@{@"bundleID": bundleID} deliverImmediately:YES];
}

#pragma mark - Data store

@interface TDStore : NSObject
@property (nonatomic, copy) NSArray<TDApp *> *apps;
@property (nonatomic, copy) NSArray<TDCategory *> *categories;
@property (nonatomic, strong) TDStorage *storage;
@property (nonatomic) BOOL scanning;
+ (instancetype)shared;
- (void)refresh;
- (unsigned long long)cleanableBytes;
@end

@implementation TDStore
+ (instancetype)shared {
	static TDStore *store;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ store = [TDStore new]; });
	return store;
}

- (void)refresh {
	if (self.scanning) return;
	self.scanning = YES;
	[[NSNotificationCenter defaultCenter] postNotificationName:TDDataChangedNotification object:nil];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSArray *apps = [TDApp installedApps];
		for (TDApp *app in apps) [app computeSizes];
		NSArray *categories = [TDCategory categoriesForApps:apps];
		for (TDCategory *category in categories) [category measure];
		TDStorage *storage = [TDStorage measureWithApps:apps];
		dispatch_async(dispatch_get_main_queue(), ^{
			self.apps = [apps sortedArrayUsingComparator:^NSComparisonResult(TDApp *a, TDApp *b) {
				return [@(b.appSize + b.dataSize) compare:@(a.appSize + a.dataSize)];
			}];
			self.categories = categories;
			self.storage = storage;
			self.scanning = NO;
			[[NSNotificationCenter defaultCenter] postNotificationName:TDDataChangedNotification object:nil];
		});
	});
}

- (unsigned long long)cleanableBytes {
	unsigned long long total = 0;
	for (TDCategory *category in self.categories) {
		if ([TDSettings categoryEnabled:category.identifier defaultValue:category.defaultOn]) total += category.size;
	}
	return total;
}
@end

#pragma mark - Overview

@interface TDOverviewController : UIViewController
@end

@implementation TDOverviewController {
	UIScrollView *_scroll;
	TDBarCard *_storageCard, *_memoryCard;
	TDStatusPill *_pressure;
	UIStackView *_processList;
	UILabel *_cleanableLabel, *_lastCleanLabel, *_killResult;
	NSTimer *_timer;
}

- (instancetype)init {
	if ((self = [super init])) {
		self.title = @"Tidy";
		self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Overview" image:[UIImage systemImageNamed:@"chart.bar.xaxis"] tag:0];
	}
	return self;
}

- (UIView *)cardWithViews:(NSArray<UIView *> *)views {
	UIView *card = [UIView new];
	card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
	card.layer.cornerRadius = 14;
	UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
	stack.axis = UILayoutConstraintAxisVertical;
	stack.spacing = 10;
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:stack];
	[NSLayoutConstraint activateConstraints:@[
		[stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
		[stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
		[stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
		[stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
	]];
	return card;
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight secondary:(BOOL)secondary {
	UILabel *label = [UILabel new];
	label.text = text;
	label.font = [UIFont systemFontOfSize:size weight:weight];
	label.textColor = secondary ? [UIColor secondaryLabelColor] : [UIColor labelColor];
	label.numberOfLines = 0;
	return label;
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action filled:(BOOL)filled {
	UIButtonConfiguration *config = filled ? [UIButtonConfiguration filledButtonConfiguration] : [UIButtonConfiguration tintedButtonConfiguration];
	config.title = title;
	config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
	config.buttonSize = UIButtonConfigurationSizeLarge;
	UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
	[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
	return button;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
	self.navigationController.navigationBar.prefersLargeTitles = YES;

	_scroll = [UIScrollView new];
	_scroll.alwaysBounceVertical = YES;
	_scroll.translatesAutoresizingMaskIntoConstraints = NO;
	UIRefreshControl *refresh = [UIRefreshControl new];
	[refresh addTarget:self action:@selector(pullToRefresh:) forControlEvents:UIControlEventValueChanged];
	_scroll.refreshControl = refresh;
	[self.view addSubview:_scroll];

	_storageCard = [TDBarCard new];
	_storageCard.titleLabel.text = @"STORAGE";
	_memoryCard = [TDBarCard new];
	_memoryCard.titleLabel.text = @"MEMORY";
	_pressure = [TDStatusPill new];
	// Insert the pressure pill under the memory headline.
	UIStackView *memoryStack = (UIStackView *)_memoryCard.headlineLabel.superview;
	[memoryStack insertArrangedSubview:_pressure atIndex:2];

	_cleanableLabel = [self label:@"Measuring…" size:28 weight:UIFontWeightBold secondary:NO];
	_lastCleanLabel = [self label:@"" size:15 weight:UIFontWeightRegular secondary:YES];
	UIView *cleanCard = [self cardWithViews:@[
		[self label:@"CLEANABLE NOW" size:15 weight:UIFontWeightSemibold secondary:YES],
		_cleanableLabel, _lastCleanLabel,
		[self buttonWithTitle:@"Review & Clean" action:@selector(openClean) filled:YES],
	]];

	_processList = [UIStackView new];
	_processList.axis = UILayoutConstraintAxisVertical;
	_processList.spacing = 6;
	_killResult = [self label:@"" size:15 weight:UIFontWeightRegular secondary:YES];
	_killResult.hidden = YES;
	UIView *processCard = [self cardWithViews:@[
		[self label:@"USING THE MOST MEMORY" size:15 weight:UIFontWeightSemibold secondary:YES],
		_processList,
		[self buttonWithTitle:@"Close Background Apps" action:@selector(closeBackgroundApps) filled:NO],
		_killResult,
		[self label:@"iOS frees memory by itself when an app needs it, so this is rarely necessary. Use it when the phone feels stuck. Closed apps start a little slower next time." size:13 weight:UIFontWeightRegular secondary:YES],
	]];

	UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[_storageCard, cleanCard, _memoryCard, processCard]];
	content.axis = UILayoutConstraintAxisVertical;
	content.spacing = 16;
	content.translatesAutoresizingMaskIntoConstraints = NO;
	[_scroll addSubview:content];
	[NSLayoutConstraint activateConstraints:@[
		[_scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
		[_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[content.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:8],
		[content.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-24],
		[content.leadingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.leadingAnchor constant:16],
		[content.trailingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.trailingAnchor constant:-16],
	]];

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadStorage) name:TDDataChangedNotification object:nil];
	[[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(backgroundAppsClosed:) name:@"com.yasin.tidy.killbackground.done" object:nil];
	[self reloadStorage];
	[self reloadMemory];
	if (![TDStore shared].storage) [[TDStore shared] refresh];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self reloadStorage];
	_timer = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(reloadMemory) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[_timer invalidate];
}

- (void)pullToRefresh:(UIRefreshControl *)control {
	[[TDStore shared] refresh];
	[self reloadMemory];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [control endRefreshing]; });
}

- (void)reloadStorage {
	TDStore *store = [TDStore shared];
	TDStorage *storage = store.storage;
	unsigned long long total = 0, free = 0;
	[TDStorage diskTotal:&total free:&free];
	_storageCard.headlineLabel.text = [NSString stringWithFormat:@"%@ free", TDBytes(free)];
	if (!storage) {
		_storageCard.captionLabel.text = [NSString stringWithFormat:@"of %@ · Measuring what's using space…", TDBytes(total)];
		[_storageCard setSegments:@[[TDSegment name:@"Used" value:total - free color:TDSeriesColor(0)], [TDSegment name:@"Free" value:free color:TDFreeColor()]]
		                formatter:^NSString *(double v) { return TDBytes(v); }];
	} else {
		_storageCard.captionLabel.text = [NSString stringWithFormat:@"of %@ · %@ used", TDBytes(storage.total), TDBytes(storage.total - storage.free)];
		[_storageCard setSegments:@[
			[TDSegment name:@"Apps" value:storage.apps color:TDSeriesColor(0)],
			[TDSegment name:@"App data" value:storage.appData color:TDSeriesColor(1)],
			[TDSegment name:@"Photos" value:storage.photos color:TDSeriesColor(2)],
			[TDSegment name:@"Messages & WhatsApp" value:storage.messages color:TDSeriesColor(3)],
			[TDSegment name:@"iOS & system" value:storage.system color:TDSeriesColor(4)],
			[TDSegment name:@"Free" value:storage.free color:TDFreeColor()],
		] formatter:^NSString *(double v) { return TDBytes(v); }];
	}
	_cleanableLabel.text = store.categories ? TDBytes([store cleanableBytes]) : (store.scanning ? @"Measuring…" : @"—");
	NSDictionary *last = [TDSettings load][@"lastClean"];
	if (last[@"date"]) {
		NSString *when = [NSDateFormatter localizedStringFromDate:last[@"date"] dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle];
		_lastCleanLabel.text = [NSString stringWithFormat:@"Last cleaned %@%@: %@ freed", [last[@"automatic"] boolValue] ? @"automatically " : @"", when, TDBytes([last[@"bytes"] doubleValue])];
	} else {
		_lastCleanLabel.text = @"Safe to remove: caches, temporary files and logs. Apps and iOS recreate what they need.";
	}
}

- (void)reloadMemory {
	TDMemory *memory = [TDMemory current];
	_memoryCard.headlineLabel.text = [NSString stringWithFormat:@"%@ available", TDBytes(memory.available)];
	_memoryCard.captionLabel.text = [NSString stringWithFormat:@"of %@ total. Cached memory is given back instantly when an app needs it.", TDBytes(memory.total)];
	[_memoryCard setSegments:@[
		[TDSegment name:@"Apps" value:memory.appMemory color:TDSeriesColor(0)],
		[TDSegment name:@"iOS & system" value:memory.wired color:TDSeriesColor(1)],
		[TDSegment name:@"Compressed" value:memory.compressed color:TDSeriesColor(2)],
		[TDSegment name:@"Cached" value:memory.cached color:TDSeriesColor(3)],
		[TDSegment name:@"Free" value:memory.free color:TDFreeColor()],
	] formatter:^NSString *(double v) { return TDBytes(v); }];

	int level = memory.pressureLevel;
	if (level < 0) [_pressure setText:@"Memory pressure: unknown" symbol:@"questionmark.circle" color:[UIColor secondaryLabelColor]];
	else if (level >= 40) [_pressure setText:@"Memory pressure: normal" symbol:@"checkmark.circle.fill" color:TDStatusGood()];
	else if (level >= 20) [_pressure setText:@"Memory pressure: elevated" symbol:@"exclamationmark.triangle.fill" color:TDStatusWarning()];
	else [_pressure setText:@"Memory pressure: high" symbol:@"xmark.octagon.fill" color:TDStatusCritical()];

	for (UIView *view in _processList.arrangedSubviews) [view removeFromSuperview];
	NSArray *processes = [TDMemory topProcesses:5];
	if (processes.count == 0) {
		[_processList addArrangedSubview:[self label:@"Not available on this device." size:15 weight:UIFontWeightRegular secondary:YES]];
	}
	for (NSDictionary *process in processes) {
		UILabel *name = [self label:process[@"name"] size:15 weight:UIFontWeightRegular secondary:NO];
		name.numberOfLines = 1;
		UILabel *size = [self label:TDBytes([process[@"bytes"] doubleValue]) size:15 weight:UIFontWeightRegular secondary:YES];
		size.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
		[size setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
		UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[name, size]];
		[_processList addArrangedSubview:row];
	}
}

- (void)openClean {
	self.tabBarController.selectedIndex = 1;
}

- (void)closeBackgroundApps {
	_killResult.hidden = NO;
	_killResult.text = @"Closing…";
	[[NSDistributedNotificationCenter defaultCenter] postNotificationName:kTDKillBackgroundNotification object:nil userInfo:nil deliverImmediately:YES];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if ([self->_killResult.text isEqualToString:@"Closing…"]) self->_killResult.text = @"No answer from SpringBoard. Respring once after installing Tidy.";
	});
}

- (void)backgroundAppsClosed:(NSNotification *)note {
	dispatch_async(dispatch_get_main_queue(), ^{
		NSInteger count = [note.userInfo[@"count"] integerValue];
		self->_killResult.text = count == 0 ? @"No background apps were running." : [NSString stringWithFormat:@"Closed %ld background app%@.", (long)count, count == 1 ? @"" : @"s"];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self reloadMemory]; });
	});
}

@end

#pragma mark - WhatsApp media

@interface TDWhatsAppController : UITableViewController
@end

@implementation TDWhatsAppController {
	TDWhatsApp *_whatsApp;
	TDMediaKind _kinds;
	NSInteger _ageIndex;
	NSMutableSet<NSString *> *_selected;
}

static NSArray *TDAgeDays(void) { return @[@0, @30, @90, @180, @365]; }

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
		self.title = @"WhatsApp Media";
		_kinds = TDMediaVideos;
		_ageIndex = 3; // older than 6 months
		_selected = [NSMutableSet set];
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	[self rescan];
}

- (void)rescan {
	TDRunWithSpinner(self, @"Reading WhatsApp media…", ^id{ return [TDWhatsApp scan]; }, ^(TDWhatsApp *result) {
		self->_whatsApp = result;
		[self.tableView reloadData];
	});
}

- (unsigned long long)totalMedia {
	unsigned long long total = 0;
	for (TDWhatsAppChat *chat in _whatsApp.chats) total += chat.total;
	return total;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _whatsApp.containerPath ? 4 : 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	if (!_whatsApp.containerPath) return 0;
	switch (section) {
		case 0: return 0;           // header card only
		case 1: return 6;           // 5 kinds + age
		case 2: return 1;           // delete button
		default: return _whatsApp.chats.count;
	}
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
	if (section != 0) return nil;
	TDBarCard *card = [TDBarCard new];
	if (!_whatsApp) { card.headlineLabel.text = @"…"; return card; }
	if (!_whatsApp.containerPath) {
		card.titleLabel.text = @"WHATSAPP";
		card.headlineLabel.text = @"Not installed";
		card.captionLabel.text = @"There is no WhatsApp media on this phone.";
		return card;
	}
	card.titleLabel.text = @"WHATSAPP MEDIA";
	card.headlineLabel.text = TDBytes([self totalMedia]);
	NSString *activity = _whatsApp.hasActiveAccount ? @"In use." :
		(_whatsApp.lastUsed ? [NSString stringWithFormat:@"Not used since %@. The account may be signed out; this media is left over.",
			[NSDateFormatter localizedStringFromDate:_whatsApp.lastUsed dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterNoStyle]] : @"No chats found.");
	card.captionLabel.text = [NSString stringWithFormat:@"%lu chats with media. %@", (unsigned long)_whatsApp.chats.count, activity];
	unsigned long long photos = 0, videos = 0, audio = 0, documents = 0, other = 0;
	for (TDWhatsAppChat *chat in _whatsApp.chats) { photos += chat.photos; videos += chat.videos; audio += chat.audio; documents += chat.documents; other += chat.other; }
	[card setSegments:@[
		[TDSegment name:@"Photos" value:photos color:TDSeriesColor(0)],
		[TDSegment name:@"Videos" value:videos color:TDSeriesColor(1)],
		[TDSegment name:@"Voice & audio" value:audio color:TDSeriesColor(2)],
		[TDSegment name:@"Documents" value:documents color:TDSeriesColor(3)],
		[TDSegment name:@"Stickers & previews" value:other color:TDSeriesColor(4)],
	] formatter:^NSString *(double v) { return TDBytes(v); }];
	return card;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	switch (section) {
		case 1: return @"What to delete";
		case 3: return @"Chats (tap to choose; none chosen = all chats)";
		default: return nil;
	}
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	if (section == 2) return @"You'll see how many files match before anything is deleted. Deleted media can't be recovered; the messages stay, and WhatsApp shows the media as unavailable.";
	return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
	if (indexPath.section == 1) {
		if (indexPath.row < 5) {
			NSArray *names = @[@"Videos", @"Photos", @"Voice & audio", @"Documents", @"Stickers & previews"];
			NSArray *kinds = @[@(TDMediaVideos), @(TDMediaPhotos), @(TDMediaAudio), @(TDMediaDocuments), @(TDMediaOther)];
			cell.textLabel.text = names[indexPath.row];
			cell.accessoryType = (_kinds & [kinds[indexPath.row] unsignedIntegerValue]) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
		} else {
			cell.textLabel.text = @"Older than";
			UISegmentedControl *age = [[UISegmentedControl alloc] initWithItems:@[@"Any", @"1 mo", @"3 mo", @"6 mo", @"1 yr"]];
			age.selectedSegmentIndex = _ageIndex;
			[age addTarget:self action:@selector(ageChanged:) forControlEvents:UIControlEventValueChanged];
			[age sizeToFit];
			cell.accessoryView = age;
			cell.selectionStyle = UITableViewCellSelectionStyleNone;
		}
	} else if (indexPath.section == 2) {
		cell.textLabel.text = _selected.count ? [NSString stringWithFormat:@"Delete from %lu chosen chat%@…", (unsigned long)_selected.count, _selected.count == 1 ? @"" : @"s"] : @"Delete from all chats…";
		cell.textLabel.textColor = [UIColor systemRedColor];
	} else {
		TDWhatsAppChat *chat = _whatsApp.chats[indexPath.row];
		cell.textLabel.text = chat.displayName;
		cell.detailTextLabel.text = TDBytes(chat.total);
		cell.imageView.image = [UIImage systemImageNamed:chat.isGroup ? @"person.3.fill" : @"person.fill"];
		cell.imageView.tintColor = [UIColor secondaryLabelColor];
		cell.accessoryType = [_selected containsObject:chat.jid] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	}
	return cell;
}

- (void)ageChanged:(UISegmentedControl *)control { _ageIndex = control.selectedSegmentIndex; }

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (indexPath.section == 1 && indexPath.row < 5) {
		NSArray *kinds = @[@(TDMediaVideos), @(TDMediaPhotos), @(TDMediaAudio), @(TDMediaDocuments), @(TDMediaOther)];
		_kinds ^= [kinds[indexPath.row] unsignedIntegerValue];
		[tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
	} else if (indexPath.section == 2) {
		[self previewAndDelete];
	} else if (indexPath.section == 3) {
		NSString *jid = _whatsApp.chats[indexPath.row].jid;
		if ([_selected containsObject:jid]) [_selected removeObject:jid]; else [_selected addObject:jid];
		[tableView reloadData];
	}
}

- (NSArray<TDWhatsAppChat *> *)targetChats {
	if (_selected.count == 0) return _whatsApp.chats;
	return [_whatsApp.chats filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(TDWhatsAppChat *chat, NSDictionary *b) {
		return [self->_selected containsObject:chat.jid];
	}]];
}

- (void)previewAndDelete {
	if (_kinds == 0) { TDAlert(self, @"Nothing selected", @"Choose at least one kind of media to delete."); return; }
	NSArray *chats = [self targetChats];
	TDMediaKind kinds = _kinds;
	NSInteger days = [TDAgeDays()[_ageIndex] integerValue];
	TDRunWithSpinner(self, @"Counting files…", ^id{
		unsigned long long bytes = 0; NSUInteger files = 0;
		for (TDWhatsAppChat *chat in chats) {
			NSUInteger count = 0;
			bytes += [TDWhatsApp mediaInChat:chat kinds:kinds olderThanDays:days delete:NO count:&count];
			files += count;
		}
		return @[@(bytes), @(files)];
	}, ^(NSArray *preview) {
		if ([preview[1] unsignedIntegerValue] == 0) { TDAlert(self, @"Nothing to delete", @"No files match these choices."); return; }
		NSString *message = [NSString stringWithFormat:@"%@ files (%@) will be permanently deleted from %lu chat%@.", preview[1], TDBytes([preview[0] doubleValue]), (unsigned long)chats.count, chats.count == 1 ? @"" : @"s"];
		TDConfirm(self, @"Delete WhatsApp media?", message, @"Delete", YES, ^{
			TDKillApp(@"net.whatsapp.WhatsApp");
			TDRunWithSpinner(self, @"Deleting…", ^id{
				[NSThread sleepForTimeInterval:0.5];
				unsigned long long freed = 0;
				for (TDWhatsAppChat *chat in chats) freed += [TDWhatsApp mediaInChat:chat kinds:kinds olderThanDays:days delete:YES count:NULL];
				[TDSettings recordClean:freed automatic:NO];
				return @(freed);
			}, ^(NSNumber *freed) {
				TDAlert(self, @"Done", [NSString stringWithFormat:@"%@ freed.", TDBytes(freed.doubleValue)]);
				[self->_selected removeAllObjects];
				[self rescan];
				[[TDStore shared] refresh];
			});
		});
	});
}

@end

#pragma mark - Clean

@interface TDCleanController : UITableViewController
@end

@implementation TDCleanController

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
		self.title = @"Clean";
		self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Clean" image:[UIImage systemImageNamed:@"sparkles"] tag:1];
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	[[NSNotificationCenter defaultCenter] addObserver:self.tableView selector:@selector(reloadData) name:TDDataChangedNotification object:nil];
	UIRefreshControl *refresh = [UIRefreshControl new];
	[refresh addTarget:self action:@selector(pullToRefresh:) forControlEvents:UIControlEventValueChanged];
	self.refreshControl = refresh;
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self.tableView reloadData];
}

- (void)pullToRefresh:(UIRefreshControl *)control {
	[[TDStore shared] refresh];
	[control endRefreshing];
}

- (NSArray<TDCategory *> *)categories { return [TDStore shared].categories ?: @[]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return [TDSettings whatsAppEnabled] ? 3 : 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	if (section == 0) return 1;
	if (section == 1) return [TDStore shared].scanning && self.categories.count == 0 ? 1 : self.categories.count;
	return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	return section == 1 ? @"Safe to remove" : (section == 2 ? @"Your files" : nil);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	if (section == 1) return @"Tap a row for details. Switched-on items are also used by auto-clean. Caches of protected apps (Settings tab) are skipped.";
	if (section == 2) return @"Photos, videos and documents from chats. Nothing is deleted until you confirm.";
	return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
	TDStore *store = [TDStore shared];
	if (indexPath.section == 0) {
		unsigned long long total = [store cleanableBytes];
		cell.textLabel.text = store.categories ? [NSString stringWithFormat:@"Clean %@", TDBytes(total)] : @"Measuring…";
		cell.textLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
		cell.textLabel.textColor = store.categories && total > 0 ? self.view.tintColor : [UIColor secondaryLabelColor];
		cell.imageView.image = [UIImage systemImageNamed:@"sparkles"];
		return cell;
	}
	if (indexPath.section == 2) {
		cell.textLabel.text = @"WhatsApp media";
		cell.detailTextLabel.text = @"Delete old videos, photos and documents by chat";
		cell.imageView.image = [UIImage systemImageNamed:@"bubble.left.and.bubble.right"];
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		return cell;
	}
	if (self.categories.count == 0) {
		cell.textLabel.text = @"Measuring…";
		return cell;
	}
	TDCategory *category = self.categories[indexPath.row];
	cell.textLabel.text = category.title;
	cell.detailTextLabel.text = TDBytes(category.size);
	cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
	cell.imageView.image = [UIImage systemImageNamed:category.symbol];
	UISwitch *toggle = [UISwitch new];
	toggle.on = [TDSettings categoryEnabled:category.identifier defaultValue:category.defaultOn];
	toggle.tag = indexPath.row;
	[toggle addTarget:self action:@selector(categoryToggled:) forControlEvents:UIControlEventValueChanged];
	cell.accessoryView = toggle;
	return cell;
}

- (void)categoryToggled:(UISwitch *)toggle {
	TDCategory *category = self.categories[toggle.tag];
	NSMutableDictionary *settings = [TDSettings load];
	NSMutableDictionary *categories = [settings[@"categories"] mutableCopy] ?: [NSMutableDictionary dictionary];
	categories[category.identifier] = @(toggle.on);
	settings[@"categories"] = categories;
	[TDSettings save:settings];
	[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (indexPath.section == 0) {
		[self clean];
	} else if (indexPath.section == 1 && self.categories.count) {
		TDCategory *category = self.categories[indexPath.row];
		TDAlert(self, category.title, category.detail);
	} else if (indexPath.section == 2) {
		[self.navigationController pushViewController:[TDWhatsAppController new] animated:YES];
	}
}

- (void)clean {
	TDStore *store = [TDStore shared];
	if (!store.categories) return;
	NSMutableArray *chosen = [NSMutableArray array];
	for (TDCategory *category in store.categories) {
		if ([TDSettings categoryEnabled:category.identifier defaultValue:category.defaultOn] && category.size > 0) [chosen addObject:category];
	}
	if (chosen.count == 0) { TDAlert(self, @"Nothing to clean", @"Switch on at least one item with something in it."); return; }
	NSString *list = [[chosen valueForKey:@"title"] componentsJoinedByString:@", "];
	TDConfirm(self, [NSString stringWithFormat:@"Clean %@?", TDBytes([store cleanableBytes])], [NSString stringWithFormat:@"Removes: %@. Apps and iOS recreate these files when needed.", list], @"Clean", NO, ^{
		TDRunWithSpinner(self, @"Cleaning…", ^id{
			unsigned long long freed = 0;
			for (TDCategory *category in chosen) freed += [category clean];
			[TDSettings recordClean:freed automatic:NO];
			return @(freed);
		}, ^(NSNumber *freed) {
			TDAlert(self, @"Done", [NSString stringWithFormat:@"%@ freed.", TDBytes(freed.doubleValue)]);
			[store refresh];
		});
	});
}

@end

#pragma mark - App detail

@interface TDAppDetailController : UITableViewController
- (instancetype)initWithApp:(TDApp *)app;
@end

@implementation TDAppDetailController {
	TDApp *_app;
	NSArray<NSArray *> *_folders; // @[size, relative path]
}

- (instancetype)initWithApp:(TDApp *)app {
	if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
		_app = app;
		self.title = app.name;
		self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	[self loadFolders];
}

- (void)loadFolders {
	TDApp *app = _app;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		NSMutableArray *folders = [NSMutableArray array];
		NSString *root = app.dataURL.path;
		NSFileManager *fm = [NSFileManager defaultManager];
		for (NSString *first in root ? [fm contentsOfDirectoryAtPath:root error:nil] : @[]) {
			NSString *firstPath = [root stringByAppendingPathComponent:first];
			for (NSString *second in [fm contentsOfDirectoryAtPath:firstPath error:nil]) {
				NSString *rel = [first stringByAppendingPathComponent:second];
				unsigned long long size = TDSizeOfPath([root stringByAppendingPathComponent:rel]);
				if (size > 512 * 1024) [folders addObject:@[@(size), rel]];
			}
		}
		[folders sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
		dispatch_async(dispatch_get_main_queue(), ^{
			self->_folders = [folders subarrayWithRange:NSMakeRange(0, MIN(8, folders.count))];
			[self.tableView reloadData];
		});
	});
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	if (section == 0) return 0;
	if (section == 1) return _app.isUserApp ? 4 : 3;
	return _folders.count;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
	if (section != 0) return nil;
	TDBarCard *card = [TDBarCard new];
	card.titleLabel.text = _app.isUserApp ? @"APP" : @"APPLE APP";
	card.headlineLabel.text = TDBytes(_app.appSize + _app.dataSize);
	card.captionLabel.text = _app.bundleID;
	unsigned long long data = _app.dataSize > _app.cacheSize ? _app.dataSize - _app.cacheSize : 0;
	[card setSegments:@[
		[TDSegment name:@"App" value:_app.appSize color:TDSeriesColor(0)],
		[TDSegment name:@"Documents & data" value:data color:TDSeriesColor(1)],
		[TDSegment name:@"Cache" value:_app.cacheSize color:TDSeriesColor(2)],
	] formatter:^NSString *(double v) { return TDBytes(v); }];
	return card;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	return section == 2 && _folders.count ? @"Biggest folders" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	if (section != 1) return nil;
	return _app.isUserApp
		? @"Clear All Data resets the app as if it was just installed: logins, settings, downloads and offline files in the app are removed. Data saved in iCloud or on the app's servers stays."
		: @"Apple apps can only have their cache cleared.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
	if (indexPath.section == 2) {
		cell.textLabel.text = _folders[indexPath.row][1];
		cell.textLabel.font = [UIFont systemFontOfSize:15];
		cell.detailTextLabel.text = TDBytes([_folders[indexPath.row][0] doubleValue]);
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
		return cell;
	}
	switch (indexPath.row) {
		case 0:
			cell.textLabel.text = @"Clear Cache";
			cell.detailTextLabel.text = TDBytes(_app.cacheSize);
			cell.textLabel.textColor = self.view.tintColor;
			break;
		case 1: {
			cell.textLabel.text = @"Protect cache from cleaning";
			UISwitch *toggle = [UISwitch new];
			toggle.on = [[TDSettings protectedApps] containsObject:_app.bundleID];
			[toggle addTarget:self action:@selector(protectChanged:) forControlEvents:UIControlEventValueChanged];
			cell.accessoryView = toggle;
			cell.selectionStyle = UITableViewCellSelectionStyleNone;
			break;
		}
		case 2:
			cell.textLabel.text = @"Open App";
			cell.textLabel.textColor = self.view.tintColor;
			break;
		default:
			cell.textLabel.text = @"Clear All Data…";
			cell.textLabel.textColor = [UIColor systemRedColor];
			break;
	}
	return cell;
}

- (void)protectChanged:(UISwitch *)toggle {
	NSMutableDictionary *settings = [TDSettings load];
	NSMutableSet *protectedApps = [[TDSettings protectedApps] mutableCopy];
	if (toggle.on) [protectedApps addObject:_app.bundleID]; else [protectedApps removeObject:_app.bundleID];
	settings[@"protectedApps"] = protectedApps.allObjects;
	[TDSettings save:settings];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (indexPath.section != 1) return;
	TDApp *app = _app;
	if (indexPath.row == 0) {
		TDConfirm(self, [NSString stringWithFormat:@"Clear cache of %@?", app.name], @"The app closes and downloads what it needs again.", @"Clear Cache", NO, ^{
			TDKillApp(app.bundleID);
			TDRunWithSpinner(self, @"Clearing…", ^id{
				[NSThread sleepForTimeInterval:0.5];
				unsigned long long freed = [app clearCache];
				[app computeSizes];
				return @(freed);
			}, ^(NSNumber *freed) {
				TDAlert(self, @"Done", [NSString stringWithFormat:@"%@ freed.", TDBytes(freed.doubleValue)]);
				[self.tableView reloadData];
				[self loadFolders];
			});
		});
	} else if (indexPath.row == 2) {
		id workspace = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"LSApplicationWorkspace"), NSSelectorFromString(@"defaultWorkspace"));
		((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, NSSelectorFromString(@"openApplicationWithBundleID:"), app.bundleID);
	} else if (indexPath.row == 3) {
		TDConfirm(self, [NSString stringWithFormat:@"Clear all data of %@?", app.name],
			@"The app is reset as if it was just installed. You'll need to sign in again, and downloads and offline files in the app are deleted. This can't be undone.", @"Clear All Data", YES, ^{
			TDKillApp(app.bundleID);
			TDRunWithSpinner(self, @"Clearing…", ^id{
				[NSThread sleepForTimeInterval:0.7];
				unsigned long long freed = [app clearAllData];
				[app computeSizes];
				return @(freed);
			}, ^(NSNumber *freed) {
				TDAlert(self, @"Done", [NSString stringWithFormat:@"%@ freed. %@ starts fresh next time you open it.", TDBytes(freed.doubleValue), app.name]);
				[self.tableView reloadData];
				[self loadFolders];
				[[TDStore shared] refresh];
			});
		});
	}
}

@end

#pragma mark - Apps

@interface TDAppCell : UITableViewCell
@property (nonatomic, strong) TDSegmentBar *bar;
@end

@implementation TDAppCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
	if ((self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier])) {
		_bar = [TDSegmentBar new];
		[self.contentView addSubview:_bar];
	}
	return self;
}
- (void)layoutSubviews {
	[super layoutSubviews];
	CGRect text = self.detailTextLabel.frame;
	self.bar.frame = CGRectMake(text.origin.x, CGRectGetMaxY(text) + 6, self.contentView.bounds.size.width - text.origin.x - 16, 6);
}
@end

@interface TDAppsController : UITableViewController <UISearchResultsUpdating>
@end

@implementation TDAppsController {
	NSString *_filter;
	BOOL _sortByName;
}

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStylePlain])) {
		self.title = @"Apps";
		self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Apps" image:[UIImage systemImageNamed:@"square.grid.2x2"] tag:2];
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.tableView.rowHeight = 72;
	UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
	search.searchResultsUpdater = self;
	search.obscuresBackgroundDuringPresentation = NO;
	self.navigationItem.searchController = search;
	UISegmentedControl *sort = [[UISegmentedControl alloc] initWithItems:@[@"Size", @"Name"]];
	sort.selectedSegmentIndex = 0;
	[sort addTarget:self action:@selector(sortChanged:) forControlEvents:UIControlEventValueChanged];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:sort];
	[[NSNotificationCenter defaultCenter] addObserver:self.tableView selector:@selector(reloadData) name:TDDataChangedNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self.tableView reloadData];
}

- (void)sortChanged:(UISegmentedControl *)control {
	_sortByName = control.selectedSegmentIndex == 1;
	[self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)controller {
	_filter = controller.searchBar.text;
	[self.tableView reloadData];
}

- (NSArray<TDApp *> *)apps {
	NSArray *apps = [TDStore shared].apps ?: @[];
	if (_filter.length) apps = [apps filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@", _filter]];
	if (_sortByName) apps = [apps sortedArrayUsingComparator:^NSComparisonResult(TDApp *a, TDApp *b) { return [a.name localizedCaseInsensitiveCompare:b.name]; }];
	return apps;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return [TDStore shared].apps ? self.apps.count : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	if (![TDStore shared].apps) {
		UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
		cell.textLabel.text = @"Measuring apps…";
		cell.textLabel.textColor = [UIColor secondaryLabelColor];
		return cell;
	}
	TDAppCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app"] ?: [[TDAppCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
	TDApp *app = self.apps[indexPath.row];
	cell.textLabel.text = app.name;
	cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
	unsigned long long data = app.dataSize > app.cacheSize ? app.dataSize - app.cacheSize : 0;
	cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  ·  app %@ · data %@ · cache %@", TDBytes(app.appSize + app.dataSize), TDBytes(app.appSize), TDBytes(data), TDBytes(app.cacheSize)];
	cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
	cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
	cell.imageView.image = TDAppIcon(app.bundleID, app.bundleURL, app.iconName, app.iconFiles, 40);
	cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	cell.bar.segments = @[
		[TDSegment name:@"App" value:app.appSize color:TDSeriesColor(0)],
		[TDSegment name:@"Data" value:data color:TDSeriesColor(1)],
		[TDSegment name:@"Cache" value:app.cacheSize color:TDSeriesColor(2)],
	];
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (![TDStore shared].apps) return;
	[self.navigationController pushViewController:[[TDAppDetailController alloc] initWithApp:self.apps[indexPath.row]] animated:YES];
}

@end

#pragma mark - Large files

@interface TDFilesController : UITableViewController
@end

@implementation TDFilesController {
	NSArray<NSDictionary *> *_files; // path, size, date, owner, deletable
	BOOL _scanning;
}

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
		self.title = @"Large Files";
		self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Files" image:[UIImage systemImageNamed:@"doc.text.magnifyingglass"] tag:3];
	}
	return self;
}

static BOOL TDFileDeletable(NSString *path) {
	NSString *ext = path.pathExtension.lowercaseString;
	if ([@[@"sqlite", @"db", @"realm", @"plist", @"sqlite-wal", @"sqlite-shm", @"store", @"dylib", @"bundle"] containsObject:ext]) return NO;
	if ([path containsString:@"/Documents/"] || [path containsString:@"/Library/Caches/"] || [path containsString:@"/tmp/"]) return [path hasPrefix:@"/var/mobile/"] || [path hasPrefix:@"/private/var/mobile/"];
	if ([path containsString:@"/Message/Media/"] || [path hasPrefix:@"/var/mobile/Media/Downloads/"]) return YES;
	return NO;
}

- (void)scan {
	if (_scanning) return;
	_scanning = YES;
	[self.tableView reloadData];
	NSArray *apps = [TDStore shared].apps;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableDictionary *owners = [NSMutableDictionary dictionary];
		for (TDApp *app in apps ?: [TDApp installedApps]) {
			if (app.dataURL) owners[app.dataURL.path] = app.name;
			for (NSURL *group in app.groupURLs) if (!owners[group.path]) owners[group.path] = app.name;
		}
		NSMutableArray *found = [NSMutableArray array];
		NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtURL:[NSURL fileURLWithPath:@"/var/mobile"]
			includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey, NSURLContentModificationDateKey, NSURLIsRegularFileKey]
			options:0 errorHandler:^BOOL(NSURL *url, NSError *error) { return YES; }];
		for (NSURL *url in enumerator) {
			NSDictionary *values = [url resourceValuesForKeys:@[NSURLTotalFileAllocatedSizeKey, NSURLContentModificationDateKey, NSURLIsRegularFileKey] error:nil];
			if (![values[NSURLIsRegularFileKey] boolValue]) continue;
			unsigned long long size = [values[NSURLTotalFileAllocatedSizeKey] unsignedLongLongValue];
			if (size < 20ull * 1024 * 1024) continue;
			NSString *path = url.path;
			NSString *owner = @"iOS";
			for (NSString *root in owners) if ([path hasPrefix:root]) { owner = owners[root]; break; }
			if ([path hasPrefix:@"/var/mobile/Media/DCIM"] || [path hasPrefix:@"/var/mobile/Media/PhotoData"]) owner = @"Photos";
			[found addObject:@{@"path": path, @"size": @(size), @"date": values[NSURLContentModificationDateKey] ?: [NSDate date], @"owner": owner, @"deletable": @(TDFileDeletable(path))}];
		}
		[found sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"size"] compare:a[@"size"]]; }];
		dispatch_async(dispatch_get_main_queue(), ^{
			self->_files = [found subarrayWithRange:NSMakeRange(0, MIN(60, found.count))];
			self->_scanning = NO;
			[self.tableView reloadData];
		});
	});
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return section == 0 ? 1 : _files.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	if (section == 0) return @"Finds the biggest files (over 20 MB) in your data. Files that apps or iOS depend on, like databases, can only be opened in Filza, not deleted here.";
	return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
	if (indexPath.section == 0) {
		cell.textLabel.text = _scanning ? @"Searching…" : (_files ? @"Search again" : @"Find large files");
		cell.textLabel.textColor = _scanning ? [UIColor secondaryLabelColor] : self.view.tintColor;
		cell.imageView.image = [UIImage systemImageNamed:@"magnifyingglass"];
		return cell;
	}
	NSDictionary *file = _files[indexPath.row];
	cell.textLabel.text = [file[@"path"] lastPathComponent];
	cell.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
	cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@", TDBytes([file[@"size"] doubleValue]), file[@"owner"],
		[NSDateFormatter localizedStringFromDate:file[@"date"] dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterNoStyle]];
	cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
	cell.imageView.image = [UIImage systemImageNamed:[file[@"deletable"] boolValue] ? @"doc" : @"lock.doc"];
	cell.imageView.tintColor = [UIColor secondaryLabelColor];
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (indexPath.section == 0) { [self scan]; return; }
	NSDictionary *file = _files[indexPath.row];
	NSString *path = file[@"path"];
	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:path.lastPathComponent message:path preferredStyle:UIAlertControllerStyleActionSheet];
	NSURL *filza = [NSURL URLWithString:[@"filza://view" stringByAppendingString:[path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]]];
	if ([[UIApplication sharedApplication] canOpenURL:filza]) {
		[sheet addAction:[UIAlertAction actionWithTitle:@"Show in Filza" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
			[[UIApplication sharedApplication] openURL:filza options:@{} completionHandler:nil];
		}]];
	}
	[sheet addAction:[UIAlertAction actionWithTitle:@"Copy Path" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [UIPasteboard generalPasteboard].string = path; }]];
	if ([file[@"deletable"] boolValue]) {
		[sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Delete (%@)", TDBytes([file[@"size"] doubleValue])] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
			TDConfirm(self, @"Delete this file?", [NSString stringWithFormat:@"%@ belongs to %@. It can't be recovered.", path.lastPathComponent, file[@"owner"]], @"Delete", YES, ^{
				unsigned long long freed = TDDeleteFile(path);
				if (freed) [TDSettings recordClean:freed automatic:NO];
				NSMutableArray *files = [self->_files mutableCopy];
				[files removeObject:file];
				self->_files = files;
				[self.tableView reloadData];
				TDAlert(self, freed ? @"Deleted" : @"Couldn't delete", freed ? [NSString stringWithFormat:@"%@ freed.", TDBytes(freed)] : @"iOS didn't allow deleting this file.");
			});
		}]];
	}
	[sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	sheet.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
	[self presentViewController:sheet animated:YES completion:nil];
}

@end

#pragma mark - Settings

@interface TDSettingsController : UITableViewController
@end

@implementation TDSettingsController

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
		self.title = @"Settings";
		self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Settings" image:[UIImage systemImageNamed:@"gearshape"] tag:4];
	}
	return self;
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	switch (section) {
		case 0: return [TDSettings autoClean] == TDAutoCleanLowSpace ? 2 : 1;
		case 1: return 1;
		case 2: return 1;
		default: return 3;
	}
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	return @[@"Auto-clean", @"Protected apps", @"WhatsApp", @"About"][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	switch (section) {
		case 0: return @"Cleans the items switched on in the Clean tab, in the background: once a week, or whenever free space drops below the limit. It never touches your files or app data.";
		case 1: return @"Caches of protected apps are never cleaned automatically. Apps that may keep offline downloads in their cache (Spotify, Netflix, YouTube…) are protected by default.";
		case 2: return @"Off by default. When on, the Clean tab gets a WhatsApp section to delete old chat media.";
		default: return nil;
	}
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	NSDictionary *settings = [TDSettings load];
	if (indexPath.section == 0 && indexPath.row == 0) {
		UISegmentedControl *mode = [[UISegmentedControl alloc] initWithItems:@[@"Off", @"Weekly", @"Low space"]];
		mode.selectedSegmentIndex = [TDSettings autoClean];
		[mode addTarget:self action:@selector(autoCleanChanged:) forControlEvents:UIControlEventValueChanged];
		mode.translatesAutoresizingMaskIntoConstraints = NO;
		[cell.contentView addSubview:mode];
		[NSLayoutConstraint activateConstraints:@[
			[mode.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
			[mode.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
			[mode.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
			[mode.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
		]];
	} else if (indexPath.section == 0) {
		cell.textLabel.text = [NSString stringWithFormat:@"When free space is below %.0f GB", [TDSettings lowSpaceGB]];
		UIStepper *stepper = [UIStepper new];
		stepper.minimumValue = 1;
		stepper.maximumValue = 30;
		stepper.value = [TDSettings lowSpaceGB];
		[stepper addTarget:self action:@selector(lowSpaceChanged:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = stepper;
	} else if (indexPath.section == 1) {
		cell.textLabel.text = @"Protected apps";
		cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)[TDSettings protectedApps].count];
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		cell.selectionStyle = UITableViewCellSelectionStyleDefault;
	} else if (indexPath.section == 2) {
		cell.textLabel.text = @"WhatsApp media cleaner";
		UISwitch *toggle = [UISwitch new];
		toggle.on = [TDSettings whatsAppEnabled];
		[toggle addTarget:self action:@selector(whatsAppChanged:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = toggle;
	} else {
		if (indexPath.row == 0) {
			cell.textLabel.text = @"Cleaned so far";
			cell.detailTextLabel.text = TDBytes([settings[@"totalCleaned"] doubleValue]);
		} else if (indexPath.row == 1) {
			cell.textLabel.text = @"Version";
			cell.detailTextLabel.text = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
		} else {
			cell.textLabel.text = @"Source code";
			cell.detailTextLabel.text = @"github.com/zephyranthess/repo";
			cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		}
	}
	return cell;
}

- (void)autoCleanChanged:(UISegmentedControl *)control {
	NSMutableDictionary *settings = [TDSettings load];
	settings[@"autoClean"] = @(control.selectedSegmentIndex);
	[TDSettings save:settings];
	[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)lowSpaceChanged:(UIStepper *)stepper {
	NSMutableDictionary *settings = [TDSettings load];
	settings[@"lowSpaceGB"] = @(stepper.value);
	[TDSettings save:settings];
	[self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)whatsAppChanged:(UISwitch *)toggle {
	NSMutableDictionary *settings = [TDSettings load];
	settings[@"whatsApp"] = @(toggle.on);
	[TDSettings save:settings];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (indexPath.section == 1) {
		[self.navigationController pushViewController:[NSClassFromString(@"TDProtectedController") new] animated:YES];
	} else if (indexPath.section == 3 && indexPath.row == 2) {
		[[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/zephyranthess/repo"] options:@{} completionHandler:nil];
	}
}

@end

@interface TDProtectedController : UITableViewController
@end

@implementation TDProtectedController {
	NSArray<TDApp *> *_apps;
}

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
		self.title = @"Protected Apps";
		NSArray *apps = [TDStore shared].apps ?: [TDApp installedApps];
		_apps = [[apps filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isUserApp == YES"]] sortedArrayUsingComparator:^NSComparisonResult(TDApp *a, TDApp *b) {
			return [a.name localizedCaseInsensitiveCompare:b.name];
		}];
	}
	return self;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _apps.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	TDApp *app = _apps[indexPath.row];
	cell.textLabel.text = app.name;
	cell.imageView.image = TDAppIcon(app.bundleID, app.bundleURL, app.iconName, app.iconFiles, 29);
	UISwitch *toggle = [UISwitch new];
	toggle.on = [[TDSettings protectedApps] containsObject:app.bundleID];
	toggle.tag = indexPath.row;
	[toggle addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
	cell.accessoryView = toggle;
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	return cell;
}

- (void)toggled:(UISwitch *)toggle {
	NSString *bundleID = _apps[toggle.tag].bundleID;
	NSMutableDictionary *settings = [TDSettings load];
	NSMutableSet *protectedApps = [[TDSettings protectedApps] mutableCopy];
	if (toggle.on) [protectedApps addObject:bundleID]; else [protectedApps removeObject:bundleID];
	settings[@"protectedApps"] = protectedApps.allObjects;
	[TDSettings save:settings];
}

@end

#pragma mark - Root

UIViewController *TDMakeRootController(void) {
	UITabBarController *tabs = [UITabBarController new];
	NSMutableArray *controllers = [NSMutableArray array];
	for (UIViewController *controller in @[[TDOverviewController new], [TDCleanController new], [TDAppsController new], [TDFilesController new], [TDSettingsController new]]) {
		UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
		nav.navigationBar.prefersLargeTitles = YES;
		nav.tabBarItem = controller.tabBarItem;
		[controllers addObject:nav];
	}
	tabs.viewControllers = controllers;
	[[TDStore shared] refresh];
	return tabs;
}
