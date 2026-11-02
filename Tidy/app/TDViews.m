#import "TDViews.h"

static UIColor *TDHex(uint32_t hex) {
	return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0 green:((hex >> 8) & 0xFF) / 255.0 blue:(hex & 0xFF) / 255.0 alpha:1];
}

static UIColor *TDDynamic(uint32_t light, uint32_t dark) {
	return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
		return TDHex(traits.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light);
	}];
}

UIColor *TDSeriesColor(NSUInteger slot) {
	static const uint32_t light[] = {0x2a78d6, 0xeb6834, 0x1baf7a, 0xeda100, 0xe87ba4};
	static const uint32_t dark[]  = {0x3987e5, 0xd95926, 0x199e70, 0xc98500, 0xd55181};
	slot = MIN(slot, 4);
	return TDDynamic(light[slot], dark[slot]);
}

UIColor *TDFreeColor(void) { return TDDynamic(0xe3e2de, 0x3a3a38); }
UIColor *TDStatusGood(void) { return TDHex(0x0ca30c); }
UIColor *TDStatusWarning(void) { return TDHex(0xfab219); }
UIColor *TDStatusCritical(void) { return TDHex(0xd03b3b); }

@implementation TDSegment
+ (instancetype)name:(NSString *)name value:(double)value color:(UIColor *)color {
	TDSegment *segment = [TDSegment new];
	segment.name = name;
	segment.value = value;
	segment.color = color;
	return segment;
}
@end

#pragma mark - Segment bar

@implementation TDSegmentBar

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = [UIColor clearColor];
		self.isAccessibilityElement = YES;
	}
	return self;
}

- (CGSize)intrinsicContentSize { return CGSizeMake(UIViewNoIntrinsicMetric, 16); }

- (void)setSegments:(NSArray<TDSegment *> *)segments {
	_segments = [segments copy];
	NSMutableArray *parts = [NSMutableArray array];
	for (TDSegment *segment in segments) [parts addObject:segment.name];
	self.accessibilityLabel = [parts componentsJoinedByString:@", "];
	[self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
	double total = 0;
	for (TDSegment *segment in self.segments) total += MAX(0, segment.value);
	if (total <= 0) return;
	CGFloat gap = 2, width = self.bounds.size.width, height = self.bounds.size.height;
	NSMutableArray<TDSegment *> *visible = [NSMutableArray array];
	for (TDSegment *segment in self.segments) if (segment.value / total * width >= 1) [visible addObject:segment];
	CGFloat usable = width - gap * (visible.count - 1);
	CGFloat x = 0;
	UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:4];
	[clip addClip];
	for (TDSegment *segment in visible) {
		CGFloat w = MAX(2, round(segment.value / total * usable));
		if (segment == visible.lastObject) w = width - x;
		[segment.color setFill];
		[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x, 0, w, height) cornerRadius:segment == visible.firstObject || segment == visible.lastObject ? 4 : 1] fill];
		x += w + gap;
	}
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
	[super traitCollectionDidChange:previous];
	[self setNeedsDisplay];
}

@end

#pragma mark - Card

@implementation TDBarCard {
	UIStackView *_legend;
}

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
		self.layer.cornerRadius = 14;

		_titleLabel = [UILabel new];
		_titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
		_titleLabel.textColor = [UIColor secondaryLabelColor];
		_headlineLabel = [UILabel new];
		_headlineLabel.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
		_headlineLabel.adjustsFontSizeToFitWidth = YES;
		_captionLabel = [UILabel new];
		_captionLabel.font = [UIFont systemFontOfSize:15];
		_captionLabel.textColor = [UIColor secondaryLabelColor];
		_captionLabel.numberOfLines = 0;
		_bar = [TDSegmentBar new];
		_legend = [UIStackView new];
		_legend.axis = UILayoutConstraintAxisVertical;
		_legend.spacing = 6;

		UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _headlineLabel, _captionLabel, _bar, _legend]];
		stack.axis = UILayoutConstraintAxisVertical;
		stack.spacing = 6;
		[stack setCustomSpacing:14 afterView:_captionLabel];
		[stack setCustomSpacing:14 afterView:_bar];
		stack.translatesAutoresizingMaskIntoConstraints = NO;
		[self addSubview:stack];
		[NSLayoutConstraint activateConstraints:@[
			[stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:16],
			[stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-16],
			[stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
			[stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
			[_bar.heightAnchor constraintEqualToConstant:16],
		]];
	}
	return self;
}

- (void)setSegments:(NSArray<TDSegment *> *)segments formatter:(NSString * (^)(double))formatter {
	self.bar.segments = segments;
	for (UIView *view in _legend.arrangedSubviews) [view removeFromSuperview];
	for (TDSegment *segment in segments) {
		UIView *swatch = [UIView new];
		swatch.backgroundColor = segment.color;
		swatch.layer.cornerRadius = 3;
		[swatch.widthAnchor constraintEqualToConstant:12].active = YES;
		[swatch.heightAnchor constraintEqualToConstant:12].active = YES;
		UILabel *name = [UILabel new];
		name.text = segment.name;
		name.font = [UIFont systemFontOfSize:15];
		name.textColor = [UIColor labelColor];
		UILabel *value = [UILabel new];
		value.text = formatter(segment.value);
		value.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
		value.textColor = [UIColor secondaryLabelColor];
		value.textAlignment = NSTextAlignmentRight;
		[value setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
		UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[swatch, name, value]];
		row.spacing = 8;
		row.alignment = UIStackViewAlignmentCenter;
		[_legend addArrangedSubview:row];
	}
}

@end

#pragma mark - Status pill

@implementation TDStatusPill {
	UIImageView *_icon;
	UILabel *_label;
}

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		_icon = [UIImageView new];
		_icon.contentMode = UIViewContentModeScaleAspectFit;
		[_icon.widthAnchor constraintEqualToConstant:16].active = YES;
		_label = [UILabel new];
		_label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
		_label.textColor = [UIColor labelColor]; // text keeps text color; the icon carries the status color
		UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_icon, _label]];
		stack.spacing = 6;
		stack.translatesAutoresizingMaskIntoConstraints = NO;
		[self addSubview:stack];
		[NSLayoutConstraint activateConstraints:@[
			[stack.topAnchor constraintEqualToAnchor:self.topAnchor],
			[stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
			[stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
			[stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor],
		]];
	}
	return self;
}

- (void)setText:(NSString *)text symbol:(NSString *)symbol color:(UIColor *)color {
	_icon.image = [UIImage systemImageNamed:symbol];
	_icon.tintColor = color;
	_label.text = text;
}

@end

#pragma mark - App icons

UIImage *TDAppIcon(NSString *bundleID, NSURL *bundleURL, NSString *iconName, NSArray *iconFiles, CGFloat size) {
	static NSCache *cache;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ cache = [NSCache new]; });
	NSString *key = [NSString stringWithFormat:@"%@-%.0f", bundleID, size];
	UIImage *cached = [cache objectForKey:key];
	if (cached) return cached;

	NSBundle *bundle = bundleURL ? [NSBundle bundleWithURL:bundleURL] : nil;
	UIImage *image = (bundle && iconName) ? [UIImage imageNamed:iconName inBundle:bundle compatibleWithTraitCollection:nil] : nil;
	for (NSString *file in [iconFiles reverseObjectEnumerator]) {
		if (image) break;
		image = [UIImage imageNamed:file inBundle:bundle compatibleWithTraitCollection:nil];
		if (!image) {
			NSString *path = [bundle pathForResource:[file stringByAppendingString:@"@2x"] ofType:@"png"] ?: [bundle pathForResource:file ofType:@"png"];
			if (path) image = [UIImage imageWithContentsOfFile:path];
		}
	}
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
	UIImage *result = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
		UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size, size) cornerRadius:size * 0.225];
		[clip addClip];
		if (image) {
			[image drawInRect:CGRectMake(0, 0, size, size)];
		} else {
			[[UIColor systemGray4Color] setFill];
			[clip fill];
		}
	}];
	[cache setObject:result forKey:key];
	return result;
}
