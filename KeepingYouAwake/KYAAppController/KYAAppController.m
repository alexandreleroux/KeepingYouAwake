//
//  KYAAppController.m
//  KeepingYouAwake
//
//  Created by Marcel Dierkes on 17.10.14.
//  Copyright (c) 2014 Marcel Dierkes. All rights reserved.
//

#import "KYAAppController.h"
#import "KYADefines.h"
#import "KYALocalizedStrings.h"
#import "KYAStatusItemController.h"
#import "KYABatteryCapacityThreshold.h"
#import "KYAActivationDurationsMenuController.h"
#import "KYAActivationUserNotification.h"

// Deprecated!
#define KYA_MINUTES(m) (m * 60.0f)
#define KYA_HOURS(h) (h * 3600.0f)

@interface KYAAppController () <KYAStatusItemControllerDelegate, KYAActivationDurationsMenuControllerDelegate>
@property (nonatomic, readwrite) KYASleepWakeTimer *sleepWakeTimer;
@property (nonatomic, readwrite) KYAStatusItemController *statusItemController;
@property (nonatomic) KYAActivationDurationsMenuController *menuController;

// Battery Status
@property (nonatomic) KYABatteryStatus *batteryStatus;
@property (nonatomic, getter=isBatteryOverrideEnabled) BOOL batteryOverrideEnabled;

// Menu
@property (weak, nonatomic) IBOutlet NSMenu *menu;
@property (weak, nonatomic) IBOutlet NSMenuItem *activationDurationsMenuItem;
@end

@implementation KYAAppController

#pragma mark - Life Cycle

- (instancetype)init
{
    self = [super init];
    if(self)
    {
        self.sleepWakeTimer = [KYASleepWakeTimer new];
        [self.sleepWakeTimer addObserver:self forKeyPath:@"scheduled" options:NSKeyValueObservingOptionNew context:NULL];

        self.statusItemController = [KYAStatusItemController new];
        self.statusItemController.delegate = self;
        
        [self configureUserNotificationCenter];

        // Check activate on launch state
        if([self shouldActivateOnLaunch])
        {
            [self activateTimer];
        }

        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(applicationWillFinishLaunching:)
                                                   name:NSApplicationWillFinishLaunchingNotification
                                                 object:nil];

        [self configureBatteryStatus];
        [self configureEventHandler];

        self.menuController = [KYAActivationDurationsMenuController new];
        self.menuController.delegate = self;
    }
    return self;
}

- (void)dealloc
{
    KYA_AUTO center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self name:NSApplicationDidFinishLaunchingNotification object:nil];
    [center removeObserver:self name:kKYABatteryCapacityThresholdDidChangeNotification object:nil];
}

- (void)awakeFromNib
{
    [super awakeFromNib];

    [self.menu setSubmenu:self.menuController.menu
                  forItem:self.activationDurationsMenuItem];
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if([object isEqual:self.sleepWakeTimer] && [keyPath isEqualToString:@"scheduled"])
    {
        KYA_WEAK weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Update the status item for scheduling changes
            BOOL active = [change[NSKeyValueChangeNewKey] boolValue];
            weakSelf.statusItemController.activeAppearanceEnabled = active;
        });
    }
}

#pragma mark - Default Time Interval

- (NSTimeInterval)defaultTimeInterval
{
    return NSUserDefaults.standardUserDefaults.kya_defaultTimeInterval;
}

#pragma mark - Activate on Launch

- (BOOL)shouldActivateOnLaunch
{
    return [NSUserDefaults.standardUserDefaults kya_isActivatedOnLaunch];
}

- (IBAction)toggleActivateOnLaunch:(id)sender
{
    KYA_AUTO defaults = NSUserDefaults.standardUserDefaults;
    defaults.kya_activateOnLaunch = ![defaults kya_isActivatedOnLaunch];
    [defaults synchronize];
}

#pragma mark - User Notification Center

- (void)configureUserNotificationCenter
{
    if(@available(macOS 11.0, *))
    {
        Auto center = KYAUserNotificationCenter.sharedCenter;
        [center requestAuthorizationIfUndetermined];
        [center clearAllDeliveredNotifications];
    }
}

#pragma mark - Sleep Wake Timer Handling

- (void)activateTimer
{
    [self activateTimerWithTimeInterval:self.defaultTimeInterval];
}

- (void)activateTimerWithTimeInterval:(NSTimeInterval)timeInterval
{
    // Do not allow negative time intervals
    if(timeInterval < 0)
    {
        return;
    }

    KYA_AUTO defaults = NSUserDefaults.standardUserDefaults;

    // Check battery overrides and register for capacity changes.
    [self checkAndEnableBatteryOverride];
    if([defaults kya_isBatteryCapacityThresholdEnabled])
    {
        [self.batteryStatus registerForCapacityChangesIfNeeded];
    }

    KYA_AUTO timerCompletion = ^(BOOL cancelled) {
        // Post deactivation notification
        if(@available(macOS 11.0, *))
        {
            Auto notification = [[KYAActivationUserNotification alloc] initWithFireDate:nil
                                                                             activating:NO];
            [KYAUserNotificationCenter.sharedCenter postNotification:notification];
        }

        // Quit on timer expiration
        if(cancelled == NO && [defaults kya_isQuitOnTimerExpirationEnabled])
        {
            [NSApplication.sharedApplication terminate:nil];
        }
    };
    [self.sleepWakeTimer scheduleWithTimeInterval:timeInterval completion:timerCompletion];

    // Post activation notification
    if(@available(macOS 11.0, *))
    {
        Auto fireDate = self.sleepWakeTimer.fireDate;
        Auto notification = [[KYAActivationUserNotification alloc] initWithFireDate:fireDate
                                                                         activating:YES];
        [KYAUserNotificationCenter.sharedCenter postNotification:notification];
    }
}

- (void)terminateTimer
{
    [self disableBatteryOverride];
    [self.batteryStatus unregisterFromCapacityChanges];

    if([self.sleepWakeTimer isScheduled])
    {
        [self.sleepWakeTimer invalidate];
    }
}

#pragma mark - Battery Status

- (KYABatteryStatus *)batteryStatus
{
    if(_batteryStatus == nil)
    {
        _batteryStatus = [KYABatteryStatus new];

        KYA_WEAK weakSelf = self;
        _batteryStatus.capacityChangeHandler = ^(CGFloat capacity) {
            [weakSelf batteryCapacityDidChange:capacity];
        };
    }
    return _batteryStatus;
}

- (void)configureBatteryStatus
{
    if(![self.batteryStatus isBatteryStatusAvailable])
    {
        return;
    }

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(batteryCapacityThresholdDidChange:)
                                               name:kKYABatteryCapacityThresholdDidChangeNotification
                                             object:nil];

    // Start receiving battery status changes
    if([NSUserDefaults.standardUserDefaults kya_isBatteryCapacityThresholdEnabled])
    {
        [self.batteryStatus registerForCapacityChangesIfNeeded];
    }
}

- (void)checkAndEnableBatteryOverride
{
    CGFloat currentCapacity = self.batteryStatus.currentCapacity;
    CGFloat threshold = NSUserDefaults.standardUserDefaults.kya_batteryCapacityThreshold;

    self.batteryOverrideEnabled = (currentCapacity <= threshold);
}

- (void)disableBatteryOverride
{
    self.batteryOverrideEnabled = NO;
}

- (void)batteryCapacityDidChange:(CGFloat)capacity
{
    CGFloat threshold = NSUserDefaults.standardUserDefaults.kya_batteryCapacityThreshold;
    if([self.sleepWakeTimer isScheduled] && (capacity <= threshold) && ![self isBatteryOverrideEnabled])
    {
        [self terminateTimer];
    }
}

#pragma mark - Battery Capacity Threshold Changes

- (void)batteryCapacityThresholdDidChange:(NSNotification *)notification
{
    if(![self.batteryStatus isBatteryStatusAvailable])
    {
        return;
    }

    [self terminateTimer];
}

#pragma mark - Apple Event Manager

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    KYA_AUTO eventManager = [NSAppleEventManager sharedAppleEventManager];
    [eventManager setEventHandler:self
                      andSelector:@selector(handleGetURLEvent:withReplyEvent:)
                    forEventClass:kInternetEventClass
                       andEventID:kAEGetURL];
}

- (void)handleGetURLEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)reply
{
    KYA_AUTO parameter = [event paramDescriptorForKeyword:keyDirectObject].stringValue;
    [KYAEventHandler.defaultHandler handleEventForURL:[NSURL URLWithString:parameter]];
}

- (void)configureEventHandler
{
    KYA_WEAK weakSelf = self;
    [KYAEventHandler.defaultHandler registerActionNamed:@"activate"
                                                  block:^(KYAEvent *event) {
                                                      typeof(self) strongSelf = weakSelf;
                                                      [strongSelf handleActivateActionForEvent:event];
                                                  }];

    [KYAEventHandler.defaultHandler registerActionNamed:@"deactivate"
                                                  block:^(KYAEvent *event) {
                                                      [weakSelf terminateTimer];
                                                  }];

    [KYAEventHandler.defaultHandler registerActionNamed:@"toggle"
                                                  block:^(KYAEvent *event) {
                                                      [weakSelf.statusItemController toggle];
                                                  }];
}

- (void)handleActivateActionForEvent:(KYAEvent *)event
{
    KYA_AUTO parameters = event.arguments;
    NSString *seconds = parameters[@"seconds"];
    NSString *minutes = parameters[@"minutes"];
    NSString *hours = parameters[@"hours"];

    [self terminateTimer];

    // Activate indefinitely if there are no parameters
    if(parameters.count == 0)
    {
        [self activateTimer];
    }
    else if(seconds)
    {
        [self activateTimerWithTimeInterval:(NSTimeInterval)ceil(seconds.doubleValue)];
    }
    else if(minutes)
    {
        [self activateTimerWithTimeInterval:(NSTimeInterval)KYA_MINUTES(ceil(minutes.doubleValue))];
    }
    else if(hours)
    {
        [self activateTimerWithTimeInterval:(NSTimeInterval)KYA_HOURS(ceil(hours.doubleValue))];
    }
}

#pragma mark - KYAStatusItemControllerDelegate

- (void)statusItemControllerShouldPerformMainAction:(KYAStatusItemController *)controller
{
    if([self.sleepWakeTimer isScheduled])
    {
        [self terminateTimer];
    }
    else
    {
        [self activateTimer];
    }
}

- (void)statusItemControllerShouldPerformAlternativeAction:(KYAStatusItemController *)controller
{
    [self.statusItemController showMenu:self.menu];
}

#pragma mark - KYAActivationDurationsMenuControllerDelegate

- (KYAActivationDuration *)currentActivationDuration
{
    KYA_AUTO sleepWakeTimer = self.sleepWakeTimer;
    if(![sleepWakeTimer isScheduled])
    {
        return nil;
    }

    NSTimeInterval seconds = sleepWakeTimer.scheduledTimeInterval;
    return [[KYAActivationDuration alloc] initWithSeconds:seconds];
}

- (void)activationDurationsMenuController:(KYAActivationDurationsMenuController *)controller didSelectActivationDuration:(KYAActivationDuration *)activationDuration
{
    [self terminateTimer];

    KYA_WEAK weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimeInterval seconds = activationDuration.seconds;
        [weakSelf activateTimerWithTimeInterval:seconds];
    });
}

- (NSDate *)fireDateForMenuController:(KYAActivationDurationsMenuController *)controller
{
    return self.sleepWakeTimer.fireDate;
}

@end
