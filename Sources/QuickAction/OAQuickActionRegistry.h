//
//  OAQuickActionRegistry.h
//  OsmAnd
//
//  Created by Paul on 8/15/19.
//  Copyright © 2019 OsmAnd. All rights reserved.
//
//  OsmAnd/src/net/osmand/plus/quickaction/QuickActionRegistry.java
//  git revision 8dedb3908aabe6e4fdd59751914516461f09e6d9

#import "OAObservable.h"
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class OAQuickAction;
@class OAQuickActionType;

@interface OAQuickActionRegistry : NSObject

@property (readonly) OAObservable* quickActionListChangedObservable;

+ (OAQuickActionRegistry *)sharedInstance;

+ (OAQuickActionType *) TYPE_ADD_ITEMS;
+ (OAQuickActionType *) TYPE_CONFIGURE_MAP;
+ (OAQuickActionType *) TYPE_NAVIGATION;
+ (OAQuickActionType *) TYPE_CONFIGURE_SCREEN;
+ (OAQuickActionType *) TYPE_SETTINGS;
+ (OAQuickActionType *) TYPE_OPEN;

-(NSArray<OAQuickAction *> *) getQuickActions;

-(void) addQuickAction:(OAQuickAction *) action;
-(void) updateQuickAction:(OAQuickAction *) action;
-(void) updateQuickActions:(NSArray<OAQuickAction *> *) quickActions;
-(void) deleteQuickAction:(OAQuickAction *)action;
-(OAQuickAction *) getQuickAction:(long) identifier;
-(OAQuickAction *) getQuickAction:(NSInteger)type name:(NSString *)name params:(NSDictionary<NSString *, NSString *> *)params;
-(NSArray<OAQuickActionType *> *) produceTypeActionsListWithHeaders;
-(void) updateActionTypes;

- (OAQuickAction *) newActionByStringType:(NSString *) actionType;
- (OAQuickAction *) newActionByType:(NSInteger) type;

-(BOOL) isNameUnique:(OAQuickAction *) action;

-(OAQuickAction *) generateUniqueName:(OAQuickAction *) action;

- (long) getLastModifiedTime;
- (void) setLastModifiedTime:(long)lastModifiedTime;

- (NSInteger) getQuickActionsCount;

@end

NS_ASSUME_NONNULL_END
