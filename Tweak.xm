// Tweak.xm - XHS778 小红书表情包保存助手
// Author: lllxxx123456
// 测试版本：XHS 9.28.1

#import "XHS778Headers.h"

#pragma mark - 设置存储 Key（所有开关默认关）

static NSString * const kXHS778EnabledKey            = @"XHS778_Enabled";
static NSString * const kXHS778CommentSaveEnabledKey = @"XHS778_CommentSaveEnabled";
static NSString * const kXHS778PreviewSaveEnabledKey = @"XHS778_PreviewSaveEnabled";
static NSString * const kXHS778SenderMenuSaveKey     = @"XHS778_SenderMenuSaveEnabled";

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

#pragma mark - KCMenu 风格设置 VC

static const CGFloat kXHS778CardCornerRadius = 18.0;
static const CGFloat kXHS778CellHeight = 44.0;
static const CGFloat kXHS778HeaderHeight = 92.0;
static const CGFloat kXHS778FooterHeight = 56.0;

@interface XHS778SettingsVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UIView *settingsCard;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *menuSections;
@end

@implementation XHS778SettingsVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.30];

    CGFloat screenWidth = CGRectGetWidth([UIScreen mainScreen].bounds);
    CGFloat screenHeight = CGRectGetHeight([UIScreen mainScreen].bounds);
    CGFloat cardWidth = MIN(screenWidth - 48, 700);
    CGFloat cardHeight = MIN(screenHeight * 0.72, 580);

    CGRect cardFrame = CGRectMake((screenWidth - cardWidth) / 2.0,
                                  (screenHeight - cardHeight) / 2.0,
                                  cardWidth, cardHeight);
    self.settingsCard = [[UIView alloc] initWithFrame:cardFrame];
    self.settingsCard.layer.cornerRadius = kXHS778CardCornerRadius;
    self.settingsCard.layer.masksToBounds = YES;
    [self.view addSubview:self.settingsCard];

    UIBlurEffectStyle bs = UIBlurEffectStyleSystemThinMaterial;
    UIVisualEffect *effect = [UIBlurEffect effectWithStyle:bs];
    self.blurView = [[UIVisualEffectView alloc] initWithEffect:effect];
    self.blurView.frame = self.settingsCard.bounds;
    self.blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.settingsCard addSubview:self.blurView];

    [self _buildTopBar];
    [self _buildContentArea];
    [self _buildMenuData];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_onBackgroundTap:)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];
}

- (void)_buildTopBar {
    UIView *topBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.settingsCard.bounds), 48)];
    [self.blurView.contentView addSubview:topBar];

    UILabel *title = [[UILabel alloc] initWithFrame:topBar.bounds];
    title.text = @"XHS778";
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textColor = [UIColor labelColor];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [topBar addSubview:title];

    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    closeButton.frame = CGRectMake(CGRectGetWidth(topBar.bounds) - 60, 6, 52, 36);
    closeButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [closeButton setTitle:@"关闭" forState:UIControlStateNormal];
    closeButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [closeButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [closeButton addTarget:self action:@selector(_onClose) forControlEvents:UIControlEventTouchUpInside];
    [topBar addSubview:closeButton];

    UIView *separator = [[UIView alloc] initWithFrame:CGRectMake(0, CGRectGetMaxY(topBar.frame),
                                                                 CGRectGetWidth(self.settingsCard.bounds), 0.5)];
    separator.backgroundColor = [[UIColor separatorColor] colorWithAlphaComponent:0.4];
    [self.blurView.contentView addSubview:separator];
}

- (void)_buildContentArea {
    CGFloat tableY = 49;
    CGFloat tableHeight = CGRectGetHeight(self.settingsCard.bounds) - tableY - 36; // 底部留出 footer
    UIView *tableContainer = [[UIView alloc] initWithFrame:CGRectMake(12, tableY,
                                                                     CGRectGetWidth(self.settingsCard.bounds) - 24,
                                                                     tableHeight)];
    [self.blurView.contentView addSubview:tableContainer];

    self.tableView = [[UITableView alloc] initWithFrame:tableContainer.bounds style:UITableViewStyleGrouped];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = kXHS778CellHeight;
    self.tableView.estimatedRowHeight = 0;
    self.tableView.estimatedSectionHeaderHeight = 0;
    self.tableView.estimatedSectionFooterHeight = 0;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.showsVerticalScrollIndicator = NO;
    self.tableView.alwaysBounceVertical = YES;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 12, 0);
    [tableContainer addSubview:self.tableView];

    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableContainer.bounds.size.width, kXHS778HeaderHeight)];

    UIView *infoCard = [[UIView alloc] initWithFrame:CGRectMake(0, 12, headerView.bounds.size.width, kXHS778HeaderHeight - 16)];
    infoCard.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:0.65];
    infoCard.layer.cornerRadius = 12;
    infoCard.layer.masksToBounds = YES;
    infoCard.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, infoCard.bounds.size.width - 32, 24)];
    nameLabel.text = @"小红书表情包保存助手";
    nameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    nameLabel.textColor = [UIColor labelColor];
    nameLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [infoCard addSubview:nameLabel];

    UILabel *descLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 38, infoCard.bounds.size.width - 32, 18)];
    descLabel.text = @"长按评论 / 表情详情 / 发送菜单 一键保存";
    descLabel.font = [UIFont systemFontOfSize:12];
    descLabel.textColor = [UIColor secondaryLabelColor];
    descLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [infoCard addSubview:descLabel];

    [headerView addSubview:infoCard];
    self.tableView.tableHeaderView = headerView;

    UIView *footerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableContainer.bounds.size.width, kXHS778FooterHeight)];
    UILabel *tipLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, footerView.bounds.size.width - 32, 22)];
    tipLabel.text = @"⚠ 仅用于学习交流，请尊重原作者版权";
    tipLabel.font = [UIFont systemFontOfSize:11];
    tipLabel.textColor = [UIColor tertiaryLabelColor];
    tipLabel.textAlignment = NSTextAlignmentCenter;
    tipLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [footerView addSubview:tipLabel];

    UILabel *versionLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 28, footerView.bounds.size.width - 32, 18)];
    versionLabel.text = @"在 XHS 9.28.1 中测试";
    versionLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    versionLabel.textColor = [UIColor secondaryLabelColor];
    versionLabel.textAlignment = NSTextAlignmentCenter;
    versionLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [footerView addSubview:versionLabel];

    self.tableView.tableFooterView = footerView;
}

- (void)_buildMenuData {
    self.menuSections = [NSMutableArray arrayWithArray:@[
        [NSMutableDictionary dictionaryWithDictionary:@{
            @"title": @"总开关",
            @"expanded": @YES,
            @"items": @[
                @{@"title": @"启用 XHS778",
                  @"detail": @"插件总开关，关闭后所有功能停用",
                  @"key": kXHS778EnabledKey,
                  @"isMaster": @YES}
            ]
        }],
        [NSMutableDictionary dictionaryWithDictionary:@{
            @"title": @"保存功能",
            @"expanded": @YES,
            @"items": @[
                @{@"title": @"长按评论保存表情",
                  @"detail": @"在长按评论的菜单中显示「保存表情」",
                  @"key": kXHS778CommentSaveEnabledKey},
                @{@"title": @"表情详情页保存",
                  @"detail": @"在表情详情页显示「保存」按钮",
                  @"key": kXHS778PreviewSaveEnabledKey},
                @{@"title": @"发送菜单保存表情",
                  @"detail": @"长按已添加 / 推荐表情时显示下载图标",
                  @"key": kXHS778SenderMenuSaveKey}
            ]
        }]
    ]];
}

- (void)_onClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)_onBackgroundTap:(UITapGestureRecognizer *)gesture {
    CGPoint p = [gesture locationInView:self.view];
    if (!CGRectContainsPoint(self.settingsCard.frame, p)) {
        [self _onClose];
    }
}

#pragma mark - TableView DataSource & Delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.menuSections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSDictionary *sectionData = self.menuSections[section];
    BOOL expanded = [sectionData[@"expanded"] boolValue];
    NSArray *items = sectionData[@"items"];
    return expanded ? (1 + items.count) : 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return section == 0 ? 4.0 : 12.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *header = [[UIView alloc] init];
    header.backgroundColor = [UIColor clearColor];
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return 0.1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row == 0) return kXHS778CellHeight;
    return 60.0; // 子项行高
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *sectionData = self.menuSections[indexPath.section];
    BOOL expanded = [sectionData[@"expanded"] boolValue];
    NSArray *items = sectionData[@"items"];

    if (indexPath.row == 0) {
        return [self _headerCellAt:indexPath section:sectionData expanded:expanded];
    }
    NSDictionary *item = items[indexPath.row - 1];
    return [self _switchCellAt:indexPath item:item];
}

- (UITableViewCell *)_headerCellAt:(NSIndexPath *)indexPath section:(NSDictionary *)sectionData expanded:(BOOL)expanded {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = [UIColor clearColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, kXHS778CellHeight)];
    card.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:0.65];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if (expanded) {
        card.layer.cornerRadius = 10;
        card.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    } else {
        card.layer.cornerRadius = 10;
        card.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                                   kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    }
    card.layer.masksToBounds = YES;
    [cell.contentView insertSubview:card atIndex:0];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    icon.tintColor = [UIColor systemRedColor];
    icon.frame = CGRectMake(14, (kXHS778CellHeight - 14) / 2.0, 14, 14);
    icon.transform = expanded ? CGAffineTransformMakeRotation(M_PI_2) : CGAffineTransformIdentity;
    [cell.contentView addSubview:icon];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(40, 0,
                                                                    self.tableView.bounds.size.width - 60,
                                                                    kXHS778CellHeight)];
    titleLabel.text = sectionData[@"title"];
    titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [cell.contentView addSubview:titleLabel];

    return cell;
}

- (UITableViewCell *)_switchCellAt:(NSIndexPath *)indexPath item:(NSDictionary *)item {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = [UIColor clearColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    NSInteger totalRows = [self tableView:self.tableView numberOfRowsInSection:indexPath.section];
    BOOL isLast = (indexPath.row == totalRows - 1);
    CGFloat cellHeight = [self tableView:self.tableView heightForRowAtIndexPath:indexPath];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, cellHeight)];
    card.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:0.65];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if (isLast) {
        card.layer.cornerRadius = 10;
        card.layer.maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        card.layer.masksToBounds = YES;
    }
    [cell.contentView insertSubview:card atIndex:0];

    if (indexPath.row > 1) {
        UIView *separator = [[UIView alloc] initWithFrame:CGRectMake(14, 0, self.tableView.bounds.size.width - 28, 0.5)];
        separator.backgroundColor = [[UIColor separatorColor] colorWithAlphaComponent:0.3];
        separator.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [cell.contentView addSubview:separator];
    }

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 10,
                                                                    self.tableView.bounds.size.width - 90, 22)];
    titleLabel.text = item[@"title"];
    titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [cell.contentView addSubview:titleLabel];

    UILabel *detailLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 32,
                                                                     self.tableView.bounds.size.width - 90, 18)];
    detailLabel.text = item[@"detail"];
    detailLabel.font = [UIFont systemFontOfSize:11];
    detailLabel.textColor = [UIColor secondaryLabelColor];
    detailLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [cell.contentView addSubview:detailLabel];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.transform = CGAffineTransformMakeScale(0.85, 0.85);
    sw.onTintColor = [UIColor systemRedColor];
    sw.on = [[NSUserDefaults standardUserDefaults] boolForKey:item[@"key"]];
    sw.tag = (indexPath.section << 16) | (indexPath.row - 1);
    [sw addTarget:self action:@selector(_onSwitchChanged:) forControlEvents:UIControlEventValueChanged];

    BOOL isMaster = [item[@"isMaster"] boolValue];
    if (!isMaster) {
        BOOL master = XHS778Enabled();
        sw.enabled = master;
        cell.contentView.alpha = master ? 1.0 : 0.45;
    }

    cell.accessoryView = sw;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row != 0) return;
    NSMutableDictionary *sectionData = [self.menuSections[indexPath.section] mutableCopy];
    BOOL expanded = [sectionData[@"expanded"] boolValue];
    sectionData[@"expanded"] = @(!expanded);
    [self.menuSections replaceObjectAtIndex:indexPath.section withObject:sectionData];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:indexPath.section]
                  withRowAnimation:UITableViewRowAnimationFade];
}

- (void)_onSwitchChanged:(UISwitch *)sw {
    NSInteger section = sw.tag >> 16;
    NSInteger subIndex = sw.tag & 0xFFFF;
    NSDictionary *sectionData = self.menuSections[section];
    NSDictionary *item = sectionData[@"items"][subIndex];
    NSString *key = item[@"key"];
    [[NSUserDefaults standardUserDefaults] setBool:sw.isOn forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];

    // 主开关变化时刷新所有子开关启用状态
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


#pragma mark - Hook 设置主页：在「隐私设置」下方注入 XHS778 入口

static char kXHS778PrivacyIndexKey;     // 缓存「隐私设置」位置 NSIndexPath
static char kXHS778PrivacyScannedKey;   // 是否已完成扫描

%hook XYPHSettingViewController

- (void)viewDidLoad {
    %orig;
    objc_setAssociatedObject(self, &kXHS778PrivacyIndexKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kXHS778PrivacyScannedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (long long)tableView:(UITableView *)tableView numberOfRowsInSection:(long long)section {
    long long original = %orig;
    NSIndexPath *privacyIp = objc_getAssociatedObject(self, &kXHS778PrivacyIndexKey);
    if (privacyIp && privacyIp.section == section) {
        return original + 1;
    }
    return original;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *privacyIp = objc_getAssociatedObject(self, &kXHS778PrivacyIndexKey);
    if (privacyIp && privacyIp.section == indexPath.section) {
        if (indexPath.row == privacyIp.row + 1) {
            // 我们插入的入口
            static NSString *cellId = @"XHS778EntryCell";
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellId];
            }
            for (UIView *v in cell.contentView.subviews) {
                if (v.tag == 7780001 || v.tag == 7780002) [v removeFromSuperview];
            }

            cell.backgroundColor = [UIColor clearColor];
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.textLabel.text = nil;

            UIImageView *icon = [[UIImageView alloc] init];
            icon.tag = 7780001;
            icon.contentMode = UIViewContentModeScaleAspectFit;
            icon.tintColor = [UIColor systemRedColor];
            if (@available(iOS 13.0, *)) {
                icon.image = [UIImage systemImageNamed:@"face.smiling"];
            }
            icon.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:icon];

            UILabel *titleLabel = [[UILabel alloc] init];
            titleLabel.tag = 7780002;
            titleLabel.text = @"XHS778";
            titleLabel.font = [UIFont systemFontOfSize:16];
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
        if (indexPath.row > privacyIp.row + 1) {
            NSIndexPath *origIp = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
            return %orig(tableView, origIp);
        }
    }

    UITableViewCell *cell = %orig;

    // 第一次扫描各 cell 内容找出「隐私设置」位置
    NSNumber *scanned = objc_getAssociatedObject(self, &kXHS778PrivacyScannedKey);
    if (!scanned.boolValue && !privacyIp) {
        UILabel *l = XHS778FindLabel(cell.contentView);
        if (l.text.length && [l.text isEqualToString:@"隐私设置"]) {
            objc_setAssociatedObject(self, &kXHS778PrivacyIndexKey, indexPath, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, &kXHS778PrivacyScannedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    NSIndexPath *privacyIp = objc_getAssociatedObject(self, &kXHS778PrivacyIndexKey);
    if (privacyIp && privacyIp.section == indexPath.section) {
        if (indexPath.row == privacyIp.row + 1) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            XHS778SettingsVC *vc = [[XHS778SettingsVC alloc] init];
            vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
            vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
            [self presentViewController:vc animated:YES completion:nil];
            return;
        }
        if (indexPath.row > privacyIp.row + 1) {
            NSIndexPath *origIp = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
            %orig(tableView, origIp);
            return;
        }
    }
    %orig;
}

- (double)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *privacyIp = objc_getAssociatedObject(self, &kXHS778PrivacyIndexKey);
    if (privacyIp && privacyIp.section == indexPath.section) {
        if (indexPath.row == privacyIp.row + 1) {
            // 与原「隐私设置」行同高，避免视觉跳变
            NSIndexPath *origPrivacy = [NSIndexPath indexPathForRow:privacyIp.row inSection:privacyIp.section];
            return %orig(tableView, origPrivacy);
        }
        if (indexPath.row > privacyIp.row + 1) {
            NSIndexPath *origIp = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
            return %orig(tableView, origIp);
        }
    }
    return %orig;
}

- (double)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *privacyIp = objc_getAssociatedObject(self, &kXHS778PrivacyIndexKey);
    if (privacyIp && privacyIp.section == indexPath.section) {
        if (indexPath.row == privacyIp.row + 1) {
            NSIndexPath *origPrivacy = [NSIndexPath indexPathForRow:privacyIp.row inSection:privacyIp.section];
            return %orig(tableView, origPrivacy);
        }
        if (indexPath.row > privacyIp.row + 1) {
            NSIndexPath *origIp = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
            return %orig(tableView, origIp);
        }
    }
    return %orig;
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
    if (!gXHS778LastLongPressedEmojiView) return original;

    NSIndexPath *addIp = objc_getAssociatedObject(self, &kXHS778FeedbackAddIndexKey);
    if (addIp && addIp.section == section) {
        return original + 1;
    }
    return original;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL active = XHS778Enabled() && XHS778CommentSaveEnabled() && (gXHS778LastLongPressedEmojiView != nil);
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

    // 扫描「添加表情」位置
    NSNumber *scanned = objc_getAssociatedObject(self, &kXHS778FeedbackScannedKey);
    if (active && !scanned.boolValue && !addIp) {
        UILabel *l = XHS778FindLabel(cell.contentView);
        if (l.text.length && [l.text containsString:@"添加表情"]) {
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
    BOOL active = XHS778Enabled() && XHS778CommentSaveEnabled() && (gXHS778LastLongPressedEmojiView != nil);
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
    BOOL active = XHS778Enabled() && XHS778CommentSaveEnabled() && (gXHS778LastLongPressedEmojiView != nil);
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
    BOOL active = XHS778Enabled() && XHS778CommentSaveEnabled() && (gXHS778LastLongPressedEmojiView != nil);
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


#pragma mark - 表情详情页：MemePreviewPageController 添加「保存」按钮

static char kXHS778PreviewSaveButtonInjectedKey;

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
    UIView *v = sender.superview;
    while (v && ![v.nextResponder isKindOfClass:[UIViewController class]]) v = v.superview;
    UIView *root = v ?: sender.superview;
    XYAnimatedImageView *iv = XHS778FindAnimatedImageView(root);
    if (iv) {
        XHS778SaveEmojiFromImageView(iv);
    } else {
        // 兜底：找任何 UIImageView
        UIImageView *anyIv = nil;
        NSMutableArray *q = [NSMutableArray arrayWithObject:root];
        while (q.count > 0) {
            UIView *cur = q.firstObject;
            [q removeObjectAtIndex:0];
            if ([cur isKindOfClass:[UIImageView class]]) { anyIv = (UIImageView *)cur; break; }
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

static void XHS778AddPreviewSaveButton(UIViewController *vc) {
    if (!XHS778Enabled() || !XHS778PreviewSaveEnabled()) return;
    if (!vc || !vc.viewLoaded) return;
    if (objc_getAssociatedObject(vc, &kXHS778PreviewSaveButtonInjectedKey)) return;
    UIView *root = vc.view;
    if (!root || root.bounds.size.width <= 0) return;

    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    CGFloat size = 44;
    CGFloat topInset = 8;
    if (@available(iOS 11.0, *)) {
        topInset = root.safeAreaInsets.top + 8;
    }
    saveBtn.frame = CGRectMake(root.bounds.size.width - size - 16, topInset, size, size);
    saveBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    saveBtn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
    saveBtn.layer.cornerRadius = size / 2.0;
    saveBtn.tintColor = [UIColor whiteColor];
    if (@available(iOS 13.0, *)) {
        UIImage *img = [UIImage systemImageNamed:@"square.and.arrow.down"];
        [saveBtn setImage:img forState:UIControlStateNormal];
    }
    [saveBtn addTarget:[XHS778PreviewBtnTarget sharedTarget]
                action:@selector(onPreviewSavePressed:)
      forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:saveBtn];

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
        if (!container) return; // superview 还没准备好，等下一次 setTitle: 再尝试
        if ([container viewWithTag:kXHS778MenuDownloadButtonTag]) return; // 已注入

        // 原按钮 frame=(0,128,128,40)，container 宽 128，缩半为下载按钮腾空间
        CGRect btnFrame = btn.frame;
        CGFloat newWidth = btnFrame.size.width / 2.0;
        btn.frame = CGRectMake(btnFrame.origin.x, btnFrame.origin.y, newWidth, btnFrame.size.height);

        UIButton *dlBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        dlBtn.tag = kXHS778MenuDownloadButtonTag;
        dlBtn.frame = CGRectMake(btnFrame.origin.x + newWidth, btnFrame.origin.y, newWidth, btnFrame.size.height);
        dlBtn.tintColor = btn.tintColor;
        if (@available(iOS 13.0, *)) {
            UIImage *img = [UIImage systemImageNamed:@"square.and.arrow.down"];
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
