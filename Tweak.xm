// Tweak.xm - XHS778 小红书表情包保存助手
// Author: jijiang778
// 测试版本：XHS 9.28.1

#import "XHS778Headers.h"

#pragma mark - 设置存储 Key（所有开关默认关）

static NSString * const kXHS778EnabledKey            = @"XHS778_Enabled";
static NSString * const kXHS778CommentSaveEnabledKey = @"XHS778_CommentSaveEnabled";
static NSString * const kXHS778SenderMenuSaveKey     = @"XHS778_SenderMenuSaveEnabled";
static NSString * const kXHS778DisclaimerAcceptedKey = @"XHS778_DisclaimerAccepted";

static BOOL XHS778Enabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kXHS778EnabledKey];
}
static BOOL XHS778CommentSaveEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kXHS778CommentSaveEnabledKey];
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
    // 强制本 VC 跟随系统真实深浅色（不被宿主 App 的 overrideUserInterfaceStyle 影响）
    if (@available(iOS 13.0, *)) {
        UIUserInterfaceStyle realStyle = [UIScreen mainScreen].traitCollection.userInterfaceStyle;
        if (realStyle != UIUserInterfaceStyleUnspecified) {
            self.overrideUserInterfaceStyle = realStyle;
        }
    }
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
    // fallback 底色：如果 blur 在某些场景失效，至少不会透出黑色蒙层
    if (@available(iOS 13.0, *)) {
        self.card.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
                return [UIColor colorWithRed:0.188 green:0.188 blue:0.204 alpha:1.0];
            }
            return [UIColor whiteColor];
        }];
    } else {
        self.card.backgroundColor = [UIColor whiteColor];
    }
    [self.view addSubview:self.card];

    UIBlurEffectStyle blurStyle = UIBlurEffectStyleLight;
    if (@available(iOS 13.0, *)) {
        blurStyle = UIBlurEffectStyleSystemThinMaterial;
    }
    self.blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:blurStyle]];
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


#pragma mark - 设置 VC（重写版）

static char kXHS778SettingsTopBarHeightKey;

#pragma mark - 缓存大小计算与清理

static NSString *XHS778FormatSize(unsigned long long bytes) {
    if (bytes < 1024ULL) return [NSString stringWithFormat:@"%llu B", bytes];
    double kb = bytes / 1024.0;
    if (kb < 1024.0) return [NSString stringWithFormat:@"%.1f KB", kb];
    double mb = kb / 1024.0;
    if (mb < 1024.0) return [NSString stringWithFormat:@"%.1f MB", mb];
    double gb = mb / 1024.0;
    return [NSString stringWithFormat:@"%.2f GB", gb];
}

static NSArray<NSString *> *XHS778CacheDirs(void) {
    NSString *home = NSHomeDirectory();
    return @[
        [home stringByAppendingPathComponent:@"Library/Caches"],
        [home stringByAppendingPathComponent:@"tmp"],
    ];
}

static unsigned long long XHS778CalcCacheSize(void) {
    unsigned long long total = 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in XHS778CacheDirs()) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;
        NSDirectoryEnumerator *e = [fm enumeratorAtPath:dir];
        NSString *sub;
        while ((sub = [e nextObject])) {
            NSString *full = [dir stringByAppendingPathComponent:sub];
            NSDictionary *attr = [fm attributesOfItemAtPath:full error:nil];
            if ([attr[NSFileType] isEqualToString:NSFileTypeRegular]) {
                total += [attr[NSFileSize] unsignedLongLongValue];
            }
        }
    }
    return total;
}

static void XHS778ClearCache(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in XHS778CacheDirs()) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *item in items) {
            NSString *full = [dir stringByAppendingPathComponent:item];
            [fm removeItemAtPath:full error:nil];
        }
    }
}

@interface XHS778SettingsVC : UIViewController <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UISwitch *masterSwitch;
@property (nonatomic, strong) UISwitch *commentSwitch;
@property (nonatomic, strong) UISwitch *senderSwitch;
@property (nonatomic, strong) UIView *commentRow;
@property (nonatomic, strong) UIView *senderRow;
@property (nonatomic, strong) UIView *cacheRow;
@property (nonatomic, strong) UILabel *cacheDetailLabel;
@property (nonatomic, assign) BOOL cacheCleaning;
@end

@implementation XHS778SettingsVC

- (void)viewDidLoad {
    [super viewDidLoad];
    // 强制本 VC 跟随系统真实深浅色（不被宿主 App 的 overrideUserInterfaceStyle 影响）
    if (@available(iOS 13.0, *)) {
        UIUserInterfaceStyle realStyle = [UIScreen mainScreen].traitCollection.userInterfaceStyle;
        if (realStyle != UIUserInterfaceStyleUnspecified) {
            self.overrideUserInterfaceStyle = realStyle;
        }
    }
    if (@available(iOS 13.0, *)) {
        self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    } else {
        self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];
    }
    [self _buildNavigationBar];
    [self _buildContent];

    // 左缘右滑返回手势（与系统导航返回手势一致）
    UIScreenEdgePanGestureRecognizer *edgePan = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(_onEdgePan:)];
    edgePan.edges = UIRectEdgeLeft;
    edgePan.delegate = self;
    [self.view addGestureRecognizer:edgePan];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self _refreshCacheSize];
}

- (BOOL)prefersStatusBarHidden {
    return NO;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleDefault;
}

- (void)_buildNavigationBar {
    CGFloat w = self.view.bounds.size.width;
    CGFloat statusH = 0;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = (UIWindowScene *)[[[UIApplication sharedApplication] connectedScenes] anyObject];
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            statusH = scene.statusBarManager.statusBarFrame.size.height;
        }
    }
    if (statusH <= 0) statusH = 20;
    CGFloat barH = 44;

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, statusH + barH)];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    if (@available(iOS 13.0, *)) {
        bar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    } else {
        bar.backgroundColor = [UIColor whiteColor];
    }
    [self.view addSubview:bar];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(8, statusH + 4, 36, 36);
    close.tintColor = [UIColor labelColor];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
        [close setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:cfg] forState:UIControlStateNormal];
    } else {
        [close setTitle:@"✕" forState:UIControlStateNormal];
    }
    [close addTarget:self action:@selector(_onClose) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:close];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(56, statusH, w - 112, barH)];
    title.text = @"XHS778";
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textColor = [UIColor labelColor];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [bar addSubview:title];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, statusH + barH - 0.5, w, 0.5)];
    line.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    line.backgroundColor = [[UIColor separatorColor] colorWithAlphaComponent:0.35];
    [bar addSubview:line];

    objc_setAssociatedObject(self, &kXHS778SettingsTopBarHeightKey, @(statusH + barH), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)_buildContent {
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat topH = [objc_getAssociatedObject(self, &kXHS778SettingsTopBarHeightKey) doubleValue];
    if (topH <= 0) topH = 64;

    self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(0, topH, w, h - topH)];
    self.scrollView.backgroundColor = [UIColor clearColor];
    self.scrollView.showsVerticalScrollIndicator = YES;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.scrollView];

    CGFloat y = 16.0;

    [self _addSectionTitle:@"总开关" y:&y width:w];
    NSArray *masterRows = @[
        @{@"title": @"启用 XHS778", @"detail": @"关闭后所有保存功能停用", @"tag": @1}
    ];
    [self _addRows:masterRows y:&y width:w];

    y += 24;
    [self _addSectionTitle:@"保存功能" y:&y width:w];
    NSArray *saveRows = @[
        @{@"title": @"长按评论保存", @"detail": @"在评论菜单中加入「保存表情」", @"tag": @2},
        @{@"title": @"发送菜单保存", @"detail": @"长按表情时显示「删除 / 保存」", @"tag": @4}
    ];
    [self _addRows:saveRows y:&y width:w];

    y += 24;
    [self _addSectionTitle:@"缓存管理" y:&y width:w];
    NSArray *cacheRows = @[
        @{@"title": @"清理缓存", @"icon": @"trash", @"detail": @"计算中…", @"action": @"cache"}
    ];
    [self _addRows:cacheRows y:&y width:w];

    y += 24;
    [self _addSectionTitle:@"关于" y:&y width:w];
    NSArray *aboutRows = @[
        @{@"title": @"阅读使用须知", @"icon": @"doc.text", @"action": @"disclaimer"},
        @{@"title": @"TG", @"icon": @"paperplane", @"detail": @"@JiJiang_778", @"action": @"telegram"},
        @{@"title": @"版本", @"icon": @"info.circle", @"detail": @"1.0-1"}
    ];
    [self _addRows:aboutRows y:&y width:w];

    y += 12;
    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(24, y, w - 48, 36)];
    tip.text = @"仅供学习交流，请尊重原作者版权";
    tip.textAlignment = NSTextAlignmentCenter;
    tip.font = [UIFont systemFontOfSize:11];
    tip.textColor = [UIColor tertiaryLabelColor];
    [self.scrollView addSubview:tip];

    self.scrollView.contentSize = CGSizeMake(w, y + 60);
    [self _syncRows];
}

- (void)_addSectionTitle:(NSString *)title y:(CGFloat *)y width:(CGFloat)width {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(32, *y, width - 64, 18)];
    label.text = title;
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = [UIColor secondaryLabelColor];
    [self.scrollView addSubview:label];
    *y += 26;
}

- (void)_addRows:(NSArray<NSDictionary *> *)rows y:(CGFloat *)y width:(CGFloat)width {
    CGFloat x = 18.0;
    CGFloat sectionW = width - x * 2.0;

    NSMutableArray<UIView *> *createdRows = [NSMutableArray array];
    CGFloat totalH = 0;

    for (NSInteger i = 0; i < rows.count; i++) {
        NSDictionary *rowInfo = rows[i];
        BOOL hasDetail = [rowInfo[@"detail"] length] > 0;
        BOOL isSwitch = rowInfo[@"tag"] != nil;
        NSString *iconName = rowInfo[@"icon"];
        BOOL hasIcon = iconName.length > 0;
        NSString *action = rowInfo[@"action"];
        CGFloat rowH = (isSwitch && hasDetail) ? 64 : 50;

        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, totalH, sectionW, rowH)];
        [createdRows addObject:row];
        totalH += rowH;

        // 左侧图标（SF Symbol 黑白）
        CGFloat textLeft = 16;
        if (hasIcon) {
            UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectMake(16, (rowH - 22) / 2.0, 22, 22)];
            iconView.contentMode = UIViewContentModeScaleAspectFit;
            iconView.tintColor = [UIColor labelColor];
            if (@available(iOS 13.0, *)) {
                UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightRegular];
                iconView.image = [UIImage systemImageNamed:iconName withConfiguration:cfg];
            }
            [row addSubview:iconView];
            textLeft = 16 + 22 + 12;
        }

        UILabel *title = [[UILabel alloc] init];
        title.text = rowInfo[@"title"];
        title.font = [UIFont systemFontOfSize:16];
        title.textColor = [UIColor labelColor];
        [row addSubview:title];

        if (hasDetail && isSwitch) {
            title.frame = CGRectMake(textLeft, 8, sectionW - textLeft - 68, 22);
            UILabel *detail = [[UILabel alloc] initWithFrame:CGRectMake(textLeft, 32, sectionW - textLeft - 68, 22)];
            detail.text = rowInfo[@"detail"];
            detail.font = [UIFont systemFontOfSize:12];
            detail.textColor = [UIColor secondaryLabelColor];
            [row addSubview:detail];
        } else {
            title.frame = CGRectMake(textLeft, 0, sectionW - textLeft - 68, rowH);
        }

        if (isSwitch) {
            NSInteger tagNum = [rowInfo[@"tag"] integerValue];
            UISwitch *sw = [[UISwitch alloc] init];
            sw.tag = tagNum;
            sw.onTintColor = [UIColor systemGreenColor];
            sw.on = [[NSUserDefaults standardUserDefaults] boolForKey:[self _keyForTag:sw.tag]];
            CGRect sf = sw.frame;
            sw.frame = CGRectMake(sectionW - sf.size.width - 14, (rowH - sf.size.height) / 2.0, sf.size.width, sf.size.height);
            [sw addTarget:self action:@selector(_onSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [row addSubview:sw];
            if (sw.tag == 1) self.masterSwitch = sw;
            if (sw.tag == 2) { self.commentSwitch = sw; self.commentRow = row; }
            if (sw.tag == 4) { self.senderSwitch = sw; self.senderRow = row; }
        } else {
            BOOL clickable = [action isEqualToString:@"disclaimer"]
                          || [action isEqualToString:@"telegram"]
                          || [action isEqualToString:@"cache"];
            CGFloat detailRight = 16;

            if (clickable) {
                UIImageView *chevron = [[UIImageView alloc] initWithFrame:CGRectMake(sectionW - 26, (rowH - 14) / 2.0, 8, 14)];
                chevron.tintColor = [UIColor tertiaryLabelColor];
                chevron.contentMode = UIViewContentModeScaleAspectFit;
                if (@available(iOS 13.0, *)) {
                    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
                    chevron.image = [UIImage systemImageNamed:@"chevron.right" withConfiguration:cfg];
                }
                [row addSubview:chevron];
                detailRight = 34;
            }

            UILabel *detailLabel = nil;
            if (hasDetail) {
                CGFloat rightEdge = clickable ? (sectionW - detailRight) : (sectionW - 16);
                CGFloat labelW = 220;
                CGFloat labelX = MAX(textLeft + 8, rightEdge - labelW);
                if (rightEdge - labelX < 60) labelX = rightEdge - 60;
                detailLabel = [[UILabel alloc] initWithFrame:CGRectMake(labelX, 0, rightEdge - labelX, rowH)];
                detailLabel.text = rowInfo[@"detail"];
                detailLabel.textAlignment = NSTextAlignmentRight;
                detailLabel.font = [UIFont systemFontOfSize:14];
                detailLabel.textColor = [UIColor secondaryLabelColor];
                detailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
                [row addSubview:detailLabel];
            }

            if (clickable) {
                UIControl *control = [[UIControl alloc] initWithFrame:row.bounds];
                control.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                if ([action isEqualToString:@"telegram"]) {
                    [control addTarget:self action:@selector(_openTelegram) forControlEvents:UIControlEventTouchUpInside];
                } else if ([action isEqualToString:@"cache"]) {
                    [control addTarget:self action:@selector(_onCleanCache) forControlEvents:UIControlEventTouchUpInside];
                    self.cacheRow = row;
                    self.cacheDetailLabel = detailLabel;
                } else {
                    [control addTarget:self action:@selector(_showDisclaimer) forControlEvents:UIControlEventTouchUpInside];
                }
                [row addSubview:control];
            }
        }
    }

    UIView *section = [[UIView alloc] initWithFrame:CGRectMake(x, *y, sectionW, totalH)];
    section.layer.cornerRadius = 12;
    section.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *)) {
        section.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    } else {
        section.backgroundColor = [UIColor whiteColor];
    }
    [self.scrollView addSubview:section];

    for (NSInteger i = 0; i < createdRows.count; i++) {
        UIView *row = createdRows[i];
        [section addSubview:row];
        if (i < createdRows.count - 1) {
            UIView *line = [[UIView alloc] initWithFrame:CGRectMake(16, CGRectGetMaxY(row.frame) - 0.5, row.bounds.size.width - 16, 0.5)];
            line.backgroundColor = [[UIColor separatorColor] colorWithAlphaComponent:0.35];
            [section addSubview:line];
        }
    }
    *y += totalH;
}

- (NSString *)_keyForTag:(NSInteger)tag {
    if (tag == 1) return kXHS778EnabledKey;
    if (tag == 2) return kXHS778CommentSaveEnabledKey;
    if (tag == 4) return kXHS778SenderMenuSaveKey;
    return kXHS778EnabledKey;
}

- (void)_syncRows {
    BOOL master = XHS778Enabled();
    self.commentSwitch.enabled = master;
    self.senderSwitch.enabled = master;
    self.commentRow.alpha = master ? 1.0 : 0.45;
    self.senderRow.alpha = master ? 1.0 : 0.45;
}

- (void)_onSwitchChanged:(UISwitch *)sender {
    NSString *key = [self _keyForTag:sender.tag];
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (sender.tag == 1) [self _syncRows];
}

- (void)_showDisclaimer {
    XHS778DisclaimerVC *vc = [[XHS778DisclaimerVC alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)_openTelegram {
    NSURL *tgApp = [NSURL URLWithString:@"tg://resolve?domain=JiJiang_778"];
    NSURL *tgWeb = [NSURL URLWithString:@"https://t.me/JiJiang_778"];
    UIApplication *app = [UIApplication sharedApplication];
    if ([app canOpenURL:tgApp]) {
        [app openURL:tgApp options:@{} completionHandler:nil];
    } else {
        [app openURL:tgWeb options:@{} completionHandler:nil];
    }
}

#pragma mark - 缓存管理

- (void)_refreshCacheSize {
    if (self.cacheCleaning) return;
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        unsigned long long bytes = XHS778CalcCacheSize();
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) ss = ws;
            if (!ss) return;
            ss.cacheDetailLabel.text = XHS778FormatSize(bytes);
        });
    });
}

- (void)_onCleanCache {
    if (self.cacheCleaning) return;
    NSString *detail = self.cacheDetailLabel.text ?: @"";
    NSString *msg = [NSString stringWithFormat:
        @"当前缓存大小：%@\n\n"
        @"提示：小红书官方「设置 → 存储空间 → 缓存」也可清理缓存。\n"
        @"插件清理范围为 Library/Caches 与 tmp，通常比官方清理得更彻底；\n"
        @"如无必要可使用官方自带的清理缓存。\n\n"
        @"是否确认用插件清理？", detail];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清理缓存"
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"确定清理" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull act) {
        __strong typeof(ws) ss = ws;
        if (!ss) return;
        ss.cacheCleaning = YES;
        ss.cacheDetailLabel.text = @"清理中…";
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            XHS778ClearCache();
            unsigned long long after = XHS778CalcCacheSize();
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(ws) ss2 = ws;
                if (!ss2) return;
                ss2.cacheCleaning = NO;
                ss2.cacheDetailLabel.text = XHS778FormatSize(after);
                UIAlertController *done = [UIAlertController alertControllerWithTitle:@"清理完成"
                                                                              message:[NSString stringWithFormat:@"剩余缓存：%@", XHS778FormatSize(after)]
                                                                       preferredStyle:UIAlertControllerStyleAlert];
                [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [ss2 presentViewController:done animated:YES completion:nil];
            });
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 左缘右滑返回（交互式 dismiss）

- (void)_onEdgePan:(UIScreenEdgePanGestureRecognizer *)g {
    CGFloat w = self.view.bounds.size.width;
    CGPoint t = [g translationInView:self.view];
    CGFloat tx = MAX(0, t.x);
    CGFloat progress = (w > 0) ? (tx / w) : 0;

    switch (g.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged: {
            self.view.transform = CGAffineTransformMakeTranslation(tx, 0);
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            CGFloat vx = [g velocityInView:self.view].x;
            BOOL shouldDismiss = (progress > 0.35) || (vx > 600);
            if (shouldDismiss) {
                [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                    self.view.transform = CGAffineTransformMakeTranslation(w, 0);
                } completion:^(BOOL finished) {
                    [self dismissViewControllerAnimated:NO completion:nil];
                }];
            } else {
                [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                    self.view.transform = CGAffineTransformIdentity;
                } completion:nil];
            }
            break;
        }
        default:
            break;
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)_onClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - Hook 评论 view (Swift class)：记录最近一次长按的评论

static void XHS778RecordCommentTouches(UIView *commentView) {
    if (!commentView) return;
    gXHS778LastLongPressedCommentView = commentView;
    XYAnimatedImageView *iv = XHS778FindAnimatedImageView(commentView);
    gXHS778LastLongPressedEmojiView = iv;
}

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

    }
}


#pragma mark - Hook 设置主页：tableHeaderView 注入入口（最小侵入，绝不改 dataSource）

static const NSInteger kXHS778SettingsHeaderTag = 778900;

@interface XYPHSettingViewController (XHS778)
- (void)xhs778_setupTableHeader;
- (void)xhs778_presentEntry;
@end

%hook XYPHSettingViewController

- (void)viewDidLayoutSubviews {
    %orig;
    [self xhs778_setupTableHeader];
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [self xhs778_setupTableHeader];
}

%new
- (void)xhs778_setupTableHeader {
    UITableView *tv = self.tableView;
    if (!tv) return;
    CGFloat width = tv.bounds.size.width;
    if (width <= 0) return;
    UIView *existing = tv.tableHeaderView;
    if (existing.tag == kXHS778SettingsHeaderTag &&
        fabs(existing.bounds.size.width - width) < 0.5) {
        return;
    }

    // FLEX 抓数据：官方 cell 整体 frame = (0, 0, 382, 52)，占满 tableView 宽度（tableView 自身已做边距）
    // 我们要让 XHS778 cell 严格匹配：x=0, width=tableView.width, h=52
    CGFloat cellH = 52.0;
    CGFloat cellW = width;
    CGFloat headerHeight = 22 + cellH + 14;  // section header + cell + bottom gap
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, headerHeight)];
    header.tag = kXHS778SettingsHeaderTag;
    header.backgroundColor = [UIColor clearColor];

    // section 标题距 tableView 左缘 16pt（与官方组标题对齐）
    UILabel *sectionTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, width - 32, 22)];
    sectionTitle.text = @"XHS778";
    sectionTitle.font = [UIFont systemFontOfSize:13];
    sectionTitle.textColor = [UIColor secondaryLabelColor];
    [header addSubview:sectionTitle];

    UIControl *cell = [[UIControl alloc] initWithFrame:CGRectMake(0, 22, cellW, cellH)];
    cell.layer.cornerRadius = 10;
    cell.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *)) {
        cell.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
                // FLEX 抓小红书设置页官方 cell 深色：RGB(0.098, 0.098, 0.122) alpha 1.0
                return [UIColor colorWithRed:0.098 green:0.098 blue:0.122 alpha:1.0];
            }
            return [UIColor whiteColor];
        }];
    } else {
        cell.backgroundColor = [UIColor whiteColor];
    }
    [cell addTarget:self action:@selector(xhs778_presentEntry) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:cell];

    // icon 距 cell 左缘 16pt（与官方 cell 内 icon 一致）
    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(16, (cellH - 24) / 2.0, 24, 24)];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = [UIColor labelColor];
    icon.userInteractionEnabled = NO;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
        icon.image = [UIImage systemImageNamed:@"face.smiling" withConfiguration:cfg];
    }
    [cell addSubview:icon];

    UILabel *titleL = [[UILabel alloc] initWithFrame:CGRectMake(54, 0, cellW - 140, cellH)];
    titleL.text = @"XHS778";
    titleL.font = [UIFont systemFontOfSize:16];
    titleL.textColor = [UIColor labelColor];
    titleL.userInteractionEnabled = NO;
    [cell addSubview:titleL];

    UILabel *version = [[UILabel alloc] initWithFrame:CGRectMake(cellW - 96, 0, 60, cellH)];
    version.text = @"1.0-1";
    version.textAlignment = NSTextAlignmentRight;
    version.font = [UIFont systemFontOfSize:14];
    version.textColor = [UIColor secondaryLabelColor];
    version.userInteractionEnabled = NO;
    [cell addSubview:version];

    UIImageView *arrow = [[UIImageView alloc] initWithFrame:CGRectMake(cellW - 26, (cellH - 14) / 2.0, 8, 14)];
    arrow.tintColor = [UIColor tertiaryLabelColor];
    arrow.contentMode = UIViewContentModeScaleAspectFit;
    arrow.userInteractionEnabled = NO;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
        arrow.image = [UIImage systemImageNamed:@"chevron.right" withConfiguration:cfg];
    }
    [cell addSubview:arrow];

    tv.tableHeaderView = header;
}

%new
- (void)xhs778_presentEntry {
    __weak typeof(self) ws = self;
    void (^presentSettings)(void) = ^{
        __strong typeof(ws) ss = ws;
        if (!ss) return;
        XHS778SettingsVC *vc = [[XHS778SettingsVC alloc] init];
        // OverFullScreen 保留底层（小红书设置页）在视图树中，右滑返回时能直接露出官方设置界面
        vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
        vc.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
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


#pragma mark - Hook 长按评论菜单：在「回复」上方插入「保存表情」

// saveCell 插入位置：在「回复」cell 上方（即占用「回复」原本的 indexPath，原「回复」及之后的 row 全部 +1）
static char kXHS778FeedbackReplyIndexKey;
static char kXHS778FeedbackScannedKey;

@interface XYCommentFeedbackPanelController (XHS778)
- (void)xhs778_onSavePressed;
- (UITableViewCell *)xhs778_makeSaveCell;
@end

%hook XYCommentFeedbackPanelController

- (void)viewDidLoad {
    %orig;
    objc_setAssociatedObject(self, &kXHS778FeedbackReplyIndexKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kXHS778FeedbackScannedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (long long)tableView:(UITableView *)tableView numberOfRowsInSection:(long long)section {
    long long original = %orig;
    if (!XHS778Enabled() || !XHS778CommentSaveEnabled()) return original;
    NSIndexPath *replyIp = objc_getAssociatedObject(self, &kXHS778FeedbackReplyIndexKey);
    if (replyIp && replyIp.section == section) {
        return original + 1;
    }
    return original;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL active = XHS778Enabled() && XHS778CommentSaveEnabled();
    NSIndexPath *replyIp = objc_getAssociatedObject(self, &kXHS778FeedbackReplyIndexKey);

    if (active && replyIp && replyIp.section == indexPath.section) {
        if (indexPath.row == replyIp.row) {
            return [self xhs778_makeSaveCell];
        }
        if (indexPath.row > replyIp.row) {
            NSIndexPath *origIp = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
            return %orig(tableView, origIp);
        }
    }

    UITableViewCell *cell = %orig;

    NSNumber *scanned = objc_getAssociatedObject(self, &kXHS778FeedbackScannedKey);
    if (active && !scanned.boolValue && !replyIp) {
        UILabel *l = XHS778FindLabel(cell.contentView);
        if (l.text.length && [l.text isEqualToString:@"回复"]) {
            objc_setAssociatedObject(self, &kXHS778FeedbackReplyIndexKey, indexPath, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, &kXHS778FeedbackScannedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    BOOL active = XHS778Enabled() && XHS778CommentSaveEnabled();
    NSIndexPath *replyIp = objc_getAssociatedObject(self, &kXHS778FeedbackReplyIndexKey);

    if (active && replyIp && replyIp.section == indexPath.section) {
        if (indexPath.row == replyIp.row) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            [self xhs778_onSavePressed];
            return;
        }
        if (indexPath.row > replyIp.row) {
            NSIndexPath *origIp = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
            %orig(tableView, origIp);
            return;
        }
    }
    %orig;
}

- (double)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL active = XHS778Enabled() && XHS778CommentSaveEnabled();
    NSIndexPath *replyIp = objc_getAssociatedObject(self, &kXHS778FeedbackReplyIndexKey);

    if (active && replyIp && replyIp.section == indexPath.section) {
        if (indexPath.row == replyIp.row) {
            // saveCell 独立岛：在「回复」cell 高度基础上增加上下各 12pt 间距
            NSIndexPath *origReply = [NSIndexPath indexPathForRow:replyIp.row inSection:replyIp.section];
            double replyH = %orig(tableView, origReply);
            if (replyH <= 0) replyH = 52;
            return replyH + 24;
        }
        if (indexPath.row > replyIp.row) {
            NSIndexPath *origIp = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
            return %orig(tableView, origIp);
        }
    }
    return %orig;
}

- (double)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL active = XHS778Enabled() && XHS778CommentSaveEnabled();
    NSIndexPath *replyIp = objc_getAssociatedObject(self, &kXHS778FeedbackReplyIndexKey);

    if (active && replyIp && replyIp.section == indexPath.section) {
        if (indexPath.row == replyIp.row) {
            NSIndexPath *origReply = [NSIndexPath indexPathForRow:replyIp.row inSection:replyIp.section];
            double replyH = %orig(tableView, origReply);
            if (replyH <= 0) replyH = 52;
            return replyH + 24;
        }
        if (indexPath.row > replyIp.row) {
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
    // 清理已存在的子视图（reuse 场景）
    for (UIView *v in cell.contentView.subviews) {
        if (v.tag == 7780100 || v.tag == 7780101 || v.tag == 7780102) [v removeFromSuperview];
    }

    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = nil;

    // 独立岛样式：wrapper 距 cell 上下各 12pt、左右各 16pt，带圆角，自成一组
    UIView *wrapper = [[UIView alloc] init];
    wrapper.tag = 7780100;
    wrapper.translatesAutoresizingMaskIntoConstraints = NO;
    wrapper.userInteractionEnabled = NO;
    wrapper.layer.cornerRadius = 10;
    wrapper.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *)) {
        wrapper.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
                // FLEX 抓官方「回复」cell：RGB(0.188, 0.188, 0.204) alpha 0.99
                return [UIColor colorWithRed:0.188 green:0.188 blue:0.204 alpha:0.99];
            }
            return [UIColor whiteColor];
        }];
    } else {
        wrapper.backgroundColor = [UIColor whiteColor];
    }
    [cell.contentView addSubview:wrapper];

    UIImageView *icon = [[UIImageView alloc] init];
    icon.tag = 7780101;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = [UIColor labelColor];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightRegular];
        icon.image = [UIImage systemImageNamed:@"square.and.arrow.down" withConfiguration:cfg];
    }
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [wrapper addSubview:icon];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.tag = 7780102;
    titleLabel.text = @"保存表情";
    titleLabel.font = [UIFont systemFontOfSize:15];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [wrapper addSubview:titleLabel];

    [NSLayoutConstraint activateConstraints:@[
        // wrapper 独立岛：距 cell 上下各 12pt、左右各 16pt
        [wrapper.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [wrapper.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [wrapper.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],
        [wrapper.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12],

        // icon 在 wrapper 内 leading 16，尺寸 22x22（与官方 cell 图标视觉一致）
        [icon.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor constant:16],
        [icon.centerYAnchor constraintEqualToAnchor:wrapper.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:22],
        [icon.heightAnchor constraintEqualToConstant:22],

        [titleLabel.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:14],
        [titleLabel.centerYAnchor constraintEqualToAnchor:wrapper.centerYAnchor],
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


#pragma mark - Hook UIButton：长按发送页表情，「删除/添加表情」按钮内右侧叠加圆形下载图标
// 完全不动原按钮 frame、不动 superview、不动预览图
// iOS 15/16/17/18 通用策略：多重触发（setTitle + layoutSubviews + didMoveToSuperview），幂等添加

static const NSInteger kXHS778MenuSaveButtonTag = 778201;

static BOOL XHS778IsSenderMenuTitle(NSString *t) {
    if (t.length == 0) return NO;
    // 快速首字符剪枝：删(0x5220) / 添(0x6DFB) / 收(0x6536，为了兼容某些版本"收藏表情"字样)
    unichar c = [t characterAtIndex:0];
    if (c != 0x5220 && c != 0x6DFB && c != 0x6536) return NO;
    return [t isEqualToString:@"删除表情"]
        || [t isEqualToString:@"添加到表情"]
        || [t isEqualToString:@"添加表情"]
        || [t isEqualToString:@"收藏表情"];
}

// Forward declaration：%new 方法在编译期不会生成 @interface 声明，需显式 category 声明供消息发送表达式识别
@interface UIButton (XHS778)
- (void)xhs778_tryAttachSaveButton;
- (void)xhs778_menuSavePressed:(UIButton *)sender;
@end

%hook UIButton

%new
- (void)xhs778_tryAttachSaveButton {
    if (!XHS778Enabled() || !XHS778SenderMenuSaveEnabled()) return;
    UIButton *btn = self;
    if (btn.tag == kXHS778MenuSaveButtonTag) return;

    NSString *title = [btn titleForState:UIControlStateNormal];
    if (!XHS778IsSenderMenuTitle(title)) {
        // iOS 15+ 若用 UIButtonConfiguration，titleForState 可能为空，再尝试 configuration.title
        if (@available(iOS 15.0, *)) {
            UIButtonConfiguration *cfg = btn.configuration;
            if (cfg && [cfg isKindOfClass:NSClassFromString(@"UIButtonConfiguration")]) {
                if (!XHS778IsSenderMenuTitle(cfg.title)) return;
            } else {
                return;
            }
        } else {
            return;
        }
    }

    UIView *container = btn.superview;
    if (!container) return;

    CGRect bf = btn.frame;
    if (bf.size.width < 20 || bf.size.height < 20) return;  // 尚未布局完成
    CGFloat iconSize = 24.0;
    CGFloat rightInset = 10.0;
    CGRect expected = CGRectMake(CGRectGetMaxX(bf) - iconSize - rightInset,
                                 bf.origin.y + (bf.size.height - iconSize) / 2.0,
                                 iconSize, iconSize);

    UIView *found = [container viewWithTag:kXHS778MenuSaveButtonTag];
    if ([found isKindOfClass:[UIButton class]]) {
        if (!CGRectEqualToRect(found.frame, expected)) {
            found.frame = expected;
        }
        [container bringSubviewToFront:found];
        return;
    }

    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    saveBtn.tag = kXHS778MenuSaveButtonTag;
    saveBtn.frame = expected;
    saveBtn.layer.cornerRadius = iconSize / 2.0;
    saveBtn.layer.masksToBounds = YES;
    saveBtn.tintColor = [UIColor labelColor];
    saveBtn.adjustsImageWhenHighlighted = YES;
    saveBtn.contentMode = UIViewContentModeScaleAspectFit;
    saveBtn.imageView.contentMode = UIViewContentModeScaleAspectFit;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightRegular];
        UIImage *img = [UIImage systemImageNamed:@"square.and.arrow.down" withConfiguration:cfg];
        [saveBtn setImage:img forState:UIControlStateNormal];
    }
    [saveBtn addTarget:btn action:@selector(xhs778_menuSavePressed:) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:saveBtn];
    [container bringSubviewToFront:saveBtn];
}

- (void)setTitle:(NSString *)title forState:(UIControlState)state {
    %orig;
    if (state != UIControlStateNormal) return;
    if (!XHS778IsSenderMenuTitle(title)) return;
    if (self.tag == kXHS778MenuSaveButtonTag) return;

    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [ws xhs778_tryAttachSaveButton]; });
    // 兜底：延迟再试一次，处理 setTitle 时 superview 尚未就绪 / layout 尚未完成的情况
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [ws xhs778_tryAttachSaveButton];
    });
}

- (void)layoutSubviews {
    %orig;
    // 快速剪枝：只处理 title 匹配的按钮，对其他 UIButton 无感
    if (self.tag == kXHS778MenuSaveButtonTag) return;
    NSString *t = [self titleForState:UIControlStateNormal];
    if (XHS778IsSenderMenuTitle(t)) {
        [self xhs778_tryAttachSaveButton];
        return;
    }
    // iOS 15+ UIButtonConfiguration 兜底
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *cfg = self.configuration;
        if (cfg && XHS778IsSenderMenuTitle(cfg.title)) {
            [self xhs778_tryAttachSaveButton];
        }
    }
}

- (void)didMoveToSuperview {
    %orig;
    if (self.tag == kXHS778MenuSaveButtonTag) return;
    NSString *t = [self titleForState:UIControlStateNormal];
    if (XHS778IsSenderMenuTitle(t)) {
        __weak typeof(self) ws = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [ws xhs778_tryAttachSaveButton]; });
    } else if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *cfg = self.configuration;
        if (cfg && XHS778IsSenderMenuTitle(cfg.title)) {
            __weak typeof(self) ws = self;
            dispatch_async(dispatch_get_main_queue(), ^{ [ws xhs778_tryAttachSaveButton]; });
        }
    }
}

%new
- (void)xhs778_menuSavePressed:(UIButton *)sender {
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
