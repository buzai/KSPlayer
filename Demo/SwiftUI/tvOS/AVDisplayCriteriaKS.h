//
//  AVDisplayCriteriaKS.h
//  KSPlayer
//
//  Created by kintan on 2022/8/28.
//

#ifndef AVDisplayCriteriaKS_h
#define AVDisplayCriteriaKS_h

#import <AVFoundation/AVDisplayCriteria.h>

@interface AVDisplayCriteria ()
@property(readonly) int videoDynamicRange;
@property(readonly, nonatomic) float refreshRate;
- (id)initWithRefreshRate:(float)arg1 videoDynamicRange:(int)arg2;
@end

#endif /* AVDisplayCriteriaKS_h */

