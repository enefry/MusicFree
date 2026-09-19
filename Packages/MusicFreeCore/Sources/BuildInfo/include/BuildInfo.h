//
//  BuildInfo.h
//  MusicFreeCore
//
//  Created by 陈任伟 on 9/13/26.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BuildInfo : NSObject

/// The date and time at which this source file was compiled.
+ (NSString *)buildTime;

@end

NS_ASSUME_NONNULL_END
