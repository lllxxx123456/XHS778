// Tweak.xm - XHS778 小红书表情包保存助手
// Author: lllxxx123456
// 测试版本：XHS 9.28.1

#import "XHS778Headers.h"

#pragma mark - 设置存储 Key（所有开关默认关）

static NSString * const kXHS778EnabledKey            = @"XHS778_Enabled";
static NSString * const kXHS778CommentSaveEnabledKey = @"XHS778_CommentSaveEnabled";
static NSString * const kXHS778PreviewSaveEnabledKey = @"XHS778_PreviewSaveEnabled";
static NSString * const kXHS778SenderMenuSaveKey     = @"XHS778_SenderMenuSaveEnabled";
static NSString * const kXHS778DisclaimerAcceptedKey = @"XHS778_DisclaimerAccepted";

static BOOL XHS778Enabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kXHS778EnabledKey];
}
static BOOL XHS778CommentSaveEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kXHS778CommentSaveEnabledKey];
}
static BOOL XHS778PreviewSaveEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kXHS778PreviewSaveEnabledKey];
}
static BOOL XHS778SenderMenuSaveEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kXHS778SenderMenuSaveKey];
}
static BOOL XHS778DisclaimerAccepted(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kXHS778DisclaimerAcceptedKey];
}
static void XHS778SetDisclaimerAccepted(void) {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kXHS778DisclaimerAcceptedKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
static void XHS778TerminateApp(void) {
    // 触发应用退出（用户拒绝免责声明时调用）
    UIApplication *app = [UIApplication sharedApplication];
    SEL sel = NSSelectorFromString(@"terminateWithSuccess");
    if ([app respondsToSelector:sel]) {
        ((void (*)(id, SEL))objc_msgSend)(app, sel);
    } else {
        exit(0);
    }
}

#pragma mark - 全局状态

static __weak UIView *gXHS778LastLongPressedCommentView = nil;
static __weak XYAnimatedImageView *gXHS778LastLongPressedEmojiView = nil;

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

static UILabel *XHS778FindLabel(UIView *root) {
    if (!root) return nil;
    if ([root isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)root;
        if (l.text.length > 0) return l;
    }
    for (UIView *sub in root.subviews) {
        UILabel *l = XHS778FindLabel(sub);
        if (l) return l;
    }
    return nil;
}

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

static void XHS778SaveEmojiFromCommentView(UIView *commentView) {
    if (!commentView) {
        XHS778ShowToast(@"未找到评论视图");
        return;
    }
    XYAnimatedImageView *iv = XHS778FindAnimatedImageView(commentView);
    XHS778SaveEmojiFromImageView(iv);
}

static void XHS778SaveImageObject(UIImage *image) {
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

#pragma mark - 首次使用风险提示 VC（3 秒倒计时 + 接受/退出）

@interface XHS778DisclaimerVC : UIViewController
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIButton *acceptButton;
@property (nonatomic, strong) UIButton *rejectButton;
@property (nonatomic, assign) NSInteger countdown;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) void (^onAccept)(void);
@end

@implementation XHS778DisclaimerVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    self.countdown = 3;

    CGFloat screenWidth = CGRectGetWidth([UIScreen mainScreen].bounds);
    CGFloat screenHeight = CGRectGetHeight([UIScreen mainScreen].bounds);
    CGFloat cardWidth = MIN(screenWidth - 56, 360);
    CGFloat cardHeight = 360;

    self.card = [[UIView alloc] initWithFrame:CGRectMake((screenWidth - cardWidth) / 2.0,
                                                         (screenHeight - cardHeight) / 2.0,
                                                         cardWidth, cardHeight)];
    self.card.layer.cornerRadius = 18;
    self.card.layer.masksToBounds = YES;
    [self.view addSubview:self.card];

    self.blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    self.blurView.frame = self.card.bounds;
    self.blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.card addSubview:self.blurView];

    // 顶部红色警示图标
    UIImageView *warnIcon = [[UIImageView alloc] init];
    warnIcon.contentMode = UIViewContentModeScaleAspectFit;
    warnIcon.tintColor = [UIColor systemRedColor];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:36 weight:UIImageSymbolWeightSemibold];
        warnIcon.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill" withConfiguration:cfg];
    }
    warnIcon.frame = CGRectMake((cardWidth - 50) / 2.0, 22, 50, 44);
    [self.blurView.contentView addSubview:warnIcon];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 70, cardWidth, 28)];
    titleLabel.text = @"使用须知";
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor labelColor];
    [self.blurView.contentView addSubview:titleLabel];

    // 风险提示文本
    UILabel *contentLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 108, cardWidth - 40, 170)];
    contentLabel.numberOfLines = 0;
    contentLabel.font = [UIFont systemFontOfSize:13];
    contentLabel.textColor = [UIColor labelColor];
    NSString *raw = @"本插件仅用于学习交流，请尊重原作者的版权。\n\n"
                    @"保存的表情仅供个人使用，请勿用于商业用途或二次传播。\n\n"
                    @"使用本插件可能违反小红书用户协议，由此引发的账号风险请自行承担。";
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineSpacing = 3;
    ps.paragraphSpacing = 4;
    contentLabel.attributedText = [[NSAttributedString alloc] initWithString:raw attributes:@{
        NSFontAttributeName: contentLabel.font,
        NSForegroundColorAttributeName: contentLabel.textColor,
        NSParagraphStyleAttributeName: ps,
    }];
    [self.blurView.contentView addSubview:contentLabel];

    // 底部分隔线
    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, cardHeight - 56, cardWidth, 0.5)];
    sep.backgroundColor = [[UIColor separatorColor] colorWithAlphaComponent:0.4];
    [self.blurView.contentView addSubview:sep];

    // 左：我不用了
    self.rejectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.rejectButton.frame = CGRectMake(0, cardHeight - 55, cardWidth / 2.0, 55);
    [self.rejectButton setTitle:@"我不用了" forState:UIControlStateNormal];
    [self.rejectButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    self.rejectButton.titleLabel.font = [UIFont systemFontOfSize:15];
    [self.rejectButton addTarget:self action:@selector(_onReject) forControlEvents:UIControlEventTouchUpInside];
    [self.blurView.contentView addSubview:self.rejectButton];

    // 中间竖线
    UIView *vSep = [[UIView alloc] initWithFrame:CGRectMake(cardWidth / 2.0, cardHeight - 55, 0.5, 55)];
    vSep.backgroundColor = [[UIColor separatorColor] colorWithAlphaComponent:0.4];
    [self.blurView.contentView addSubview:vSep];

    // 右：确定（倒计时 3 秒后启用）
    self.acceptButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.acceptButton.frame = CGRectMake(cardWidth / 2.0, cardHeight - 55, cardWidth / 2.0, 55);
    [self.acceptButton setTitle:@"确定 (3)" forState:UIControlStateNormal];
    [self.acceptButton setTitleColor:[UIColor tertiaryLabelColor] forState:UIControlStateDisabled];
    [self.acceptButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    self.acceptButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.acceptButton.enabled = NO;
    [self.acceptButton addTarget:self action:@selector(_onAccept) forControlEvents:UIControlEventTouchUpInside];
    [self.blurView.contentView addSubview:self.acceptButton];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self _startCountdown];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self _stopCountdown];
}

- (void)_startCountdown {
    [self _stopCountdown];
    self.countdown = 3;
    [self _refreshAcceptTitle];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(_onTick) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)_stopCountdown {
    if (self.timer) {
        [self.timer invalidate];
        self.timer = nil;
    }
}

- (void)_onTick {
    self.countdown -= 1;
    if (self.countdown <= 0) {
        [self _stopCountdown];
        self.acceptButton.enabled = YES;
        [self.acceptButton setTitle:@"确定并继续使用" forState:UIControlStateNormal];
    } else {
        [self _refreshAcceptTitle];
    }
}

- (void)_refreshAcceptTitle {
    [self.acceptButton setTitle:[NSString stringWithFormat:@"确定 (%ld)", (long)self.countdown] forState:UIControlStateNormal];
}

- (void)_onAccept {
    XHS778SetDisclaimerAccepted();
    void (^cb)(void) = self.onAccept;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb();
    }];
}

- (void)_onReject {
    [self dismissViewControllerAnimated:YES completion:^{
        XHS778TerminateApp();
    }];
}

@end


#pragma mark - 设置 VC（原创设计 · 自适应深浅色）

@interface XHS778SettingsVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, copy) NSArray<NSDictionary *> *sections;
@end

@implementation XHS778SettingsVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];

    CGFloat sw = CGRectGetWidth([UIScreen mainScreen].bounds);
    CGFloat sh = CGRectGetHeight([UIScreen mainScreen].bounds);
    CGFloat cw = MIN(sw - 32, 380);
    CGFloat ch = MIN(sh - 100, 620);

    self.card = [[UIView alloc] initWithFrame:CGRectMake((sw - cw) / 2.0, (sh - ch) / 2.0, cw, ch)];
    self.card.layer.cornerRadius = 22;
    self.card.layer.masksToBounds = YES;
    [self.view addSubview:self.card];

    UIBlurEffect *eff;
    if (@available(iOS 13.0, *)) {
        eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    } else {
        eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
    }
    self.blurView = [[UIVisualEffectView alloc] initWithEffect:eff];
    self.blurView.frame = self.card.bounds;
    self.blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.card addSubview:self.blurView];

    [self _buildTopBar];
    [self _buildSections];
    [self _buildTable];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_onBgTap:)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];
}

- (void)_buildTopBar {
    CGFloat W = self.card.bounds.size.width;
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 50)];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.blurView.contentView addSubview:bar];

    UIButton *exitBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    exitBtn.frame = CGRectMake(8, 7, 36, 36);
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
        [exitBtn setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:cfg] forState:UIControlStateNormal];
    } else {
        [exitBtn setTitle:@"✕" forState:UIControlStateNormal];
    }
    exitBtn.tintColor = [UIColor labelColor];
    [exitBtn addTarget:self action:@selector(_onExitApp) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:exitBtn];

    UILabel *t = [[UILabel alloc] initWithFrame:bar.bounds];
    t.text = @"XHS778";
    t.textAlignment = NSTextAlignmentCenter;
    t.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    t.textColor = [UIColor labelColor];
    t.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [bar addSubview:t];

    UIButton *doneBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    doneBtn.frame = CGRectMake(W - 64, 7, 56, 36);
    doneBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [doneBtn setTitle:@"完成" forState:UIControlStateNormal];
    doneBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [doneBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [doneBtn addTarget:self action:@selector(_onClose) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:doneBtn];

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, 50, W, 0.5)];
    sep.backgroundColor = [[UIColor separatorColor] colorWithAlphaComponent:0.4];
    sep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.blurView.contentView addSubview:sep];
}

- (void)_buildSections {
    self.sections = @[
        @{@"title": @"总开关", @"items": @[
            @{@"icon": @"power.circle.fill", @"iconColor": @"red",
              @"title": @"启用 XHS778",
              @"detail": @"插件总开关，关闭后所有功能停用",
              @"key": kXHS778EnabledKey, @"isMaster": @YES, @"type": @"switch"},
        ]},
        @{@"title": @"保存功能", @"items": @[
            @{@"icon": @"text.bubble.fill", @"iconColor": @"orange",
              @"title": @"长按评论保存",
              @"detail": @"长按表情评论 → 显示「保存表情」",
              @"key": kXHS778CommentSaveEnabledKey, @"type": @"switch"},
            @{@"icon": @"photo.fill", @"iconColor": @"blue",
              @"title": @"详情页保存",
              @"detail": @"表情详情页「添加表情」下方加保存按钮",
              @"key": kXHS778PreviewSaveEnabledKey, @"type": @"switch"},
            @{@"icon": @"square.and.arrow.up.fill", @"iconColor": @"green",
              @"title": @"发送菜单保存",
              @"detail": @"长按已添加/推荐表情 → 圆形保存图标",
              @"key": kXHS778SenderMenuSaveKey, @"type": @"switch"},
        ]},
        @{@"title": @"关于", @"items": @[
            @{@"icon": @"doc.text.fill", @"iconColor": @"gray",
              @"title": @"重新阅读使用须知",
              @"type": @"action", @"action": @"showDisclaimer"},
            @{@"icon": @"info.circle.fill", @"iconColor": @"gray",
              @"title": @"版本",
              @"detail": @"1.0-1 · 适配 XHS 9.28.1",
              @"type": @"info"},
        ]},
    ];
}

- (void)_buildTable {
    CGFloat W = self.card.bounds.size.width;
    CGFloat H = self.card.bounds.size.height;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 51, W, H - 51) style:UITableViewStyleGrouped];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.showsVerticalScrollIndicator = NO;
    self.tableView.estimatedRowHeight = 0;
    self.tableView.estimatedSectionHeaderHeight = 0;
    self.tableView.estimatedSectionFooterHeight = 0;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 16, 0);

    // tableHeaderView：图标 + 名称 + 版本
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 132)];
    UIView *iconBg = [[UIView alloc] initWithFrame:CGRectMake((W - 64) / 2.0, 16, 64, 64)];
    iconBg.layer.cornerRadius = 16;
    iconBg.layer.masksToBounds = YES;
    iconBg.backgroundColor = [UIColor systemRedColor];
    iconBg.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    UIImageView *iv = [[UIImageView alloc] initWithFrame:iconBg.bounds];
    iv.contentMode = UIViewContentModeCenter;
    iv.tintColor = [UIColor whiteColor];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:34 weight:UIImageSymbolWeightSemibold];
        iv.image = [UIImage systemImageNamed:@"face.smiling.fill" withConfiguration:cfg];
    }
    [iconBg addSubview:iv];
    [header addSubview:iconBg];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(0, 84, W, 20)];
    name.text = @"小红书表情包保存助手";
    name.textAlignment = NSTextAlignmentCenter;
    name.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    name.textColor = [UIColor labelColor];
    name.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:name];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(0, 106, W, 18)];
    sub.text = @"v1.0-1  ·  XHS 9.28.1";
    sub.textAlignment = NSTextAlignmentCenter;
    sub.font = [UIFont systemFontOfSize:11];
    sub.textColor = [UIColor secondaryLabelColor];
    sub.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:sub];
    self.tableView.tableHeaderView = header;

    // tableFooterView：风险提示
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 36)];
    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, W - 32, 36)];
    tip.text = @"⚠ 仅供学习交流，请尊重原作者版权";
    tip.font = [UIFont systemFontOfSize:11];
    tip.textColor = [UIColor tertiaryLabelColor];
    tip.textAlignment = NSTextAlignmentCenter;
    tip.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [footer addSubview:tip];
    self.tableView.tableFooterView = footer;

    [self.blurView.contentView addSubview:self.tableView];
}

- (void)_onClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)_onBgTap:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.view];
    if (!CGRectContainsPoint(self.card.frame, p)) [self _onClose];
}

- (void)_onExitApp {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"退出小红书"
                                                                message:@"确定要退出小红书吗？"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"退出" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
        XHS778TerminateApp();
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (UIColor *)_iconColorWithName:(NSString *)name {
    if ([name isEqualToString:@"red"]) return [UIColor systemRedColor];
    if ([name isEqualToString:@"orange"]) return [UIColor systemOrangeColor];
    if ([name isEqualToString:@"blue"]) return [UIColor systemBlueColor];
    if ([name isEqualToString:@"green"]) return [UIColor systemGreenColor];
    if ([name isEqualToString:@"gray"]) return [UIColor systemGrayColor];
    return [UIColor systemRedColor];
}

#pragma mark - TableView DataSource & Delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.sections[section][@"items"] count];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 36.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *header = [[UIView alloc] init];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(28, 8, 240, 22)];
    l.text = self.sections[section][@"title"];
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    l.textColor = [UIColor secondaryLabelColor];
    [header addSubview:l];
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return 0.1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.sections[indexPath.section][@"items"][indexPath.row];
    return item[@"detail"] ? 64.0 : 50.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.sections[indexPath.section][@"items"][indexPath.row];
    NSArray *items = self.sections[indexPath.section][@"items"];
    BOOL isFirst = (indexPath.row == 0);
    BOOL isLast = (indexPath.row == items.count - 1);

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = [UIColor clearColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    CGFloat W = self.tableView.bounds.size.width;
    CGFloat H = [self tableView:tableView heightForRowAtIndexPath:indexPath];

    // 卡片背景：依据是否首/末 row 决定圆角
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16, 0, W - 32, H)];
    card.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:0.85];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    card.layer.masksToBounds = YES;
    if (isFirst && isLast) {
        card.layer.cornerRadius = 14;
    } else if (isFirst) {
        card.layer.cornerRadius = 14;
        card.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    } else if (isLast) {
        card.layer.cornerRadius = 14;
        card.layer.maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    }
    [cell.contentView insertSubview:card atIndex:0];

    if (!isLast) {
        UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(60, H - 0.5, W - 76, 0.5)];
        sep.backgroundColor = [[UIColor separatorColor] colorWithAlphaComponent:0.35];
        sep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [cell.contentView addSubview:sep];
    }

    // 图标块
    UIView *iconBg = [[UIView alloc] initWithFrame:CGRectMake(28, (H - 28) / 2.0, 28, 28)];
    iconBg.backgroundColor = [self _iconColorWithName:item[@"iconColor"]];
    iconBg.layer.cornerRadius = 7;
    iconBg.layer.masksToBounds = YES;
    [cell.contentView addSubview:iconBg];

    UIImageView *iv = [[UIImageView alloc] initWithFrame:iconBg.bounds];
    iv.contentMode = UIViewContentModeCenter;
    iv.tintColor = [UIColor whiteColor];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
        iv.image = [UIImage systemImageNamed:item[@"icon"] withConfiguration:cfg];
    }
    [iconBg addSubview:iv];

    NSString *type = item[@"type"];
    NSString *detail = item[@"detail"];

    if (detail) {
        UILabel *titleLb = [[UILabel alloc] initWithFrame:CGRectMake(68, 11, W - 130, 20)];
        titleLb.text = item[@"title"];
        titleLb.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        titleLb.textColor = [UIColor labelColor];
        titleLb.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [cell.contentView addSubview:titleLb];

        UILabel *subLb = [[UILabel alloc] initWithFrame:CGRectMake(68, 33, W - 130, 18)];
        subLb.text = detail;
        subLb.font = [UIFont systemFontOfSize:11];
        subLb.textColor = [UIColor secondaryLabelColor];
        subLb.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [cell.contentView addSubview:subLb];
    } else {
        UILabel *titleLb = [[UILabel alloc] initWithFrame:CGRectMake(68, 0, W - 130, H)];
        titleLb.text = item[@"title"];
        titleLb.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        titleLb.textColor = [UIColor labelColor];
        titleLb.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [cell.contentView addSubview:titleLb];
    }

    if ([type isEqualToString:@"switch"]) {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.transform = CGAffineTransformMakeScale(0.85, 0.85);
        sw.onTintColor = [UIColor systemRedColor];
        sw.on = [[NSUserDefaults standardUserDefaults] boolForKey:item[@"key"]];
        sw.tag = (indexPath.section << 16) | indexPath.row;
        [sw addTarget:self action:@selector(_onSwitchChanged:) forControlEvents:UIControlEventValueChanged];

        BOOL isMaster = [item[@"isMaster"] boolValue];
        if (!isMaster) {
            BOOL master = XHS778Enabled();
            sw.enabled = master;
            cell.contentView.alpha = master ? 1.0 : 0.4;
        }
        cell.accessoryView = sw;
    } else if ([type isEqualToString:@"action"]) {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        UIImageView *chev = [[UIImageView alloc] init];
        chev.tintColor = [UIColor tertiaryLabelColor];
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
            chev.image = [UIImage systemImageNamed:@"chevron.right" withConfiguration:cfg];
        }
        chev.frame = CGRectMake(W - 44, (H - 16) / 2.0, 12, 16);
        chev.contentMode = UIViewContentModeScaleAspectFit;
        chev.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [cell.contentView addSubview:chev];
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = self.sections[indexPath.section][@"items"][indexPath.row];
    NSString *action = item[@"action"];
    if ([action isEqualToString:@"showDisclaimer"]) {
        XHS778DisclaimerVC *dvc = [[XHS778DisclaimerVC alloc] init];
        dvc.modalPresentationStyle = UIModalPresentationOverFullScreen;
        dvc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        [self presentViewController:dvc animated:YES completion:nil];
    }
}

- (void)_onSwitchChanged:(UISwitch *)sw {
    NSInteger section = sw.tag >> 16;
    NSInteger row = sw.tag & 0xFFFF;
    NSDictionary *item = self.sections[section][@"items"][row];
    NSString *key = item[@"key"];
    [[NSUserDefaults standardUserDefaults] setBool:sw.isOn forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];

    if ([item[@"isMaster"] boolValue]) {
        [self.tableView reloadData];
    }
}

@end


#pragma mark - Hook 评论 view (Swift class)：记录最近一次长按的评论

static void XHS778RecordCommentTouches(UIView *commentView) {
    if (!commentView) return;
    gXHS778LastLongPressedCommentView = commentView;
    XYAnimatedImageView *iv = XHS778FindAnimatedImageView(commentView);
    gXHS778LastLongPressedEmojiView = iv;
}

static void XHS778AddPreviewSaveButton(UIViewController *vc);

// 安全的 method swizzle：如果子类未重写则给子类添加方法（避免污染父类），否则替换 IMP
static void XHS778SwizzleInstanceMethod(Class cls, SEL sel, IMP newImp) {
    if (!cls || !sel || !newImp) return;
    Method origMethod = class_getInstanceMethod(cls, sel);
    if (!origMethod) return;
    const char *types = method_getTypeEncoding(origMethod);
    BOOL added = class_addMethod(cls, sel, newImp, types);
    if (!added) {
        // 子类已有此方法，直接替换
        method_setImplementation(origMethod, newImp);
    }
    // added 为真时不替换原 method，因为原 method 在父类，已通过 origImp 在 block 内捕获
}

%ctor {
    @autoreleasepool {
        // (1) 评论 view 触摸追踪
        NSArray *commentClassNames = @[
            @"XYNoteModule.CommentEntityView",
            @"XYOldNoteModule.LandscapeCommentEntityView",
        ];
        for (NSString *clsName in commentClassNames) {
            Class cls = NSClassFromString(clsName);
            if (!cls) continue;
            SEL origSel = @selector(touchesBegan:withEvent:);
            Method origMethod = class_getInstanceMethod(cls, origSel);
            if (!origMethod) continue;
            IMP origImp = method_getImplementation(origMethod);
            IMP newImp = imp_implementationWithBlock(^(UIView *self, NSSet *touches, UIEvent *event) {
                XHS778RecordCommentTouches(self);
                ((void (*)(id, SEL, id, id))origImp)(self, origSel, touches, event);
            });
            XHS778SwizzleInstanceMethod(cls, origSel, newImp);
        }

        // (2) 表情详情页 MemePreviewPageController：viewDidAppear: 与 viewDidLayoutSubviews
        Class previewCls = NSClassFromString(@"_TtC12XYNoteModule25MemePreviewPageController");
        if (previewCls) {
            // viewDidAppear:
            {
                SEL sel = @selector(viewDidAppear:);
                Method m = class_getInstanceMethod(previewCls, sel);
                if (m) {
                    IMP origImp = method_getImplementation(m);
                    IMP newImp = imp_implementationWithBlock(^(UIViewController *self, BOOL animated) {
                        ((void (*)(id, SEL, BOOL))origImp)(self, sel, animated);
                        XHS778AddPreviewSaveButton(self);
                    });
                    XHS778SwizzleInstanceMethod(previewCls, sel, newImp);
                }
            }
            // viewDidLayoutSubviews
            {
                SEL sel = @selector(viewDidLayoutSubviews);
                Method m = class_getInstanceMethod(previewCls, sel);
                if (m) {
                    IMP origImp = method_getImplementation(m);
                    IMP newImp = imp_implementationWithBlock(^(UIViewController *self) {
                        ((void (*)(id, SEL))origImp)(self, sel);
                        XHS778AddPreviewSaveButton(self);
                    });
                    XHS778SwizzleInstanceMethod(previewCls, sel, newImp);
                }
            }
        }
    }
}


#pragma mark - Hook 设置主页：在「隐私设置」section 下方插入独立 XHS778 section（仿 DYYY 样式）

static char kXHS778PrivacySectionKey;   // 缓存「隐私设置」所在 section 索引（NSNumber）
static char kXHS778PrivacyScannedKey;

@interface XYPHSettingViewController (XHS778)
- (UITableViewCell *)xhs778_makeEntryCell;
- (void)xhs778_presentEntry;
@end

static long long XHS778GetPrivacySection(id self) {
    NSNumber *n = objc_getAssociatedObject(self, &kXHS778PrivacySectionKey);
    return n ? [n longLongValue] : -1;
}

%hook XYPHSettingViewController

- (void)viewDidLoad {
    %orig;
    objc_setAssociatedObject(self, &kXHS778PrivacySectionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kXHS778PrivacyScannedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (long long)numberOfSectionsInTableView:(UITableView *)tableView {
    long long original = %orig;
    long long ps = XHS778GetPrivacySection(self);
    return (ps >= 0) ? (original + 1) : original;
}

- (long long)tableView:(UITableView *)tableView numberOfRowsInSection:(long long)section {
    long long ps = XHS778GetPrivacySection(self);
    if (ps >= 0) {
        if (section == ps + 1) return 1;                         // 我们的 section
        if (section > ps + 1) return %orig(tableView, section - 1);
    }
    return %orig;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    long long ps = XHS778GetPrivacySection(self);
    if (ps >= 0) {
        if (indexPath.section == ps + 1) {
            return [self xhs778_makeEntryCell];
        }
        if (indexPath.section > ps + 1) {
            NSIndexPath *origIp = [NSIndexPath indexPathForRow:indexPath.row inSection:indexPath.section - 1];
            return %orig(tableView, origIp);
        }
    }

    UITableViewCell *cell = %orig;

    // 扫描隐私设置 section
    NSNumber *scanned = objc_getAssociatedObject(self, &kXHS778PrivacyScannedKey);
    if (!scanned.boolValue && ps < 0) {
        UILabel *l = XHS778FindLabel(cell.contentView);
        if (l.text.length && [l.text isEqualToString:@"隐私设置"]) {
            objc_setAssociatedObject(self, &kXHS778PrivacySectionKey, @(indexPath.section), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, &kXHS778PrivacyScannedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak typeof(self) ws = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(ws) ss = ws;
                if (ss && ss.tableView) [ss.tableView reloadData];
            });
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    long long ps = XHS778GetPrivacySection(self);
    if (ps >= 0) {
        if (indexPath.section == ps + 1) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            [self xhs778_presentEntry];
            return;
        }
        if (indexPath.section > ps + 1) {
            NSIndexPath *origIp = [NSIndexPath indexPathForRow:indexPath.row inSection:indexPath.section - 1];
            %orig(tableView, origIp);
            return;
        }
    }
    %orig;
}

- (double)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    long long ps = XHS778GetPrivacySection(self);
    if (ps >= 0) {
        if (indexPath.section == ps + 1) {
            // 复用原「隐私设置」行高，保持视觉一致
            NSIndexPath *probe = [NSIndexPath indexPathForRow:0 inSection:ps];
            return %orig(tableView, probe);
        }
        if (indexPath.section > ps + 1) {
            NSIndexPath *origIp = [NSIndexPath indexPathForRow:indexPath.row inSection:indexPath.section - 1];
            return %orig(tableView, origIp);
        }
    }
    return %orig;
}

- (double)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath {
    long long ps = XHS778GetPrivacySection(self);
    if (ps >= 0) {
        if (indexPath.section == ps + 1) {
            NSIndexPath *probe = [NSIndexPath indexPathForRow:0 inSection:ps];
            return %orig(tableView, probe);
        }
        if (indexPath.section > ps + 1) {
            NSIndexPath *origIp = [NSIndexPath indexPathForRow:indexPath.row inSection:indexPath.section - 1];
            return %orig(tableView, origIp);
        }
    }
    return %orig;
}

%new
- (UITableViewCell *)xhs778_makeEntryCell {
    static NSString *cellId = @"XHS778EntryCell";
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellId];
    }
    for (UIView *v in cell.contentView.subviews) {
        if (v.tag == 7780001 || v.tag == 7780002) [v removeFromSuperview];
    }

    // 不主动设置 backgroundColor，让它自动跟随系统的浅/深色 grouped style
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.text = nil;

    UIImageView *icon = [[UIImageView alloc] init];
    icon.tag = 7780001;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = [UIColor labelColor]; // 黑白图标，自动适配深浅色
    if (@available(iOS 13.0, *)) {
        icon.image = [UIImage systemImageNamed:@"face.smiling"];
    }
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:icon];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.tag = 7780002;
    titleLabel.text = @"XHS778";
    titleLabel.font = [UIFont systemFontOfSize:16];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:titleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:18],
        [icon.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:22],
        [icon.heightAnchor constraintEqualToConstant:22],

        [titleLabel.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:14],
        [titleLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
    ]];

    return cell;
}

%new
- (void)xhs778_presentEntry {
    __weak typeof(self) ws = self;
    void (^presentSettings)(void) = ^{
        __strong typeof(ws) ss = ws;
        if (!ss) return;
        XHS778SettingsVC *vc = [[XHS778SettingsVC alloc] init];
        vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
        vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        [ss presentViewController:vc animated:YES completion:nil];
    };
    if (XHS778DisclaimerAccepted()) {
        presentSettings();
    } else {
        XHS778DisclaimerVC *dvc = [[XHS778DisclaimerVC alloc] init];
        dvc.modalPresentationStyle = UIModalPresentationOverFullScreen;
        dvc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        dvc.onAccept = ^{ presentSettings(); };
        [self presentViewController:dvc animated:YES completion:nil];
    }
}

%end


#pragma mark - Hook 长按评论菜单：在「添加表情」下方插入「保存表情」

static char kXHS778FeedbackAddIndexKey;
static char kXHS778FeedbackScannedKey;

@interface XYCommentFeedbackPanelController (XHS778)
- (void)xhs778_onSavePressed;
- (UITableViewCell *)xhs778_makeSaveCell;
@end

%hook XYCommentFeedbackPanelController

- (void)viewDidLoad {
    %orig;
    objc_setAssociatedObject(self, &kXHS778FeedbackAddIndexKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kXHS778FeedbackScannedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (long long)tableView:(UITableView *)tableView numberOfRowsInSection:(long long)section {
    long long original = %orig;
    if (!XHS778Enabled() || !XHS778CommentSaveEnabled()) return original;

    // 仅当原 panel 中已扫描到「添加表情」项（说明评论是表情包）时才插入
    NSIndexPath *addIp = objc_getAssociatedObject(self, &kXHS778FeedbackAddIndexKey);
    if (addIp && addIp.section == section) {
        return original + 1;
    }
    return original;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL active = XHS778Enabled() && XHS778CommentSaveEnabled();
    NSIndexPath *addIp = objc_getAssociatedObject(self, &kXHS778FeedbackAddIndexKey);

    if (active && addIp && addIp.section == indexPath.section) {
        if (indexPath.row == addIp.row + 1) {
            return [self xhs778_makeSaveCell];
        }
        if (indexPath.row > addIp.row + 1) {
            NSIndexPath *origIp = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
            return %orig(tableView, origIp);
        }
    }

    UITableViewCell *cell = %orig;

    // 扫描「添加表情」位置（出现该项即表示评论是表情包）
    NSNumber *scanned = objc_getAssociatedObject(self, &kXHS778FeedbackScannedKey);
    if (active && !scanned.boolValue && !addIp) {
        UILabel *l = XHS778FindLabel(cell.contentView);
        if (l.text.length && [l.text isEqualToString:@"添加表情"]) {
            objc_setAssociatedObject(self, &kXHS778FeedbackAddIndexKey, indexPath, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, &kXHS778FeedbackScannedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf && strongSelf.tableView) {
                    [strongSelf.tableView reloadData];
                }
            });
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL active = XHS778Enabled() && XHS778CommentSaveEnabled();
    NSIndexPath *addIp = objc_getAssociatedObject(self, &kXHS778FeedbackAddIndexKey);

    if (active && addIp && addIp.section == indexPath.section) {
        if (indexPath.row == addIp.row + 1) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            [self xhs778_onSavePressed];
            return;
        }
        if (indexPath.row > addIp.row + 1) {
            NSIndexPath *origIp = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
            %orig(tableView, origIp);
            return;
        }
    }
    %orig;
}

- (double)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL active = XHS778Enabled() && XHS778CommentSaveEnabled();
    NSIndexPath *addIp = objc_getAssociatedObject(self, &kXHS778FeedbackAddIndexKey);

    if (active && addIp && addIp.section == indexPath.section) {
        if (indexPath.row == addIp.row + 1) {
            NSIndexPath *origAdd = [NSIndexPath indexPathForRow:addIp.row inSection:addIp.section];
            return %orig(tableView, origAdd);
        }
        if (indexPath.row > addIp.row + 1) {
            NSIndexPath *origIp = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
            return %orig(tableView, origIp);
        }
    }
    return %orig;
}

- (double)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL active = XHS778Enabled() && XHS778CommentSaveEnabled();
    NSIndexPath *addIp = objc_getAssociatedObject(self, &kXHS778FeedbackAddIndexKey);

    if (active && addIp && addIp.section == indexPath.section) {
        if (indexPath.row == addIp.row + 1) {
            NSIndexPath *origAdd = [NSIndexPath indexPathForRow:addIp.row inSection:addIp.section];
            return %orig(tableView, origAdd);
        }
        if (indexPath.row > addIp.row + 1) {
            NSIndexPath *origIp = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
            return %orig(tableView, origIp);
        }
    }
    return %orig;
}

%new
- (UITableViewCell *)xhs778_makeSaveCell {
    static NSString *cellId = @"XHS778SaveCommentCell";
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellId];
    }
    for (UIView *v in cell.contentView.subviews) {
        if (v.tag == 7780101 || v.tag == 7780102) [v removeFromSuperview];
    }

    cell.backgroundColor = [UIColor clearColor];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.text = nil;

    UIImageView *icon = [[UIImageView alloc] init];
    icon.tag = 7780101;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = [UIColor labelColor];
    if (@available(iOS 13.0, *)) {
        icon.image = [UIImage systemImageNamed:@"square.and.arrow.down"];
    }
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:icon];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.tag = 7780102;
    titleLabel.text = @"保存表情";
    titleLabel.font = [UIFont systemFontOfSize:16];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:titleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:18],
        [icon.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:24],
        [icon.heightAnchor constraintEqualToConstant:24],

        [titleLabel.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:14],
        [titleLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
    ]];

    return cell;
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


#pragma mark - 表情详情页：MemePreviewPageController 在「添加表情」下方加同样胶囊「保存表情」按钮

static char kXHS778PreviewSaveButtonInjectedKey;
static const NSInteger kXHS778PreviewSaveButtonTag = 778303;

@interface XHS778PreviewBtnTarget : NSObject
+ (instancetype)sharedTarget;
- (void)onPreviewSavePressed:(UIButton *)sender;
@end

@implementation XHS778PreviewBtnTarget
+ (instancetype)sharedTarget {
    static XHS778PreviewBtnTarget *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [[self alloc] init]; });
    return t;
}
- (void)onPreviewSavePressed:(UIButton *)sender {
    // 从按钮一路向上找到 controller 的 view，递归找 emoji image view
    UIView *v = sender.superview;
    while (v && ![v.nextResponder isKindOfClass:[UIViewController class]]) v = v.superview;
    UIView *root = v ?: sender.superview;
    XYAnimatedImageView *iv = XHS778FindAnimatedImageView(root);
    if (iv) {
        XHS778SaveEmojiFromImageView(iv);
    } else {
        UIImageView *anyIv = nil;
        NSMutableArray *q = [NSMutableArray arrayWithObject:root];
        while (q.count > 0) {
            UIView *cur = q.firstObject;
            [q removeObjectAtIndex:0];
            if ([cur isKindOfClass:[UIImageView class]] && ((UIImageView *)cur).image) {
                anyIv = (UIImageView *)cur; break;
            }
            [q addObjectsFromArray:cur.subviews];
        }
        if (anyIv && anyIv.image) {
            XHS778SaveImageObject(anyIv.image);
        } else {
            XHS778ShowToast(@"未找到表情图片");
        }
    }
}
@end

// 递归查找 currentTitle 等于指定文字的 UIButton
static UIButton *XHS778FindButtonWithTitle(UIView *root, NSString *title) {
    if (!root) return nil;
    if ([root isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)root;
        if ([b.currentTitle isEqualToString:title]) return b;
    }
    for (UIView *sub in root.subviews) {
        UIButton *b = XHS778FindButtonWithTitle(sub, title);
        if (b) return b;
    }
    return nil;
}

static void XHS778AddPreviewSaveButton(UIViewController *vc) {
    if (!XHS778Enabled() || !XHS778PreviewSaveEnabled()) return;
    if (!vc || !vc.viewLoaded) return;
    UIView *root = vc.view;
    if (!root || root.bounds.size.width <= 0) return;
    if ([root viewWithTag:kXHS778PreviewSaveButtonTag]) return;

    // 找原「添加表情」胶囊按钮（红色）
    UIButton *addBtn = XHS778FindButtonWithTitle(root, @"添加表情");
    if (!addBtn) return;
    UIView *parent = addBtn.superview;
    if (!parent) return;

    // 复制完全相同的尺寸/颜色/字体，仅文字与回调不同
    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    saveBtn.tag = kXHS778PreviewSaveButtonTag;
    CGRect af = addBtn.frame;
    saveBtn.frame = CGRectMake(af.origin.x, CGRectGetMaxY(af) + 12, af.size.width, af.size.height);
    saveBtn.autoresizingMask = addBtn.autoresizingMask;
    saveBtn.backgroundColor = addBtn.backgroundColor ?: [UIColor systemRedColor];
    saveBtn.layer.cornerRadius = (addBtn.layer.cornerRadius > 0) ? addBtn.layer.cornerRadius : (af.size.height / 2.0);
    saveBtn.layer.masksToBounds = YES;
    [saveBtn setTitle:@"保存表情" forState:UIControlStateNormal];
    UIColor *textColor = [addBtn titleColorForState:UIControlStateNormal] ?: [UIColor whiteColor];
    [saveBtn setTitleColor:textColor forState:UIControlStateNormal];
    saveBtn.titleLabel.font = addBtn.titleLabel.font ?: [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [saveBtn addTarget:[XHS778PreviewBtnTarget sharedTarget]
                action:@selector(onPreviewSavePressed:)
      forControlEvents:UIControlEventTouchUpInside];
    [parent addSubview:saveBtn];

    objc_setAssociatedObject(vc, &kXHS778PreviewSaveButtonInjectedKey, saveBtn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}


#pragma mark - Hook UIButton：识别长按表情菜单中的「删除表情」/「添加到表情」按钮，旁加下载图标

static char kXHS778MenuDownloadButtonInjectedKey;
static const NSInteger kXHS778MenuDownloadButtonTag = 778201;

%hook UIButton

- (void)setTitle:(NSString *)title forState:(UIControlState)state {
    %orig;
    if (state != UIControlStateNormal) return;
    if (!XHS778Enabled() || !XHS778SenderMenuSaveEnabled()) return;
    if (!title.length) return;
    if (![title isEqualToString:@"删除表情"] && ![title isEqualToString:@"添加到表情"]) return;

    UIButton *btn = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *container = btn.superview;
        if (!container) return;
        if ([container viewWithTag:kXHS778MenuDownloadButtonTag]) return;

        // 不再修改原按钮 frame；在 container 右上角放一个圆形小按钮（28pt），不遮挡文字与下方箭头
        CGFloat size = 28;
        CGFloat margin = 6;
        UIButton *dlBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        dlBtn.tag = kXHS778MenuDownloadButtonTag;
        CGFloat cw = container.bounds.size.width;
        if (cw < size + margin * 2) cw = size + margin * 2;
        dlBtn.frame = CGRectMake(cw - size - margin, margin, size, size);
        dlBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
        dlBtn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.62];
        dlBtn.layer.cornerRadius = size / 2.0;
        dlBtn.layer.masksToBounds = YES;
        dlBtn.tintColor = [UIColor whiteColor];
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
            UIImage *img = [UIImage systemImageNamed:@"arrow.down.to.line" withConfiguration:cfg];
            [dlBtn setImage:img forState:UIControlStateNormal];
        }
        [dlBtn addTarget:btn action:@selector(xhs778_menuDownloadTapped:) forControlEvents:UIControlEventTouchUpInside];
        [container addSubview:dlBtn];
    });
}

%new
- (void)xhs778_menuDownloadTapped:(UIButton *)sender {
    UIButton *originalBtn = self;
    UIView *container = originalBtn.superview;
    if (!container) {
        XHS778ShowToast(@"未找到表情图片");
        return;
    }
    XYAnimatedImageView *iv = XHS778FindAnimatedImageView(container);
    if (iv) {
        XHS778SaveEmojiFromImageView(iv);
        return;
    }
    UIImageView *anyIv = nil;
    NSMutableArray *q = [NSMutableArray arrayWithObject:container];
    while (q.count > 0) {
        UIView *cur = q.firstObject;
        [q removeObjectAtIndex:0];
        if ([cur isKindOfClass:[UIImageView class]] && ((UIImageView *)cur).image) {
            anyIv = (UIImageView *)cur;
            break;
        }
        [q addObjectsFromArray:cur.subviews];
    }
    if (anyIv) {
        XHS778SaveImageObject(anyIv.image);
    } else {
        XHS778ShowToast(@"未找到表情图片");
    }
}

%end
