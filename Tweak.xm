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


#pragma mark - 设置 VC（重写版）

@interface XHS778SettingsVC : UIViewController
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UISwitch *masterSwitch;
@property (nonatomic, strong) UISwitch *commentSwitch;
@property (nonatomic, strong) UISwitch *previewSwitch;
@property (nonatomic, strong) UISwitch *senderSwitch;
@property (nonatomic, strong) UIView *commentRow;
@property (nonatomic, strong) UIView *previewRow;
@property (nonatomic, strong) UIView *senderRow;
@end

@implementation XHS778SettingsVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.42];

    CGFloat sw = CGRectGetWidth([UIScreen mainScreen].bounds);
    CGFloat sh = CGRectGetHeight([UIScreen mainScreen].bounds);
    CGFloat cw = MIN(sw - 36.0, 420.0);
    CGFloat ch = MIN(sh - 112.0, 660.0);
    self.card = [[UIView alloc] initWithFrame:CGRectMake((sw - cw) / 2.0, (sh - ch) / 2.0, cw, ch)];
    self.card.layer.cornerRadius = 24.0;
    self.card.layer.masksToBounds = YES;
    [self.view addSubview:self.card];

    UIBlurEffect *effect;
    if (@available(iOS 13.0, *)) {
        effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    } else {
        effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
    }
    self.blurView = [[UIVisualEffectView alloc] initWithEffect:effect];
    self.blurView.frame = self.card.bounds;
    self.blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.card addSubview:self.blurView];

    [self _buildNavigationBar];
    [self _buildContent];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_onBackgroundTap:)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];
}

- (void)_buildNavigationBar {
    CGFloat w = self.card.bounds.size.width;
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 54)];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.blurView.contentView addSubview:bar];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(10, 9, 36, 36);
    close.tintColor = [UIColor labelColor];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
        [close setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:cfg] forState:UIControlStateNormal];
    } else {
        [close setTitle:@"✕" forState:UIControlStateNormal];
    }
    [close addTarget:self action:@selector(_onExitApp) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:close];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(64, 0, w - 128, 54)];
    title.text = @"XHS778";
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textColor = [UIColor labelColor];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [bar addSubview:title];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.frame = CGRectMake(w - 68, 9, 58, 36);
    done.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [done setTitle:@"完成" forState:UIControlStateNormal];
    [done setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [done addTarget:self action:@selector(_onClose) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:done];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 53.5, w, 0.5)];
    line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    line.backgroundColor = [[UIColor separatorColor] colorWithAlphaComponent:0.35];
    [bar addSubview:line];
}

- (void)_buildContent {
    CGFloat w = self.card.bounds.size.width;
    CGFloat h = self.card.bounds.size.height;
    self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 54, w, h - 54)];
    self.scrollView.backgroundColor = [UIColor clearColor];
    self.scrollView.showsVerticalScrollIndicator = NO;
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.blurView.contentView addSubview:self.scrollView];

    CGFloat y = 20.0;
    UIView *logo = [[UIView alloc] initWithFrame:CGRectMake((w - 64) / 2.0, y, 64, 64)];
    logo.layer.cornerRadius = 18;
    logo.layer.masksToBounds = YES;
    logo.backgroundColor = [UIColor systemRedColor];
    [self.scrollView addSubview:logo];

    UIImageView *logoIcon = [[UIImageView alloc] initWithFrame:logo.bounds];
    logoIcon.tintColor = [UIColor whiteColor];
    logoIcon.contentMode = UIViewContentModeCenter;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:34 weight:UIImageSymbolWeightSemibold];
        logoIcon.image = [UIImage systemImageNamed:@"face.smiling.fill" withConfiguration:cfg];
    }
    [logo addSubview:logoIcon];

    y += 76;
    UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(18, y, w - 36, 24)];
    name.text = @"小红书表情包保存助手";
    name.textAlignment = NSTextAlignmentCenter;
    name.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    name.textColor = [UIColor labelColor];
    [self.scrollView addSubview:name];

    y += 24;
    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(18, y, w - 36, 18)];
    sub.text = @"v1.0-1 · 适配 XHS 9.28.1";
    sub.textAlignment = NSTextAlignmentCenter;
    sub.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    sub.textColor = [UIColor secondaryLabelColor];
    [self.scrollView addSubview:sub];

    y += 34;
    [self _addSectionTitle:@"总开关" y:&y width:w];
    NSArray *masterRows = @[
        @{@"title": @"启用 XHS778", @"detail": @"关闭后所有保存功能停用", @"symbol": @"power", @"color": [UIColor systemRedColor], @"tag": @1}
    ];
    [self _addRows:masterRows y:&y width:w];

    y += 18;
    [self _addSectionTitle:@"保存功能" y:&y width:w];
    NSArray *saveRows = @[
        @{@"title": @"长按评论保存", @"detail": @"在评论菜单中加入保存表情", @"symbol": @"bubble.left.fill", @"color": [UIColor systemOrangeColor], @"tag": @2},
        @{@"title": @"详情页保存", @"detail": @"在添加表情按钮附近加入保存", @"symbol": @"photo.fill", @"color": [UIColor systemBlueColor], @"tag": @3},
        @{@"title": @"发送菜单保存", @"detail": @"长按表情时显示删除 / 保存", @"symbol": @"square.and.arrow.down.fill", @"color": [UIColor systemGreenColor], @"tag": @4}
    ];
    [self _addRows:saveRows y:&y width:w];

    y += 18;
    [self _addSectionTitle:@"关于" y:&y width:w];
    NSArray *aboutRows = @[
        @{@"title": @"重新阅读使用须知", @"detail": @"", @"symbol": @"doc.text.fill", @"color": [UIColor systemGrayColor], @"action": @"disclaimer"},
        @{@"title": @"版本", @"detail": @"1.0-1", @"symbol": @"info.circle.fill", @"color": [UIColor systemGrayColor], @"info": @YES}
    ];
    [self _addRows:aboutRows y:&y width:w];

    y += 18;
    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(24, y, w - 48, 36)];
    tip.text = @"仅供学习交流，请尊重原作者版权";
    tip.textAlignment = NSTextAlignmentCenter;
    tip.font = [UIFont systemFontOfSize:11];
    tip.textColor = [UIColor tertiaryLabelColor];
    [self.scrollView addSubview:tip];

    self.scrollView.contentSize = CGSizeMake(w, y + 52);
    [self _syncRows];
}

- (void)_addSectionTitle:(NSString *)title y:(CGFloat *)y width:(CGFloat)width {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(28, *y, width - 56, 22)];
    label.text = title;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textColor = [UIColor secondaryLabelColor];
    [self.scrollView addSubview:label];
    *y += 28;
}

- (void)_addRows:(NSArray<NSDictionary *> *)rows y:(CGFloat *)y width:(CGFloat)width {
    CGFloat rowH = 64.0;
    CGFloat x = 18.0;
    CGFloat sectionW = width - x * 2.0;
    UIView *section = [[UIView alloc] initWithFrame:CGRectMake(x, *y, sectionW, rowH * rows.count)];
    section.layer.cornerRadius = 16.0;
    section.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *)) {
        section.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    } else {
        section.backgroundColor = [UIColor secondarySystemBackgroundColor];
    }
    [self.scrollView addSubview:section];

    for (NSInteger i = 0; i < rows.count; i++) {
        NSDictionary *rowInfo = rows[i];
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, rowH * i, sectionW, rowH)];
        [section addSubview:row];

        UIView *iconBox = [[UIView alloc] initWithFrame:CGRectMake(14, 16, 32, 32)];
        iconBox.layer.cornerRadius = 8.0;
        iconBox.layer.masksToBounds = YES;
        iconBox.backgroundColor = rowInfo[@"color"] ?: [UIColor systemGrayColor];
        [row addSubview:iconBox];

        UIImageView *icon = [[UIImageView alloc] initWithFrame:iconBox.bounds];
        icon.tintColor = [UIColor whiteColor];
        icon.contentMode = UIViewContentModeCenter;
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
            icon.image = [UIImage systemImageNamed:rowInfo[@"symbol"] withConfiguration:cfg];
        }
        [iconBox addSubview:icon];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(58, 10, sectionW - 132, 22)];
        title.text = rowInfo[@"title"];
        title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        title.textColor = [UIColor labelColor];
        [row addSubview:title];

        NSString *detailText = rowInfo[@"detail"];
        if (detailText.length > 0) {
            UILabel *detail = [[UILabel alloc] initWithFrame:CGRectMake(58, 34, sectionW - 132, 18)];
            detail.text = detailText;
            detail.font = [UIFont systemFontOfSize:11];
            detail.textColor = [UIColor secondaryLabelColor];
            [row addSubview:detail];
        } else {
            title.frame = CGRectMake(58, 0, sectionW - 132, rowH);
        }

        NSNumber *tagNumber = rowInfo[@"tag"];
        if (tagNumber) {
            UISwitch *sw = [[UISwitch alloc] init];
            sw.tag = tagNumber.integerValue;
            sw.onTintColor = [UIColor systemRedColor];
            sw.on = [[NSUserDefaults standardUserDefaults] boolForKey:[self _keyForTag:sw.tag]];
            sw.transform = CGAffineTransformMakeScale(0.88, 0.88);
            CGRect sf = sw.frame;
            sw.frame = CGRectMake(sectionW - sf.size.width - 10, (rowH - sf.size.height) / 2.0, sf.size.width, sf.size.height);
            [sw addTarget:self action:@selector(_onSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [row addSubview:sw];
            if (sw.tag == 1) self.masterSwitch = sw;
            if (sw.tag == 2) { self.commentSwitch = sw; self.commentRow = row; }
            if (sw.tag == 3) { self.previewSwitch = sw; self.previewRow = row; }
            if (sw.tag == 4) { self.senderSwitch = sw; self.senderRow = row; }
        } else if ([rowInfo[@"action"] isEqualToString:@"disclaimer"]) {
            UIImageView *chevron = [[UIImageView alloc] initWithFrame:CGRectMake(sectionW - 30, 24, 8, 14)];
            chevron.tintColor = [UIColor tertiaryLabelColor];
            if (@available(iOS 13.0, *)) {
                UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
                chevron.image = [UIImage systemImageNamed:@"chevron.right" withConfiguration:cfg];
            }
            [row addSubview:chevron];

            UIControl *control = [[UIControl alloc] initWithFrame:row.bounds];
            [control addTarget:self action:@selector(_showDisclaimer) forControlEvents:UIControlEventTouchUpInside];
            [row addSubview:control];
        }

        if (i < rows.count - 1) {
            UIView *line = [[UIView alloc] initWithFrame:CGRectMake(58, rowH - 0.5, sectionW - 58, 0.5)];
            line.backgroundColor = [[UIColor separatorColor] colorWithAlphaComponent:0.35];
            [row addSubview:line];
        }
    }
    *y += rowH * rows.count;
}

- (NSString *)_keyForTag:(NSInteger)tag {
    if (tag == 1) return kXHS778EnabledKey;
    if (tag == 2) return kXHS778CommentSaveEnabledKey;
    if (tag == 3) return kXHS778PreviewSaveEnabledKey;
    if (tag == 4) return kXHS778SenderMenuSaveKey;
    return kXHS778EnabledKey;
}

- (void)_syncRows {
    BOOL master = XHS778Enabled();
    self.commentSwitch.enabled = master;
    self.previewSwitch.enabled = master;
    self.senderSwitch.enabled = master;
    self.commentRow.alpha = master ? 1.0 : 0.45;
    self.previewRow.alpha = master ? 1.0 : 0.45;
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

- (void)_onClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)_onBackgroundTap:(UITapGestureRecognizer *)gesture {
    CGPoint p = [gesture locationInView:self.view];
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

    CGFloat headerHeight = 116.0;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, headerHeight)];
    header.tag = kXHS778SettingsHeaderTag;
    header.backgroundColor = [UIColor clearColor];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(32, 14, width - 64, 22)];
    titleLabel.text = @"XHS778 表情保存助手";
    titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    titleLabel.textColor = [UIColor secondaryLabelColor];
    [header addSubview:titleLabel];

    UIControl *cell = [[UIControl alloc] initWithFrame:CGRectMake(18, 40, width - 36, 60)];
    cell.layer.cornerRadius = 14;
    cell.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *)) {
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    } else {
        cell.backgroundColor = [UIColor whiteColor];
    }
    [cell addTarget:self action:@selector(xhs778_presentEntry) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:cell];

    UIView *iconBox = [[UIView alloc] initWithFrame:CGRectMake(14, 14, 32, 32)];
    iconBox.layer.cornerRadius = 8;
    iconBox.layer.masksToBounds = YES;
    iconBox.backgroundColor = [UIColor systemRedColor];
    iconBox.userInteractionEnabled = NO;
    [cell addSubview:iconBox];

    UIImageView *icon = [[UIImageView alloc] initWithFrame:iconBox.bounds];
    icon.tintColor = [UIColor whiteColor];
    icon.contentMode = UIViewContentModeCenter;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
        icon.image = [UIImage systemImageNamed:@"face.smiling.fill" withConfiguration:cfg];
    }
    [iconBox addSubview:icon];

    UILabel *titleL = [[UILabel alloc] initWithFrame:CGRectMake(58, 0, cell.bounds.size.width - 96, 60)];
    titleL.text = @"XHS778 表情保存";
    titleL.font = [UIFont systemFontOfSize:16];
    titleL.textColor = [UIColor labelColor];
    titleL.userInteractionEnabled = NO;
    [cell addSubview:titleL];

    UIImageView *arrow = [[UIImageView alloc] initWithFrame:CGRectMake(cell.bounds.size.width - 30, 23, 8, 14)];
    arrow.tintColor = [UIColor tertiaryLabelColor];
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

    NSNumber *scanned = objc_getAssociatedObject(self, &kXHS778FeedbackScannedKey);
    if (active && !scanned.boolValue && !addIp) {
        UILabel *l = XHS778FindLabel(cell.contentView);
        if (l.text.length && [l.text isEqualToString:@"添加表情"]) {
            objc_setAssociatedObject(self, &kXHS778FeedbackAddIndexKey, indexPath, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

static UIButton *XHS778FindButtonWithTitle(UIView *root, NSString *title) {
    if (!root) return nil;
    if ([root isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)root;
        if (b.tag == kXHS778PreviewSaveButtonTag) return nil;
        if ([b.currentTitle isEqualToString:title]) return b;
    }
    for (UIView *sub in root.subviews) {
        UIButton *b = XHS778FindButtonWithTitle(sub, title);
        if (b) return b;
    }
    return nil;
}

static UIButton *XHS778FindPreviewActionButton(UIView *root) {
    UIButton *btn = XHS778FindButtonWithTitle(root, @"添加表情");
    if (btn) return btn;
    btn = XHS778FindButtonWithTitle(root, @"已添加表情");
    if (btn) return btn;

    UIButton *best = nil;
    CGFloat bestScore = 0;
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    while (q.count > 0) {
        UIView *cur = q.firstObject;
        [q removeObjectAtIndex:0];
        if ([cur isKindOfClass:[UIButton class]]) {
            UIButton *b = (UIButton *)cur;
            if (b.tag == kXHS778PreviewSaveButtonTag) {
                [q addObjectsFromArray:cur.subviews];
                continue;
            }
            CGRect r = [b.superview convertRect:b.frame toView:root];
            BOOL centered = fabs(CGRectGetMidX(r) - root.bounds.size.width / 2.0) < 80;
            BOOL buttonLike = r.size.width >= 140 && r.size.width <= 260 && r.size.height >= 32 && r.size.height <= 56;
            BOOL belowImage = r.origin.y > root.bounds.size.height * 0.45;
            if (centered && buttonLike && belowImage) {
                CGFloat score = r.origin.y;
                if (score > bestScore) {
                    bestScore = score;
                    best = b;
                }
            }
        }
        [q addObjectsFromArray:cur.subviews];
    }
    return best;
}

static void XHS778AddPreviewSaveButton(UIViewController *vc) {
    if (!XHS778Enabled() || !XHS778PreviewSaveEnabled()) return;
    if (!vc || !vc.viewLoaded) return;
    UIView *root = vc.view;
    if (!root || root.bounds.size.width <= 0) return;

    UIButton *addBtn = XHS778FindPreviewActionButton(root);
    CGRect targetFrame = CGRectZero;
    UIColor *bgColor = [UIColor systemRedColor];
    UIColor *titleColor = [UIColor whiteColor];
    UIFont *font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    CGFloat corner = 20;

    if (addBtn && addBtn.superview) {
        CGRect af = [addBtn.superview convertRect:addBtn.frame toView:root];
        targetFrame = CGRectMake(af.origin.x, CGRectGetMaxY(af) + 12, af.size.width, af.size.height);
        if (CGRectGetMaxY(targetFrame) > root.bounds.size.height - 24) {
            targetFrame.origin.y = af.origin.y - af.size.height - 12;
        }
        if (addBtn.backgroundColor && ![addBtn.currentTitle isEqualToString:@"已添加表情"]) {
            bgColor = addBtn.backgroundColor;
        }
        UIColor *tc = [addBtn titleColorForState:UIControlStateNormal];
        if (tc) titleColor = tc;
        if (addBtn.titleLabel.font) font = addBtn.titleLabel.font;
        if (addBtn.layer.cornerRadius > 0) corner = addBtn.layer.cornerRadius;
    } else {
        CGFloat w = 190;
        CGFloat h = 42;
        targetFrame = CGRectMake((root.bounds.size.width - w) / 2.0, root.bounds.size.height * 0.76, w, h);
    }

    UIButton *saveBtn = (UIButton *)[root viewWithTag:kXHS778PreviewSaveButtonTag];
    if (!saveBtn) {
        saveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        saveBtn.tag = kXHS778PreviewSaveButtonTag;
        [saveBtn setTitle:@"保存表情" forState:UIControlStateNormal];
        [saveBtn addTarget:[XHS778PreviewBtnTarget sharedTarget]
                    action:@selector(onPreviewSavePressed:)
          forControlEvents:UIControlEventTouchUpInside];
        [root addSubview:saveBtn];
    }
    saveBtn.tag = kXHS778PreviewSaveButtonTag;
    saveBtn.frame = targetFrame;
    saveBtn.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    saveBtn.backgroundColor = bgColor;
    saveBtn.layer.cornerRadius = corner;
    saveBtn.layer.masksToBounds = YES;
    [saveBtn setTitleColor:titleColor forState:UIControlStateNormal];
    saveBtn.titleLabel.font = font;
    [root bringSubviewToFront:saveBtn];

    objc_setAssociatedObject(vc, &kXHS778PreviewSaveButtonInjectedKey, saveBtn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}


#pragma mark - Hook UIButton：长按表情菜单中「删除表情」按钮右侧追加「保存」按钮

static const NSInteger kXHS778MenuSaveButtonTag = 778201;
static const NSInteger kXHS778MenuVSepTag       = 778202;
static char kXHS778MenuButtonProcessedKey;

%hook UIButton

- (void)setTitle:(NSString *)title forState:(UIControlState)state {
    %orig;
    if (state != UIControlStateNormal) return;
    if (!XHS778Enabled() || !XHS778SenderMenuSaveEnabled()) return;
    if (!title.length) return;
    if (![title isEqualToString:@"删除表情"] && ![title isEqualToString:@"添加到表情"]) return;
    if (self.tag == kXHS778MenuSaveButtonTag) return;

    UIButton *btn = self;
    NSNumber *processed = objc_getAssociatedObject(btn, &kXHS778MenuButtonProcessedKey);
    if (processed.boolValue) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *container = btn.superview;
        if (!container) return;
        if ([container viewWithTag:kXHS778MenuSaveButtonTag]) return;

        objc_setAssociatedObject(btn, &kXHS778MenuButtonProcessedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // 不动原按钮，扩展容器宽度，在原按钮右侧追加「保存」按钮 + 竖线
        CGRect bf = btn.frame;
        CGRect cf = container.frame;
        CGFloat needRight = bf.origin.x + bf.size.width * 2;
        if (cf.size.width < needRight) {
            container.frame = CGRectMake(cf.origin.x, cf.origin.y, needRight, cf.size.height);
            container.clipsToBounds = NO;
        }

        // 竖线分隔
        UIView *vSep = [[UIView alloc] initWithFrame:CGRectMake(bf.origin.x + bf.size.width - 0.25,
                                                                 bf.origin.y + 8,
                                                                 0.5,
                                                                 bf.size.height - 16)];
        vSep.tag = kXHS778MenuVSepTag;
        vSep.userInteractionEnabled = NO;
        vSep.backgroundColor = [[UIColor separatorColor] colorWithAlphaComponent:0.5];
        [container addSubview:vSep];

        // 保存按钮（与原按钮等大、等位置在右侧）
        UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        saveBtn.tag = kXHS778MenuSaveButtonTag;
        saveBtn.frame = CGRectMake(bf.origin.x + bf.size.width, bf.origin.y, bf.size.width, bf.size.height);
        saveBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
        [saveBtn setTitle:@"保存" forState:UIControlStateNormal];
        saveBtn.titleLabel.font = btn.titleLabel.font ?: [UIFont systemFontOfSize:14];
        saveBtn.tintColor = btn.tintColor;
        UIColor *textColor = [btn titleColorForState:UIControlStateNormal];
        if (!textColor) textColor = [UIColor labelColor];
        [saveBtn setTitleColor:textColor forState:UIControlStateNormal];
        [saveBtn setTitleColor:[textColor colorWithAlphaComponent:0.5] forState:UIControlStateHighlighted];
        saveBtn.backgroundColor = [UIColor clearColor];
        [saveBtn addTarget:btn action:@selector(xhs778_menuSavePressed:) forControlEvents:UIControlEventTouchUpInside];
        [container addSubview:saveBtn];
    });
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
