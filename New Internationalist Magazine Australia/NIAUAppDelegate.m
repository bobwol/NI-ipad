//
//  NIAUAppDelegate.m
//  New Internationalist Magazine Australia
//
//  Created by Simon Loffler on 20/06/13.
//  Copyright (c) 2013 New Internationalist Australia. All rights reserved.
//

#import "NIAUAppDelegate.h"

#import "NIAUViewController.h"
#import "NIAUInAppPurchaseHelper.h"
#import <Parse/Parse.h>
#import "local.h"
#import "NIAUPublisher.h"
#import "NIAUArticleViewController.h"
#import "NIAUIssue.h"
#import <objc/runtime.h>
const char NotificationKey;

#import "GAI.h"
#import "GAITracker.h"
#import "GAITrackedViewController.h"
#import "GAIDictionaryBuilder.h"
#import "GAIFields.h"
#import "GAILogger.h"

@implementation NIAUAppDelegate
{
    BOOL moveSuccess;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // Load the In App Purchase Helper at launch to check for unfinished purchases.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        [NIAUInAppPurchaseHelper sharedInstance];
    });
    
    // Setup Parse for Notifications
    [Parse setApplicationId:PARSE_APPLICATION_ID
                  clientKey:PARSE_CLIENT_KEY];
        
    // Parse tracking analytics
//    [PFAnalytics trackAppOpenedWithLaunchOptions:launchOptions];
    if (application.applicationState != UIApplicationStateBackground) {
        // Track an app open here if we launch with a push, unless
        // "content_available" was used to trigger a background push (introduced
        // in iOS 7). In that case, we skip tracking here to avoid double counting
        // the app-open.
        BOOL preBackgroundPush = ![application respondsToSelector:@selector(backgroundRefreshStatus)];
        BOOL oldPushHandlerOnly = ![self respondsToSelector:@selector(application:didReceiveRemoteNotification:fetchCompletionHandler:)];
        BOOL noPushPayload = ![launchOptions objectForKey:UIApplicationLaunchOptionsRemoteNotificationKey];
        if (preBackgroundPush || oldPushHandlerOnly || noPushPayload) {
            [PFAnalytics trackAppOpenedWithLaunchOptions:launchOptions];
        }
    }
    
    // Setup app to receive UIRemoteNotifications
    [application registerForRemoteNotificationTypes:UIRemoteNotificationTypeBadge|
     UIRemoteNotificationTypeAlert|
     UIRemoteNotificationTypeSound|
     UIRemoteNotificationTypeNewsstandContentAvailability];
    
    // TODO: Remove this for launch - allows multiple NewsStand notifications. :-)
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"NKDontThrottleNewsstandContentNotifications"];
    
    // When we receive a Remote Notification, grab the issue number from the payload and download it.
    NSDictionary *payload = [launchOptions objectForKey:UIApplicationLaunchOptionsRemoteNotificationKey];
    if(payload) {        
        // This only fires if the application is launched from a remote notification by the user
        // Also fires when the newsstand content-available starts the app in the background.
        
        [self handleRemoteNotification:application andUserInfo:payload];
    }
    
    // Google Analytics
    
    // Optional: automatically send uncaught exceptions to Google Analytics.
    [GAI sharedInstance].trackUncaughtExceptions = YES;
    
    // Optional: set Google Analytics dispatch interval to e.g. 20 seconds.
    [GAI sharedInstance].dispatchInterval = 20;
    
    // Optional: set Logger to VERBOSE for debug information.
//    [[[GAI sharedInstance] logger] setLogLevel:kGAILogLevelVerbose];
    
    // Initialize tracker.
    id<GAITracker> tracker = [[GAI sharedInstance] trackerWithTrackingId:GOOGLE_ANALYTICS_ID];
    NSLog(@"Google Analytics tracker initialized: %@", tracker);
    
    // If user hasn't set a default, set it to TRUE
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"googleAnalytics"] == nil) {
        NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
        [userDefaults setBool:TRUE forKey:@"googleAnalytics"];
        [userDefaults synchronize];
    } else if ([[NSUserDefaults standardUserDefaults] boolForKey:@"googleAnalytics"] == 0) {
        // User has asked to opt-out of Google Analytics
        [[GAI sharedInstance] setOptOut:YES];
    }
    
    // Override point for customization after application launch.
    return YES;
}

#pragma mark - URL open handling

- (BOOL)application:(UIApplication *)application handleOpenURL:(NSURL *)url
{
    // Launched from a link newint://issues/id/articles/id
    
    BOOL okayToLoad = false;
    
    NSError *error = NULL;
    NSRegularExpression *URLRegex = [NSRegularExpression regularExpressionWithPattern:@"(issues)\\/(\\d+)\\/(articles)\\/(\\d+)"
                                                                              options:NSRegularExpressionCaseInsensitive
                                                                                error:&error];
    
    NSUInteger numberOfMatches = [URLRegex numberOfMatchesInString:[url absoluteString]
                                                           options:0
                                                             range:NSMakeRange(0, [[url absoluteString] length])];
    
    if ((numberOfMatches > 0) && !error && [[url absoluteString] hasPrefix:@"newint"]) {
        // The launch string passes regex, so should be okay
        // TODO: handle ids not found.
        okayToLoad = true;
    }
    
    if (okayToLoad) {
        // It's probably a good link, so let's load it.
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:[[NSBundle mainBundle].infoDictionary objectForKey:@"UIMainStoryboardFile"] bundle:[NSBundle mainBundle]];
        
        NIAUArticleViewController *articleViewController = [storyboard instantiateViewControllerWithIdentifier:@"article"];
        
        NSString *articleIDFromURL = [[url pathComponents] lastObject];
        NSNumber *articleID = [NSNumber numberWithInt:(int)[articleIDFromURL integerValue]];
        NSString *issueIDFromURL = [[url pathComponents] objectAtIndex:1];
        NSNumber *issueID = [NSNumber numberWithInt:(int)[issueIDFromURL integerValue]];
        NSArray *arrayOfIssues = [NIAUIssue issuesFromNKLibrary];
        NIAUIssue *issue = [arrayOfIssues objectAtIndex:[arrayOfIssues indexOfObjectPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
            return ([[obj railsID] isEqualToNumber:issueID]);
        }]];
        [issue forceDownloadArticles];
        
        articleViewController.article = [issue articleWithRailsID:articleID];
        [(UINavigationController*)self.window.rootViewController pushViewController:articleViewController animated:YES];
        
        return YES;
    } else {
        // Malformed link, so ignore it and just start the app.
        [[[UIAlertView alloc] initWithTitle:@"Sorry!" message:@"We don't recognise that link that you tried to open." delegate:self cancelButtonTitle:@"Okay." otherButtonTitles: nil] show];
        return NO;
    }
}

#pragma mark - Parse setup

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
    // Store the deviceToken in the current installation and save it to Parse.
    PFInstallation *currentInstallation = [PFInstallation currentInstallation];
    [currentInstallation setDeviceTokenFromData:deviceToken];
    [currentInstallation saveInBackground];
    NSLog(@"Parse installation objectId: %@", [currentInstallation objectId]);
}

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo
{    
    if ((application.applicationState == UIApplicationStateInactive) || (application.applicationState == UIApplicationStateBackground)) {
        [PFAnalytics trackAppOpenedWithRemoteNotificationPayload:userInfo];
        [self turnBadgeIconOn];
        [self handleRemoteNotification:application andUserInfo:userInfo];
    } else {
        [self handleNotification:userInfo];
        [PFPush handlePush:userInfo];
    }
}

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler
{
    if ((application.applicationState == UIApplicationStateInactive) || (application.applicationState == UIApplicationStateBackground)) {
        [PFAnalytics trackAppOpenedWithRemoteNotificationPayload:userInfo];
        [self turnBadgeIconOn];
        [self handleRemoteNotification:application andUserInfo:userInfo];
    } else {
        [self handleNotification:userInfo];
    }
}

- (void)handleRemoteNotification: (UIApplication *)application andUserInfo: (NSDictionary *)userInfo
{
    // Start background download.
    [self startBackgroundDownloadWithUserInfo:userInfo];
    
    UILocalNotification *localNotif = [[UILocalNotification alloc] init];
    if (localNotif) {
        localNotif.alertBody = [NSString stringWithFormat:
                                NSLocalizedString(@"%@", nil), [[userInfo objectForKey:@"aps"] objectForKey:@"alert"]];
        localNotif.alertAction = NSLocalizedString(@"Read it now.", nil);
        localNotif.soundName = [NSString stringWithFormat:
                                NSLocalizedString(@"%@", nil), [[userInfo objectForKey:@"aps"] objectForKey:@"sound"]];
        localNotif.applicationIconBadgeNumber = [[[userInfo objectForKey:@"aps"] objectForKey:@"badge"] intValue];
        [application presentLocalNotificationNow:localNotif];
    }
}

- (void)handleNotification: (NSDictionary *)userInfo
{
    NSLog(@"UserInfo: %@", userInfo);
    // Ask the user whether they want to download the new issue now
    NSString *message = [NSString stringWithFormat:@"%@ Would you like to download it now in the background?", [[userInfo objectForKey:@"aps"] objectForKey:@"alert"]];
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"New issue available" message:message delegate:self cancelButtonTitle:@"Not now." otherButtonTitles:@"Download", nil];
    [alert show];
    objc_setAssociatedObject(alert, &NotificationKey, userInfo, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)turnBadgeIconOn
{
    [[UIApplication sharedApplication] setApplicationIconBadgeNumber: 1];
}

- (void)startBackgroundDownloadWithUserInfo: (NSDictionary *)userInfo
{
    // Get zip file from Rails, unpack it and save it to the library as a new nkIssue.
    
    if(userInfo) {
        // Get the zipURL from Rails.
        NSString *railsID = [userInfo objectForKey:@"railsID"];
        NSString *zipURL = [[NIAUInAppPurchaseHelper sharedInstance] requestZipURLforRailsID: railsID];
        
        if (zipURL) {
            // Create NIAUIssue from userInfo
            NIAUIssue *newIssue = [NIAUIssue issueWithUserInfo:userInfo];
            
            // schedule for issue downloading in background
            NKIssue *newNKIssue = [[NKLibrary sharedLibrary] issueWithName:newIssue.name];
            if(newNKIssue) {
                NSURL *downloadURL = [NSURL URLWithString:zipURL];
                NSURLRequest *req = [NSURLRequest requestWithURL:downloadURL];
                NKAssetDownload *assetDownload = [newNKIssue addAssetWithRequest:req];
                [assetDownload downloadWithDelegate:self];
            }
        } else {
            NSLog(@"No zipURL, so aborting.");
        }
    }
}

#pragma mark AlertView delegate

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    NSDictionary *userInfo = objc_getAssociatedObject(alertView, &NotificationKey);
    
    switch (buttonIndex) {
        case 0:
            // Cancel pressed
            break;
        case 1:
            // Download pressed
            [self startBackgroundDownloadWithUserInfo:userInfo];
            break;
        default:
            break;
    }
}

#pragma mark - Download delegate

- (void)connectionDidFinishDownloading:(NSURLConnection *)connection destinationURL:(NSURL *)destinationURL
{
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
    
    [[NIAUInAppPurchaseHelper sharedInstance] unzipAndMoveFilesForConnection:connection toDestinationURL:destinationURL];
}

- (void)connectionDidResumeDownloading:(NSURLConnection *)connection totalBytesWritten:(long long)totalBytesWritten expectedTotalBytes:(long long)expectedTotalBytes
{
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
}

- (void)connection:(NSURLConnection *)connection didWriteData:(long long)bytesWritten totalBytesWritten:(long long)totalBytesWritten expectedTotalBytes:(long long)expectedTotalBytes
{
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
}

#pragma mark -

- (void)applicationWillResignActive:(UIApplication *)application
{
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later. 
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
}

@end
