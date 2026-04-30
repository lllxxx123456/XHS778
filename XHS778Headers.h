// XHS778Headers.h
// 小红书 9.28.1 相关头文件声明 - XHS778 表情包保存插件

#ifndef XHS778Headers_h
#define XHS778Headers_h

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - XYImage / XYAnimatedImage

@protocol XYAnimatedImage <NSObject>
@property (readonly, nonatomic) NSData *animatedImageData;
@property (readonly, nonatomic) unsigned long long animatedImageType;
@property (readonly, nonatomic) unsigned long long animatedImageFrameCount;
@property (readonly, nonatomic) unsigned long long animatedImageLoopCount;
- (double)animatedImageDurationAtIndex:(unsigned long long)index;
- (id)animatedImageFrameAtIndex:(unsigned long long)index;
@end

@interface XYImage : UIImage <XYAnimatedImage>
@property (readonly, nonatomic) NSData *animatedImageData;
@property (readonly, nonatomic) unsigned long long animatedImageType;
@property (readonly, nonatomic) unsigned long long animatedImageFrameCount;
@property (readonly, nonatomic) unsigned long long animatedImageLoopCount;
@end

#pragma mark - XYAnimatedImageView

@interface XYAnimatedImageView : UIImageView
@property (nonatomic) BOOL currentIsPlayingAnimation;
@property (nonatomic) BOOL autoPlayAnimatedImage;
@property (nonatomic) unsigned long long currentAnimatedImageIndex;
@end

#pragma mark - 设置界面相关

@interface XYPHSettingViewController : UIViewController
@property (retain, nonatomic) UITableView *tableView;
@property (copy, nonatomic) NSDictionary *settingDic;
@end

@interface XYSettingLeftIconArrow : UITableViewCell
@property (retain, nonatomic) UIImageView *leftIcon;
@property (retain, nonatomic) UIButton *trailingBtn;
@property (retain, nonatomic) UIImageView *arrow;
- (void)setOptionTitle:(id)title;
@end

#pragma mark - 评论长按菜单相关

@interface XYCommentFeedbackPanelController : UIViewController
@property (nonatomic, retain) UIView *maskContentView;
@property (nonatomic, retain) UIView *feedbackView;
@property (nonatomic, retain) UITableView *tableView;
@property (nonatomic) double feedbackHeight;
- (void)dismissFeedbackView;
- (void)prepareOptions;
@end

#endif /* XHS778Headers_h */
