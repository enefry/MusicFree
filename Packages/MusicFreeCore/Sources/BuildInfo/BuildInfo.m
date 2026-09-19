//
//  BuildInfo.m
//  MusicFreeCore
//
//  Created by 陈任伟 on 9/13/26.
//

#import "BuildInfo.h"

@implementation BuildInfo

+ (NSString *)buildTime {
    return [NSString stringWithFormat:@"%s %s",__DATE__,__TIME__];
}

@end
