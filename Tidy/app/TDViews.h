#import <UIKit/UIKit.h>

// Chart colors (validated reference palette, light/dark steps). Categorical slots are
// assigned in fixed order; "free" is a neutral gray, never a category color.
UIColor *TDSeriesColor(NSUInteger slot);   // 0..4
UIColor *TDFreeColor(void);
UIColor *TDStatusGood(void);
UIColor *TDStatusWarning(void);
UIColor *TDStatusCritical(void);

@interface TDSegment : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) double value;
@property (nonatomic, strong) UIColor *color;
+ (instancetype)name:(NSString *)name value:(double)value color:(UIColor *)color;
@end

// One horizontal bar split into segments, with 2pt surface gaps and rounded ends.
@interface TDSegmentBar : UIView
@property (nonatomic, copy) NSArray<TDSegment *> *segments;
@end

// A card: title, big headline number, caption, segmented bar and a legend with values.
@interface TDBarCard : UIView
@property (nonatomic, strong, readonly) UILabel *titleLabel, *headlineLabel, *captionLabel;
@property (nonatomic, strong, readonly) TDSegmentBar *bar;
- (void)setSegments:(NSArray<TDSegment *> *)segments formatter:(NSString * (^)(double value))formatter;
@end

// Small status pill: icon + label (status is never shown by color alone).
@interface TDStatusPill : UIView
- (void)setText:(NSString *)text symbol:(NSString *)symbol color:(UIColor *)color;
@end

UIImage *TDAppIcon(NSString *bundleID, NSURL *bundleURL, NSString *iconName, NSArray *iconFiles, CGFloat size);
