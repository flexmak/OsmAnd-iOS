//
//  OATransportStopsBaseController.h
//  OsmAnd Maps
//
//  Created by Paul on 17.01.2023.
//  Copyright © 2023 OsmAnd. All rights reserved.
//

#import "OATargetInfoViewController.h"

@class OATransportStopRoute, OAPOI, OATransportStop;

@interface OATransportStopsBaseController : OATargetInfoViewController

@property (nonatomic) OAPOI *poi;
@property (nonatomic) OATransportStop *transportStop;

- (void) processTransportStop;
+ (OATransportStop *) findNearestTransportStopForAmenity:(OAPOI *)amenity;

@end
