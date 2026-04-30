// Tweak.xm - XHS778 小红书表情包保存插件
// Author: lllxxx123456
// 适用版本：XHS 9.28.1

#import "XHS778Headers.h"

#pragma mark - 设置存储 Key

static NSString * const kXHS778EnabledKey            = @"XHS778_Enabled";
static NSString * const kXHS778CommentSaveEnabledKey = @"XHS778_CommentSaveEnabled";

static BOOL XHS778Enabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kXHS778EnabledKey];
}

static BOOL XHS778CommentSaveEnabled(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud objectForKey:kXHS778CommentSaveEnabledKey] == nil) {
        return YES; // 默认开启
    }
    return [ud boolForKey:kXHS778CommentSaveEnabledKey];
}

static void XHS778SetEnabled(BOOL e) {
    [[NSUserDefaults standardUserDefaults] setBool:e forKey:kXHS778EnabledKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static void XHS778SetCommentSaveEnabled(BOOL e) {
    [[NSUserDefaults standardUserDefaults] setBool:e forKey:kXHS778CommentSaveEnabledKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - 全局状态：当前长按的评论 view 与表情图片

static __weak UIView *gXHS778LastLongPressedCommentView = nil;
static __weak XYAnimatedImageView *gXHS778LastLongPressedEmojiView = nil;

// 关联对象 keys（设置 VC 内部使用）
static char kXHS778HeaderCardKey;
static char kXHS778WarningCardKey;
static char kXHS778SwitchCardKey;

#pragma mark - 通用工具

static UIViewController *XHS778TopViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { keyWindow = w; break; }
    }
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        vc = [(UINavigationController *)vc topViewController];
    }
    return vc;
}

static void XHS778ShowToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = XHS778TopViewController();
        if (!top) return;
        UIAlertController *toast = [UIAlertController alertControllerWithTitle:nil
                                                                      message:message
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [top presentViewController:toast animated:YES completion:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [toast dismissViewControllerAnimated:YES completion:nil];
        });
    });
}

#pragma mark - 在 view 树中查找 XYAnimatedImageView

static XYAnimatedImageView *XHS778FindAnimatedImageView(UIView *root) {
    if (!root) return nil;
    Class targetCls = NSClassFromString(@"XYAnimatedImageView");
    if (targetCls && [root isKindOfClass:targetCls]) {
        return (XYAnimatedImageView *)root;
    }
    for (UIView *sub in root.subviews) {
        XYAnimatedImageView *found = XHS778FindAnimatedImageView(sub);
        if (found) return found;
    }
    return nil;
}

#pragma mark - 表情保存核心逻辑

static NSData *XHS778ExtractAnimatedData(UIImage *image) {
    if (!image) return nil;
    if ([image respondsToSelector:@selector(animatedImageData)]) {
        NSData *data = [(id)image animatedImageData];
        if (data.length > 0) return data;
    }
    return nil;
}

static BOOL XHS778IsGIFData(NSData *data) {
    if (data.length < 6) return NO;
    const char *bytes = (const char *)data.bytes;
    return (bytes[0] == 'G' && bytes[1] == 'I' && bytes[2] == 'F');
}

static BOOL XHS778IsPNGData(NSData *data) {
    if (data.length < 8) return NO;
    const unsigned char *b = (const unsigned char *)data.bytes;
    return (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47);
}

static void XHS778RequestPhotoAuthorizationThen(void(^block)(BOOL granted)) {
    if (@available(iOS 14, *)) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
            BOOL granted = (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited);
            dispatch_async(dispatch_get_main_queue(), ^{ if (block) block(granted); });
        }];
    } else {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            BOOL granted = (status == PHAuthorizationStatusAuthorized);
            dispatch_async(dispatch_get_main_queue(), ^{ if (block) block(granted); });
        }];
    }
}

static void XHS778SaveDataToAlbum(NSData *data, BOOL isGIF) {
    if (data.length == 0) {
        XHS778ShowToast(@"没有获取到图片数据");
        return;
    }
    XHS778RequestPhotoAuthorizationThen(^(BOOL granted) {
        if (!granted) {
            XHS778ShowToast(@"未授权访问相册");
            return;
        }
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            PHAssetCreationRequest *req = [PHAssetCreationRequest creationRequestForAsset];
            PHAssetResourceCreationOptions *opts = [[PHAssetResourceCreationOptions alloc] init];
            if (isGIF) {
                opts.uniformTypeIdentifier = @"com.compuserve.gif";
            } else if (XHS778IsPNGData(data)) {
                opts.uniformTypeIdentifier = @"public.png";
            } else {
                opts.uniformTypeIdentifier = @"public.jpeg";
            }
            [req addResourceWithType:PHAssetResourceTypePhoto data:data options:opts];
        } completionHandler:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    XHS778ShowToast(isGIF ? @"GIF 已保存到相册" : @"图片已保存到相册");
                } else {
                    XHS778ShowToast([NSString stringWithFormat:@"保存失败：%@", error.localizedDescription ?: @"未知错误"]);
                }
            });
        }];
    });
}

static void XHS778SaveStaticImageToAlbum(UIImage *image) {
    if (!image) {
        XHS778ShowToast(@"没有获取到图片");
        return;
    }
    NSData *pngData = UIImagePNGRepresentation(image);
    if (pngData.length > 0) {
        XHS778SaveDataToAlbum(pngData, NO);
        return;
    }
    NSData *jpgData = UIImageJPEGRepresentation(image, 1.0);
    XHS778SaveDataToAlbum(jpgData, NO);
}

// 入口：保存指定 XYAnimatedImageView 中的表情
static void XHS778SaveEmojiFromImageView(XYAnimatedImageView *imageView) {
    if (!imageView) {
        XHS778ShowToast(@"未找到表情图片");
        return;
    }
    UIImage *image = imageView.image;
    if (!image) {
        XHS778ShowToast(@"未找到表情图片");
        return;
    }
    NSData *animatedData = XHS778ExtractAnimatedData(image);
    if (animatedData.length > 0) {
        BOOL isGIF = XHS778IsGIFData(animatedData);
        XHS778SaveDataToAlbum(animatedData, isGIF);
    } else {
        XHS778SaveStaticImageToAlbum(image);
    }
}

// 入口：从评论 view 中查找并保存表情
static void XHS778SaveEmojiFromCommentView(UIView *commentView) {
    if (!commentView) {
        XHS778ShowToast(@"未找到评论视图");
        return;
    }
    XYAnimatedImageView *iv = XHS778FindAnimatedImageView(commentView);
    XHS778SaveEmojiFromImageView(iv);
}

#pragma mark - XHS778 自定义设置 ViewController

static UIColor *XHS778ColorBackground(void) {
    return [UIColor colorWithRed:0.96 green:0.96 blue:0.97 alpha:1.0];
}
static UIColor *XHS778ColorCard(void) {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull tc) {
            return tc.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithRed:0.13 green:0.13 blue:0.15 alpha:1.0]
                : [UIColor whiteColor];
        }];
    }
    return [UIColor whiteColor];
}
static UIColor *XHS778ColorBackgroundDynamic(void) {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull tc) {
            return tc.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithRed:0.07 green:0.07 blue:0.08 alpha:1.0]
                : [UIColor colorWithRed:0.96 green:0.96 blue:0.97 alpha:1.0];
        }];
    }
    return XHS778ColorBackground();
}
static UIColor *XHS778ColorPrimary(void) {
    return [UIColor colorWithRed:1.00 green:0.14 blue:0.26 alpha:1.0]; // 小红书红 #FF2442
}
static UIColor *XHS778ColorTitleText(void) {
    if (@available(iOS 13.0, *)) return [UIColor labelColor];
    return [UIColor blackColor];
}
static UIColor *XHS778ColorSecondaryText(void) {
    if (@available(iOS 13.0, *)) return [UIColor secondaryLabelColor];
    return [UIColor grayColor];
}
static UIColor *XHS778ColorSeparator(void) {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull tc) {
            return tc.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.08]
                : [UIColor colorWithWhite:0.0 alpha:0.06];
        }];
    }
    return [UIColor colorWithWhite:0.0 alpha:0.06];
}

@interface XHS778SwitchRowView : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UISwitch *switchControl;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, copy) void (^onChange)(BOOL on);
@end

@implementation XHS778SwitchRowView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.iconView = [[UIImageView alloc] init];
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconView.tintColor = XHS778ColorPrimary();
        self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.iconView];

        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        self.titleLabel.textColor = XHS778ColorTitleText();
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.titleLabel];

        self.subtitleLabel = [[UILabel alloc] init];
        self.subtitleLabel.font = [UIFont systemFontOfSize:12];
        self.subtitleLabel.textColor = XHS778ColorSecondaryText();
        self.subtitleLabel.numberOfLines = 0;
        self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.subtitleLabel];

        self.switchControl = [[UISwitch alloc] init];
        self.switchControl.onTintColor = XHS778ColorPrimary();
        self.switchControl.translatesAutoresizingMaskIntoConstraints = NO;
        [self.switchControl addTarget:self action:@selector(_onSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:self.switchControl];

        [NSLayoutConstraint activateConstraints:@[
            [self.iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
            [self.iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.iconView.widthAnchor constraintEqualToConstant:24],
            [self.iconView.heightAnchor constraintEqualToConstant:24],

            [self.switchControl.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
            [self.switchControl.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:12],
            [self.titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:14],
            [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.switchControl.leadingAnchor constant:-12],

            [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:4],
            [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],
            [self.subtitleLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-14],
        ]];
    }
    return self;
}

- (void)_onSwitchChanged:(UISwitch *)sender {
    if (self.onChange) self.onChange(sender.isOn);
}

@end


@interface XHS778SettingsVC : UIViewController
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) XHS778SwitchRowView *masterSwitchRow;
@property (nonatomic, strong) XHS778SwitchRowView *commentSaveSwitchRow;
@end

@implementation XHS778SettingsVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"XHS778";
    self.view.backgroundColor = XHS778ColorBackgroundDynamic();
    if (self.navigationController) {
        self.navigationController.navigationBar.tintColor = XHS778ColorPrimary();
    }

    [self _buildScrollView];
    [self _buildHeaderCard];
    [self _buildWarningCard];
    [self _buildSwitchCard];
    [self _buildAboutCard];
}

- (void)_buildScrollView {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.scrollView];

    self.contentView = [[UIView alloc] init];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.contentView];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.contentView.topAnchor constraintEqualToAnchor:self.scrollView.topAnchor],
        [self.contentView.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor],
        [self.contentView.trailingAnchor constraintEqualToAnchor:self.scrollView.trailingAnchor],
        [self.contentView.bottomAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor],
        [self.contentView.widthAnchor constraintEqualToAnchor:self.scrollView.widthAnchor],
    ]];
}

- (UIView *)_makeCard {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = XHS778ColorCard();
    card.layer.cornerRadius = 14;
    card.layer.masksToBounds = NO;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.04;
    card.layer.shadowRadius = 6;
    card.layer.shadowOffset = CGSizeMake(0, 2);
    card.translatesAutoresizingMaskIntoConstraints = NO;
    return card;
}

- (UIView *)_horizontalDivider {
    UIView *line = [[UIView alloc] init];
    line.backgroundColor = XHS778ColorSeparator();
    line.translatesAutoresizingMaskIntoConstraints = NO;
    return line;
}

- (void)_buildHeaderCard {
    UIView *card = [self _makeCard];
    [self.contentView addSubview:card];

    UIView *iconBg = [[UIView alloc] init];
    iconBg.backgroundColor = XHS778ColorPrimary();
    iconBg.layer.cornerRadius = 18;
    iconBg.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:iconBg];

    UILabel *iconLabel = [[UILabel alloc] init];
    iconLabel.text = @"778";
    iconLabel.textColor = [UIColor whiteColor];
    iconLabel.textAlignment = NSTextAlignmentCenter;
    iconLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightHeavy];
    iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [iconBg addSubview:iconLabel];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"XHS778";
    titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    titleLabel.textColor = XHS778ColorTitleText();
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = @"小红书表情包保存助手";
    subtitleLabel.font = [UIFont systemFontOfSize:13];
    subtitleLabel.textColor = XHS778ColorSecondaryText();
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:subtitleLabel];

    UILabel *versionLabel = [[UILabel alloc] init];
    versionLabel.text = @"适配版本 9.28.1";
    versionLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    versionLabel.textColor = XHS778ColorPrimary();
    versionLabel.textAlignment = NSTextAlignmentCenter;
    versionLabel.layer.cornerRadius = 4;
    versionLabel.layer.borderWidth = 0.8;
    versionLabel.layer.borderColor = XHS778ColorPrimary().CGColor;
    versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:versionLabel];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:20],
        [card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [card.heightAnchor constraintEqualToConstant:96],

        [iconBg.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [iconBg.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [iconBg.widthAnchor constraintEqualToConstant:60],
        [iconBg.heightAnchor constraintEqualToConstant:60],

        [iconLabel.centerXAnchor constraintEqualToAnchor:iconBg.centerXAnchor],
        [iconLabel.centerYAnchor constraintEqualToAnchor:iconBg.centerYAnchor],

        [titleLabel.leadingAnchor constraintEqualToAnchor:iconBg.trailingAnchor constant:14],
        [titleLabel.topAnchor constraintEqualToAnchor:iconBg.topAnchor constant:6],

        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],

        [versionLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [versionLabel.topAnchor constraintEqualToAnchor:subtitleLabel.bottomAnchor constant:6],
        [versionLabel.heightAnchor constraintEqualToConstant:18],
        [versionLabel.widthAnchor constraintEqualToConstant:104],
    ]];

    objc_setAssociatedObject(self, &kXHS778HeaderCardKey, card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)_buildWarningCard {
    UIView *headerCard = objc_getAssociatedObject(self, &kXHS778HeaderCardKey);

    UIView *card = [self _makeCard];
    card.backgroundColor = [XHS778ColorPrimary() colorWithAlphaComponent:0.10];
    card.layer.shadowOpacity = 0;
    [self.contentView addSubview:card];

    UILabel *iconLabel = [[UILabel alloc] init];
    iconLabel.text = @"⚠";
    iconLabel.textColor = XHS778ColorPrimary();
    iconLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:iconLabel];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"风险提示";
    titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    titleLabel.textColor = XHS778ColorPrimary();
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:titleLabel];

    UILabel *contentLabel = [[UILabel alloc] init];
    contentLabel.text = @"本插件仅用于学习交流，请尊重原作者的版权。\n保存的表情仅供个人使用，请勿用于商业用途或二次传播。\n使用插件可能违反小红书用户协议，由此引发的账号风险请自行承担。";
    contentLabel.font = [UIFont systemFontOfSize:12];
    contentLabel.textColor = XHS778ColorTitleText();
    contentLabel.numberOfLines = 0;
    contentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:contentLabel];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:headerCard.bottomAnchor constant:16],
        [card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],

        [iconLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [iconLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],

        [titleLabel.leadingAnchor constraintEqualToAnchor:iconLabel.trailingAnchor constant:8],
        [titleLabel.centerYAnchor constraintEqualToAnchor:iconLabel.centerYAnchor],

        [contentLabel.leadingAnchor constraintEqualToAnchor:iconLabel.leadingAnchor],
        [contentLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [contentLabel.topAnchor constraintEqualToAnchor:iconLabel.bottomAnchor constant:8],
        [contentLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];

    objc_setAssociatedObject(self, &kXHS778WarningCardKey, card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)_buildSwitchCard {
    UIView *warningCard = objc_getAssociatedObject(self, &kXHS778WarningCardKey);

    // 卡片标题
    UILabel *sectionTitle = [[UILabel alloc] init];
    sectionTitle.text = @"功能开关";
    sectionTitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    sectionTitle.textColor = XHS778ColorSecondaryText();
    sectionTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:sectionTitle];

    UIView *card = [self _makeCard];
    [self.contentView addSubview:card];

    self.masterSwitchRow = [[XHS778SwitchRowView alloc] init];
    self.masterSwitchRow.translatesAutoresizingMaskIntoConstraints = NO;
    self.masterSwitchRow.titleLabel.text = @"启用 XHS778";
    self.masterSwitchRow.subtitleLabel.text = @"插件总开关，关闭后所有功能停用";
    if (@available(iOS 13.0, *)) {
        self.masterSwitchRow.iconView.image = [UIImage systemImageNamed:@"power"];
    }
    self.masterSwitchRow.switchControl.on = XHS778Enabled();
    __weak typeof(self) weakSelf = self;
    self.masterSwitchRow.onChange = ^(BOOL on) {
        XHS778SetEnabled(on);
        [weakSelf _refreshSubSwitchEnabled];
    };
    [card addSubview:self.masterSwitchRow];

    UIView *line = [self _horizontalDivider];
    [card addSubview:line];

    self.commentSaveSwitchRow = [[XHS778SwitchRowView alloc] init];
    self.commentSaveSwitchRow.translatesAutoresizingMaskIntoConstraints = NO;
    self.commentSaveSwitchRow.titleLabel.text = @"长按评论保存表情";
    self.commentSaveSwitchRow.subtitleLabel.text = @"在长按评论的菜单中显示「保存表情」选项";
    if (@available(iOS 13.0, *)) {
        self.commentSaveSwitchRow.iconView.image = [UIImage systemImageNamed:@"hand.tap"];
    }
    self.commentSaveSwitchRow.switchControl.on = XHS778CommentSaveEnabled();
    self.commentSaveSwitchRow.onChange = ^(BOOL on) {
        XHS778SetCommentSaveEnabled(on);
    };
    [card addSubview:self.commentSaveSwitchRow];

    [NSLayoutConstraint activateConstraints:@[
        [sectionTitle.topAnchor constraintEqualToAnchor:warningCard.bottomAnchor constant:24],
        [sectionTitle.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:24],

        [card.topAnchor constraintEqualToAnchor:sectionTitle.bottomAnchor constant:8],
        [card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],

        [self.masterSwitchRow.topAnchor constraintEqualToAnchor:card.topAnchor],
        [self.masterSwitchRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [self.masterSwitchRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],

        [line.topAnchor constraintEqualToAnchor:self.masterSwitchRow.bottomAnchor],
        [line.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:52],
        [line.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [line.heightAnchor constraintEqualToConstant:0.5],

        [self.commentSaveSwitchRow.topAnchor constraintEqualToAnchor:line.bottomAnchor],
        [self.commentSaveSwitchRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [self.commentSaveSwitchRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [self.commentSaveSwitchRow.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    objc_setAssociatedObject(self, &kXHS778SwitchCardKey, card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self _refreshSubSwitchEnabled];
}

- (void)_refreshSubSwitchEnabled {
    BOOL master = XHS778Enabled();
    self.commentSaveSwitchRow.switchControl.enabled = master;
    self.commentSaveSwitchRow.alpha = master ? 1.0 : 0.5;
}

- (void)_buildAboutCard {
    UIView *switchCard = objc_getAssociatedObject(self, &kXHS778SwitchCardKey);

    UILabel *sectionTitle = [[UILabel alloc] init];
    sectionTitle.text = @"关于";
    sectionTitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    sectionTitle.textColor = XHS778ColorSecondaryText();
    sectionTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:sectionTitle];

    UIView *card = [self _makeCard];
    [self.contentView addSubview:card];

    UILabel *desc = [[UILabel alloc] init];
    desc.text = @"长按评论区中的表情，菜单内即可一键保存为静态图或 GIF。\n保存的资源会写入系统相册的「最近项目」。";
    desc.font = [UIFont systemFontOfSize:13];
    desc.textColor = XHS778ColorTitleText();
    desc.numberOfLines = 0;
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:desc];

    UIView *line = [self _horizontalDivider];
    [card addSubview:line];

    UILabel *footer = [[UILabel alloc] init];
    footer.text = @"GitHub · lllxxx123456/XHS778";
    footer.font = [UIFont systemFontOfSize:12];
    footer.textColor = XHS778ColorSecondaryText();
    footer.textAlignment = NSTextAlignmentCenter;
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:footer];

    [NSLayoutConstraint activateConstraints:@[
        [sectionTitle.topAnchor constraintEqualToAnchor:switchCard.bottomAnchor constant:24],
        [sectionTitle.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:24],

        [card.topAnchor constraintEqualToAnchor:sectionTitle.bottomAnchor constant:8],
        [card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],

        [desc.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [desc.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [desc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [line.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:12],
        [line.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [line.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [line.heightAnchor constraintEqualToConstant:0.5],

        [footer.topAnchor constraintEqualToAnchor:line.bottomAnchor constant:10],
        [footer.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],

        [card.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-32],
    ]];
}

@end


#pragma mark - Hook 设置主页：注入 XHS778 入口行

static char kXHS778OriginalRowsKey;

%hook XYPHSettingViewController

- (void)viewDidLoad {
    %orig;
    // 让 tableView 重新加载以触发我们追加的 row
    if (self.tableView) {
        [self.tableView reloadData];
    }
}

- (long long)tableView:(UITableView *)tableView numberOfRowsInSection:(long long)section {
    long long original = %orig;
    long long sectionsCount = [tableView numberOfSections];
    if (section == sectionsCount - 1) {
        objc_setAssociatedObject(self, &kXHS778OriginalRowsKey, @(original), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return original + 1;
    }
    return original;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    long long sectionsCount = [tableView numberOfSections];
    if (indexPath.section == sectionsCount - 1) {
        NSNumber *originalRows = objc_getAssociatedObject(self, &kXHS778OriginalRowsKey);
        if (originalRows && indexPath.row == originalRows.integerValue) {
            // 我们追加的入口行
            static NSString *cellId = @"XHS778EntryCell";
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
            }

            // 清理重用残留
            for (UIView *v in cell.contentView.subviews) {
                if (v.tag == 7780001 || v.tag == 7780002 || v.tag == 7780003 || v.tag == 7780004) {
                    [v removeFromSuperview];
                }
            }

            cell.backgroundColor = [UIColor clearColor];
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.textLabel.text = @"";
            cell.detailTextLabel.text = @"";

            // 自定义 icon
            UIView *iconBg = [[UIView alloc] initWithFrame:CGRectMake(16, 12, 28, 28)];
            iconBg.tag = 7780001;
            iconBg.backgroundColor = XHS778ColorPrimary();
            iconBg.layer.cornerRadius = 8;
            [cell.contentView addSubview:iconBg];

            UILabel *iconLabel = [[UILabel alloc] initWithFrame:iconBg.bounds];
            iconLabel.tag = 7780002;
            iconLabel.text = @"7";
            iconLabel.textColor = [UIColor whiteColor];
            iconLabel.textAlignment = NSTextAlignmentCenter;
            iconLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightHeavy];
            [iconBg addSubview:iconLabel];

            UILabel *titleLabel = [[UILabel alloc] init];
            titleLabel.tag = 7780003;
            titleLabel.text = @"XHS778";
            titleLabel.font = [UIFont systemFontOfSize:16];
            titleLabel.textColor = XHS778ColorTitleText();
            titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:titleLabel];

            UILabel *badge = [[UILabel alloc] init];
            badge.tag = 7780004;
            badge.text = @"  表情包保存助手  ";
            badge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
            badge.textColor = XHS778ColorPrimary();
            badge.backgroundColor = [XHS778ColorPrimary() colorWithAlphaComponent:0.10];
            badge.layer.cornerRadius = 4;
            badge.layer.masksToBounds = YES;
            badge.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:badge];

            [NSLayoutConstraint activateConstraints:@[
                [titleLabel.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:56],
                [titleLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],

                [badge.leadingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor constant:8],
                [badge.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [badge.heightAnchor constraintEqualToConstant:18],
            ]];

            return cell;
        }
    }
    return %orig;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    long long sectionsCount = [tableView numberOfSections];
    if (indexPath.section == sectionsCount - 1) {
        NSNumber *originalRows = objc_getAssociatedObject(self, &kXHS778OriginalRowsKey);
        if (originalRows && indexPath.row == originalRows.integerValue) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            XHS778SettingsVC *vc = [[XHS778SettingsVC alloc] init];
            if (self.navigationController) {
                [self.navigationController pushViewController:vc animated:YES];
            } else {
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
                nav.modalPresentationStyle = UIModalPresentationFullScreen;
                [self presentViewController:nav animated:YES completion:nil];
            }
            return;
        }
    }
    %orig;
}

- (double)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    long long sectionsCount = [tableView numberOfSections];
    if (indexPath.section == sectionsCount - 1) {
        NSNumber *originalRows = objc_getAssociatedObject(self, &kXHS778OriginalRowsKey);
        if (originalRows && indexPath.row == originalRows.integerValue) {
            return 52.0;
        }
    }
    return %orig;
}

- (double)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath {
    long long sectionsCount = [tableView numberOfSections];
    if (indexPath.section == sectionsCount - 1) {
        NSNumber *originalRows = objc_getAssociatedObject(self, &kXHS778OriginalRowsKey);
        if (originalRows && indexPath.row == originalRows.integerValue) {
            return 52.0;
        }
    }
    return %orig;
}

%end


#pragma mark - Hook 评论 view (Swift class)：记录最近一次长按的评论

static void XHS778RecordCommentTouches(UIView *commentView) {
    if (!commentView) return;
    gXHS778LastLongPressedCommentView = commentView;
    XYAnimatedImageView *iv = XHS778FindAnimatedImageView(commentView);
    gXHS778LastLongPressedEmojiView = iv;
}

%ctor {
    @autoreleasepool {
        // Swift 类名带点号，需要 runtime 方式 hook
        Class commentCls = NSClassFromString(@"XYNoteModule.CommentEntityView");
        if (commentCls) {
            SEL origSel = @selector(touchesBegan:withEvent:);
            Method origMethod = class_getInstanceMethod(commentCls, origSel);
            if (origMethod) {
                IMP origImp = method_getImplementation(origMethod);
                IMP newImp = imp_implementationWithBlock(^(UIView *self, NSSet *touches, UIEvent *event) {
                    XHS778RecordCommentTouches(self);
                    ((void (*)(id, SEL, id, id))origImp)(self, origSel, touches, event);
                });
                method_setImplementation(origMethod, newImp);
            }
        }

        // 兼容旧版/横屏类
        Class landscapeCls = NSClassFromString(@"XYOldNoteModule.LandscapeCommentEntityView");
        if (landscapeCls) {
            SEL origSel = @selector(touchesBegan:withEvent:);
            Method origMethod = class_getInstanceMethod(landscapeCls, origSel);
            if (origMethod) {
                IMP origImp = method_getImplementation(origMethod);
                IMP newImp = imp_implementationWithBlock(^(UIView *self, NSSet *touches, UIEvent *event) {
                    XHS778RecordCommentTouches(self);
                    ((void (*)(id, SEL, id, id))origImp)(self, origSel, touches, event);
                });
                method_setImplementation(origMethod, newImp);
            }
        }
    }
}


#pragma mark - Hook 长按菜单：在「添加表情」下方插入「保存表情」

static char kXHS778SavePanelInjectedKey;
static const NSInteger kXHS778SaveCellTag = 778002;

%hook XYCommentFeedbackPanelController

- (void)viewDidLoad {
    %orig;
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [self xhs778_injectSaveButtonIfNeeded];
}

- (void)viewDidLayoutSubviews {
    %orig;
    [self xhs778_injectSaveButtonIfNeeded];
}

%new
- (void)xhs778_injectSaveButtonIfNeeded {
    if (!XHS778Enabled() || !XHS778CommentSaveEnabled()) return;
    if (objc_getAssociatedObject(self, &kXHS778SavePanelInjectedKey)) return;
    if (!gXHS778LastLongPressedEmojiView) return; // 没有可保存的表情，不显示

    UITableView *tv = self.tableView;
    if (!tv || tv.bounds.size.height <= 0) return;

    UIView *feedback = self.feedbackView;
    if (!feedback) return;

    // 防止重复注入
    if ([feedback viewWithTag:kXHS778SaveCellTag]) {
        objc_setAssociatedObject(self, &kXHS778SavePanelInjectedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    // 在 tableView 顶部之上、feedbackView 顶端，放置一个独立的「保存表情」入口
    // 这样视觉上紧贴所有菜单项之上，不破坏原 tableView 的 section 圆角
    const CGFloat rowHeight = 52.0;
    const CGFloat sidePadding = 12.0;

    // 扩展 feedbackView，向上长出 rowHeight + 6（间距）
    CGRect ff = feedback.frame;
    ff.origin.y -= (rowHeight + 6);
    ff.size.height += (rowHeight + 6);
    feedback.frame = ff;

    UIControl *saveRow = [[UIControl alloc] initWithFrame:CGRectMake(sidePadding, 0,
                                                                     feedback.bounds.size.width - sidePadding * 2,
                                                                     rowHeight)];
    saveRow.tag = kXHS778SaveCellTag;
    saveRow.backgroundColor = XHS778ColorCard();
    saveRow.layer.cornerRadius = 12;
    saveRow.layer.masksToBounds = YES;
    saveRow.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [saveRow addTarget:self action:@selector(xhs778_onSavePressed) forControlEvents:UIControlEventTouchUpInside];
    [feedback addSubview:saveRow];

    UIView *iconBg = [[UIView alloc] init];
    iconBg.backgroundColor = [XHS778ColorPrimary() colorWithAlphaComponent:0.12];
    iconBg.layer.cornerRadius = 8;
    iconBg.userInteractionEnabled = NO;
    iconBg.translatesAutoresizingMaskIntoConstraints = NO;
    [saveRow addSubview:iconBg];

    UIImageView *icon = [[UIImageView alloc] init];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = XHS778ColorPrimary();
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        icon.image = [UIImage systemImageNamed:@"square.and.arrow.down"];
    }
    [iconBg addSubview:icon];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"保存表情";
    titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    titleLabel.textColor = XHS778ColorTitleText();
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [saveRow addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = @"将表情图片或 GIF 保存到相册";
    subtitleLabel.font = [UIFont systemFontOfSize:11];
    subtitleLabel.textColor = XHS778ColorSecondaryText();
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [saveRow addSubview:subtitleLabel];

    UILabel *badge = [[UILabel alloc] init];
    badge.text = @"  XHS778  ";
    badge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    badge.textColor = XHS778ColorPrimary();
    badge.backgroundColor = [XHS778ColorPrimary() colorWithAlphaComponent:0.10];
    badge.layer.cornerRadius = 4;
    badge.layer.masksToBounds = YES;
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    [saveRow addSubview:badge];

    [NSLayoutConstraint activateConstraints:@[
        [iconBg.leadingAnchor constraintEqualToAnchor:saveRow.leadingAnchor constant:14],
        [iconBg.centerYAnchor constraintEqualToAnchor:saveRow.centerYAnchor],
        [iconBg.widthAnchor constraintEqualToConstant:34],
        [iconBg.heightAnchor constraintEqualToConstant:34],

        [icon.centerXAnchor constraintEqualToAnchor:iconBg.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:iconBg.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:20],
        [icon.heightAnchor constraintEqualToConstant:20],

        [titleLabel.leadingAnchor constraintEqualToAnchor:iconBg.trailingAnchor constant:12],
        [titleLabel.topAnchor constraintEqualToAnchor:saveRow.topAnchor constant:9],

        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2],

        [badge.trailingAnchor constraintEqualToAnchor:saveRow.trailingAnchor constant:-14],
        [badge.centerYAnchor constraintEqualToAnchor:saveRow.centerYAnchor],
        [badge.heightAnchor constraintEqualToConstant:16],
    ]];

    // tableView 整体下移 (rowHeight + 6)，给 saveRow 留出空间
    CGRect tvFrame = tv.frame;
    tvFrame.origin.y += (rowHeight + 6);
    tv.frame = tvFrame;

    // 同时也下移 stickyView（如果有）和其它兄弟视图
    for (UIView *sub in feedback.subviews) {
        if (sub == saveRow || sub == tv) continue;
        // 仅下移那些原本和 tableView 大致同高的兄弟（不影响 maskContentView 等顶层装饰）
        if (CGRectGetMinY(sub.frame) >= 0 && sub.bounds.size.height < feedback.bounds.size.height) {
            CGRect f = sub.frame;
            f.origin.y += (rowHeight + 6);
            sub.frame = f;
        }
    }

    objc_setAssociatedObject(self, &kXHS778SavePanelInjectedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new
- (UILabel *)xhs778_findLabelInView:(UIView *)view {
    if ([view isKindOfClass:[UILabel class]]) return (UILabel *)view;
    for (UIView *sub in view.subviews) {
        UILabel *l = [self xhs778_findLabelInView:sub];
        if (l && l.text.length) return l;
    }
    return nil;
}

%new
- (void)xhs778_onSavePressed {
    XYAnimatedImageView *iv = gXHS778LastLongPressedEmojiView;
    UIView *commentView = gXHS778LastLongPressedCommentView;

    [self dismissFeedbackView];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (iv) {
            XHS778SaveEmojiFromImageView(iv);
        } else if (commentView) {
            XHS778SaveEmojiFromCommentView(commentView);
        } else {
            XHS778ShowToast(@"未找到表情图片");
        }
    });
}

%end
