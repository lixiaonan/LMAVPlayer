//
//  LMAVPlayerManager.m
//  LMIJKPlayer
//
//  Created by 李小南 on 2017/4/17.
//  Copyright © 2017年 LMIJKPlayer. All rights reserved.
//

#import "LMAVPlayerManager.h"
#import <MediaPlayer/MediaPlayer.h>
#import "LMPlayerStatusModel.h"

@implementation LMPlayerLayerView

- (void)layoutSubviews {
    [super layoutSubviews];
    _playerLayer.frame = self.bounds;
}

#pragma mark - public method

- (void)setPlayerLayer:(AVPlayerLayer *)playerLayer {
    
    _playerLayer = playerLayer;
    [self.layer insertSublayer:playerLayer atIndex:0];
    
    [self setNeedsLayout]; //是标记 异步刷新 会调但是慢
    [self layoutIfNeeded]; //加上此代码立刻刷新
}

@end

// -------------------------------

@interface LMAVPlayerManager()

@property (nonatomic, weak) id<LMAVPlayerManagerDelegate> delegate;

/** 播放属性 */
@property (nonatomic, strong) AVPlayer               *player;
@property (nonatomic, strong) AVPlayerItem           *playerItem;
@property (nonatomic, strong) AVURLAsset             *urlAsset;
@property (nonatomic, strong) AVAssetImageGenerator  *imageGenerator;
@property (nonatomic, strong) id                     timeObserve;

/** 状态记录 */
@property (nonatomic, assign) LMPlayerState state;
/** playerLayerView */
@property (nonatomic, strong) LMPlayerLayerView *playerLayerView;
/** 播放器的参数模型 */
@property (nonatomic, strong) LMPlayerStatusModel *playerStatusModel;
/** 声音滑杆 */
@property (nonatomic, strong) UISlider *volumeViewSlider;

@end

@implementation LMAVPlayerManager

+ (instancetype)playerManagerWithDelegate:(id<LMAVPlayerManagerDelegate>)delegate playerStatusModel:(LMPlayerStatusModel *)playerStatusModel {
    
    LMAVPlayerManager *playerMgr = [[LMAVPlayerManager alloc] init];
    playerMgr.delegate = delegate;
    playerMgr.playerStatusModel = playerStatusModel;
    
    return playerMgr;
}

// !!!: 创建AVPlayer
- (void)initPlayerWithUrl:(NSURL *)url {
    
    self.urlAsset = [AVURLAsset assetWithURL:url];
    // 初始化playerItem
    self.playerItem = [AVPlayerItem playerItemWithAsset:self.urlAsset];
    // 每次都重新创建Player，替换replaceCurrentItemWithPlayerItem:，该方法阻塞线程
    self.player = [AVPlayer playerWithPlayerItem:self.playerItem];
    // 初始化playerLayer
    AVPlayerLayer *playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayerView.playerLayer = playerLayer;
    
    // 此处为默认视频填充模式
    playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    
    [self addPlayTimer];
    [self addPlayerItemObserver];
    [self addBackgroundNotificationObservers];
    [self configureVolume];
    self.playerStatusModel.autoPlay = YES;
    self.playerStatusModel.pauseByUser = NO;
}

#pragma mark - getter

- (double)duration {
    return CMTimeGetSeconds(self.playerItem.duration);
}

- (double)currentTime {
    return [self currentSecond];
}

- (UIView *)playerLayerView {
    if (!_playerLayerView) {
        _playerLayerView = [[LMPlayerLayerView alloc] init];
    }
    return _playerLayerView;
}

#pragma mark - setter
- (void)setState:(LMPlayerState)state {
    _state = state;
    
    if ([self.delegate respondsToSelector:@selector(changePlayerState:)]) {
        [self.delegate changePlayerState:state];
    }
}

#pragma mark - 应用进入后台
- (void)addBackgroundNotificationObservers {
    // app退到后台
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillEnterBackground) name:UIApplicationWillResignActiveNotification object:nil];
    // app进入前台
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidEnterPlayGround) name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)removeBackgroundNotificationObservers {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)appWillEnterBackground {
    self.playerStatusModel.didEnterBackground = YES;
    [self.player pause];
    self.state = LMPlayerStatePause;
}

- (void)appDidEnterPlayGround {
    self.playerStatusModel.didEnterBackground = NO;
    if (!self.playerStatusModel.isPauseByUser) {
        self.state = LMPlayerStatePlaying;
        self.playerStatusModel.pauseByUser = NO;
        [self play];
    }
}

#pragma mark - 添加KVO通知

- (void)addPlayerItemObserver {
    if (self.playerItem) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playDidEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:self.playerItem];
        [self.playerItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:nil];
        [self.playerItem addObserver:self forKeyPath:@"loadedTimeRanges" options:NSKeyValueObservingOptionNew context:nil];
        // 缓冲区空了，需要等待数据
        [self.playerItem addObserver:self forKeyPath:@"playbackBufferEmpty" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:nil];
        // 缓冲区有足够数据可以播放了
        [self.playerItem addObserver:self forKeyPath:@"playbackLikelyToKeepUp" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:nil];
    }
}

- (void)addPlayTimer {
    __weak typeof(self) weakSelf = self;
    self.timeObserve = [self.player addPeriodicTimeObserverForInterval:CMTimeMake(1, 1) queue:nil usingBlock:^(CMTime time) {
        AVPlayerItem *currentItem = weakSelf.playerItem;
        NSArray *loadedRanges = currentItem.seekableTimeRanges;
        if (loadedRanges.count > 0 && currentItem.duration.timescale != 0) {
            CGFloat currentSecond = [weakSelf currentSecond];
            double playProgress = CMTimeGetSeconds(weakSelf.playerItem.currentTime) / self.duration;
            [weakSelf.delegate changePlayProgress:playProgress second:currentSecond];
        }
    }];
}

#pragma mark - 移除KVO

- (void)removePlayerItemObserver {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:self.playerItem];
    [self.playerItem removeObserver:self forKeyPath:@"status"];
    [self.playerItem removeObserver:self forKeyPath:@"loadedTimeRanges"];
    [self.playerItem removeObserver:self forKeyPath:@"playbackBufferEmpty"];
    [self.playerItem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp"];
}

#pragma mark - 通知/KVO回调

// !!!: 播放结束通知
- (void)playDidEnd:(NSNotification *)notification {
    self.state = LMPlayerStateStoped;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSString *,id> *)change context:(void *)context {
    if (object == self.player.currentItem) {
        if ([keyPath isEqualToString:@"status"]) {
            switch (self.player.currentItem.status) {
                case AVPlayerItemStatusUnknown:
                    self.state = LMPlayerStateUnknow;
                    break;
                case AVPlayerItemStatusReadyToPlay: {
                    self.state = LMPlayerStateReadyToPlay;
                    // 跳到xx秒播放视频
                    if (self.seekTime) {
                        [self seekToTime:self.seekTime completionHandler:nil];
                        self.seekTime = 0;
                    }
                }
                    break;
                case AVPlayerItemStatusFailed:
                    self.state = LMPlayerStateFailed;
                    break;
            }
        } else if ([keyPath isEqualToString:@"loadedTimeRanges"]) {
            // 计算缓冲进度
            NSTimeInterval timeInterval = [self availableDuration];
            double loadedProgress = timeInterval * 1.0 / self.duration;
            [self.delegate changeLoadProgress:loadedProgress second:timeInterval];
        } else if ([keyPath isEqualToString:@"playbackBufferEmpty"]) {
            // 当缓冲是空的时候
            if (self.playerItem.isPlaybackBufferEmpty) {
                self.state = LMPlayerStateBuffering;
            }
        } else if ([keyPath isEqualToString:@"playbackLikelyToKeepUp"]) {
            
            if ([change[NSKeyValueChangeNewKey] isEqualToValue:change[NSKeyValueChangeOldKey]]) {
                return;
            }
            
            // 当缓冲好的时候
            if (self.playerItem.isPlaybackLikelyToKeepUp) {
                // 当缓冲好的时候可能达到继续播放时
                [self.delegate didBuffer:self];
            }
        }
    }
}


/**
 *  计算缓冲进度
 *
 *  @return 缓冲进度
 */

- (NSTimeInterval)availableDuration {
    
    
    //static CFTimeInterval last_T = 0.0f;
    
    //static float totalLoadlength = 0.0f;
    
    CMTimeRange timeRange     = [self timeRange];
    float startSeconds        = CMTimeGetSeconds(timeRange.start);
    float durationSeconds     = CMTimeGetSeconds(timeRange.duration);
    NSTimeInterval result     = startSeconds + durationSeconds;// 计算缓冲总进度
    
    return result;
}

- (CMTimeRange)timeRange {
    NSArray *loadedTimeRanges = [[_player currentItem] loadedTimeRanges];
    return [loadedTimeRanges.firstObject CMTimeRangeValue];// 获取缓冲区域
}

// 计算当前在第几秒
- (NSTimeInterval)currentSecond {
    return _playerItem.currentTime.value * 1.0 / _playerItem.currentTime.timescale;
}

#pragma mark - 播放控制

- (void)play {
    if (self.state == LMPlayerStateReadyToPlay || self.state == LMPlayerStatePause || self.state == LMPlayerStateBuffering) {
        [self.player play];
        self.playerStatusModel.pauseByUser = NO;
        if (self.player.rate > 0) {
            self.state = LMPlayerStatePlaying;
        }
    }
}

- (void)rePlay {
    __weak typeof(self) wself = self;
    [self seekToTime:0 completionHandler:^(BOOL finished) {
        if (finished) {
            wself.state = LMPlayerStateReadyToPlay;
            [wself play];
            self.playerStatusModel.playDidEnd = NO;
        }
    }];
}

- (void)pause {
    if (self.state == LMPlayerStatePlaying || self.state == LMPlayerStateBuffering) {
        [self.player pause];
        self.state = LMPlayerStatePause;
        self.playerStatusModel.pauseByUser = YES;
    }
}

- (void)stop {
    [self.player setRate:0.0];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self removePlayerItemObserver];
    [self removeBackgroundNotificationObservers];
    
    [self.player removeTimeObserver:self.timeObserve];
    [self.player replaceCurrentItemWithPlayerItem:nil];
    [self.playerLayerView removeFromSuperview];
    
    _timeObserve = nil;
    _urlAsset = nil;
    _imageGenerator = nil;
    _playerLayerView = nil;
    _playerItem = nil;
    _player = nil;
}

- (void)seekToTime:(NSInteger)dragedSeconds completionHandler:(void (^)(BOOL finished))completionHandler {
    if (self.player.currentItem.status == AVPlayerItemStatusReadyToPlay) {
#warning 怎么控制loading
        [self.delegate startPlayerSeekTime];
        
        if(self.state == LMPlayerStateStoped) {
            self.state = LMPlayerStateReadyToPlay;
        }
        
        // 转换成CMTime才能给player来控制播放进度
        CMTime dragedCMTime = CMTimeMake(dragedSeconds, 1);
        [self.player seekToTime:dragedCMTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
            // 视频跳转回调
            if (completionHandler) { completionHandler(finished); }
            // 只要快进, 那么久不是被用户暂停
            self.playerStatusModel.pauseByUser = NO;
            
            [self.delegate completionPlayerSeekTime];
        }];
    }
}

/**
 *  改变音量
 */
- (void)changeVolume:(CGFloat)value {
    self.volumeViewSlider.value -= value / 10000;
}

#pragma mark - 系统音量相关
/**
 *  获取系统音量
 */
- (void)configureVolume {
    MPVolumeView *volumeView = [[MPVolumeView alloc] init];
    _volumeViewSlider = nil;
    for (UIView *view in [volumeView subviews]){
        if ([view.class.description isEqualToString:@"MPVolumeSlider"]){
            _volumeViewSlider = (UISlider *)view;
            break;
        }
    }
    
    // 使用这个category的应用不会随着手机静音键打开而静音，可在手机静音下播放声音
    NSError *setCategoryError = nil;
    BOOL success = [[AVAudioSession sharedInstance]
                    setCategory: AVAudioSessionCategoryPlayback
                    error: &setCategoryError];
    
    if (!success) { /* handle the error in setCategoryError */ }
    
    // 监听耳机插入和拔掉通知
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audioRouteChangeListenerCallback:) name:AVAudioSessionRouteChangeNotification object:nil];
}

/**
 *  耳机插入、拔出事件
 */
- (void)audioRouteChangeListenerCallback:(NSNotification*)notification {
    NSDictionary *interuptionDict = notification.userInfo;
    
    NSInteger routeChangeReason = [[interuptionDict valueForKey:AVAudioSessionRouteChangeReasonKey] integerValue];
    
    switch (routeChangeReason) {
            
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable:
            // 耳机插入
            break;
            
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable:
        {
            // 耳机拔掉
            // 拔掉耳机继续播放
            [self play];
        }
            break;
            
        case AVAudioSessionRouteChangeReasonCategoryChange:
            // called at start - also when other audio wants to play
            NSLog(@"AVAudioSessionRouteChangeReasonCategoryChange");
            break;
    }
}

#pragma mark - 释放对象

- (void)dealloc {
    [self stop];
}

@end
