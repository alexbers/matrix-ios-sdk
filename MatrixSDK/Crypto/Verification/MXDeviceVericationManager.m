/*
 Copyright 2019 New Vector Ltd

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXDeviceVerificationManager.h"
#import "MXDeviceVerificationManager_Private.h"

#import "MXSession.h"
#import "MXCrypto_Private.h"

#import "MXTransactionCancelCode.h"

#pragma mark - Constants

NSString *const kMXDeviceVerificationErrorDomain = @"org.matrix.sdk.verification";
NSString *const kMXDeviceVerificationManagerNewTransactionNotification = @"kMXDeviceVerificationManagerNewTransactionNotification";
NSString *const kMXDeviceVerificationManagerNotificationTransactionKey = @"kMXDeviceVerificationManagerNotificationTransactionKey";


@interface MXDeviceVerificationManager ()
{
    // The queue to run background tasks
    dispatch_queue_t cryptoQueue;

    // All running transactions
    MXUsersDevicesMap<MXDeviceVerificationTransaction*> *transactions;
}
@end

@implementation MXDeviceVerificationManager

#pragma mark - Public methods -

- (void)beginKeyVerificationWithUserId:(NSString*)userId
                           andDeviceId:(NSString*)deviceId
                                method:(NSString*)method
                               success:(void(^)(MXDeviceVerificationTransaction *transaction))success
                               failure:(void(^)(NSError *error))failure
{
    NSLog(@"[MXKeyVerification] beginKeyVerification: device: %@:%@ method:%@", userId, deviceId, method);

    // Make sure we have other device keys
    [self loadDeviceWithDeviceId:deviceId andUserId:userId success:^(MXDeviceInfo *otherDevice) {

        MXDeviceVerificationTransaction *transaction;
        NSError *error;

        // We support only SAS at the moment
        if ([method isEqualToString:kMXKeyVerificationMethodSAS])
        {
            MXOutgoingSASTransaction *sasTransaction = [[MXOutgoingSASTransaction alloc] initWithOtherDevice:otherDevice andManager:self];
            [sasTransaction start];

            transaction = sasTransaction;
            [self addTransaction:transaction];
        }
        else
        {
            error = [NSError errorWithDomain:kMXDeviceVerificationErrorDomain
                                        code:MXDeviceVerificationUnsupportedMethodCode
                                    userInfo:@{
                                               NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unsupported verification method: %@", method]
                                               }];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (transaction)
            {
                success(transaction);
            }
            else
            {
                failure(error);
            }

        });

    } failure:^(NSError *error) {
        NSLog(@"[MXKeyVerification] beginKeyVerification: Error: %@", error);
        failure(error);
    }];
}


#pragma mark - SDK-Private methods -

- (instancetype)initWithCrypto:(MXCrypto *)crypto
{
    self = [super init];
    if (self)
    {
        _crypto = crypto;
        cryptoQueue = self.crypto.cryptoQueue;

        transactions = [MXUsersDevicesMap new];

        // Observe incoming to-device events
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onToDeviceEvent:) name:kMXSessionOnToDeviceEventNotification object:crypto.mxSession];
    }
    return self;
}


#pragma mark - Outgoing to_device events

- (MXHTTPOperation*)sendToOtherInTransaction:(MXDeviceVerificationTransaction*)transaction
                                   eventType:(NSString*)eventType
                                     content:(NSDictionary*)content
                                     success:(void (^)(void))success
                                     failure:(void (^)(NSError *error))failure
{
    MXUsersDevicesMap<NSDictionary*> *contentMap = [[MXUsersDevicesMap alloc] init];
    [contentMap setObject:content forUser:transaction.otherUserId andDevice:transaction.otherDeviceId];

    return [self sendToOther:transaction.otherUserId deviceId:transaction.otherDeviceId eventType:eventType content:content success:success failure:failure];
}

- (MXHTTPOperation*)sendToOther:(NSString*)userId
                       deviceId:(NSString*)deviceId
                      eventType:(NSString*)eventType
                        content:(NSDictionary*)content
                        success:(void (^)(void))success
                        failure:(void (^)(NSError *error))failure
{
    MXUsersDevicesMap<NSDictionary*> *contentMap = [[MXUsersDevicesMap alloc] init];
    [contentMap setObject:content forUser:userId andDevice:deviceId];

    return [self.crypto.matrixRestClient sendToDevice:eventType contentMap:contentMap txnId:nil success:success failure:failure];
}

- (void)cancelTransaction:(MXDeviceVerificationTransaction*)transaction code:(MXTransactionCancelCode*)code
{
    [self cancelTransaction:transaction.transactionId fromUserId:transaction.otherUserId andDevice:transaction.otherDeviceId code:code];
}

- (void)cancelTransaction:(NSString*)transactionId fromUserId:(NSString*)userId andDevice:(NSString*)deviceId code:(MXTransactionCancelCode*)code
{
    MXKeyVerificationCancel *cancel = [MXKeyVerificationCancel new];
    cancel.transactionId = transactionId;
    cancel.code = code.value;
    cancel.reason = code.humanReadable;

    NSLog(@"[MXKeyVerification] cancelTransaction: transactionId: %@. Code:%@. Reason: %@", transactionId, cancel.code, cancel.reason);

    [self sendToOther:userId deviceId:deviceId eventType:kMXEventTypeStringKeyVerificationCancel content:cancel.JSONDictionary success:nil failure:^(NSError *error) {

        NSLog(@"[MXKeyVerification] cancelTransaction. Error: %@", error);
    }];

    [self removeTransactionWithTransactionId:transactionId];
}


#pragma mark - Incoming to_device events

/**
 Handle a to-device event.

 @param notification the notification containing the to-device event.
 */
- (void)onToDeviceEvent:(NSNotification *)notification
{
    MXEvent *event = notification.userInfo[kMXSessionNotificationEventKey];
    
    dispatch_async(cryptoQueue, ^{
        switch (event.eventType)
        {
            case MXEventTypeKeyVerificationStart:
                [self handleStartEvent:event];
                break;

            case MXEventTypeKeyVerificationCancel:
                [self handleCancelEvent:event];
                break;

            case MXEventTypeKeyVerificationAccept:
                [self handleAcceptEvent:event];
                break;

            case MXEventTypeKeyVerificationKey:
                [self handleKeyEvent:event];
                break;

            case MXEventTypeKeyVerificationMac:
                [self handleMacEvent:event];
                break;

            default:
                break;
        }
    });
}

- (void)handleStartEvent:(MXEvent*)event
{
    NSLog(@"[MXKeyVerification] handleStartEvent");

    MXKeyVerificationStart *keyVerificationStart;
    MXJSONModelSetMXJSONModel(keyVerificationStart, MXKeyVerificationStart, event.content);

    if (!keyVerificationStart)
    {
        return;
    }
    if (!keyVerificationStart.isValid)
    {
        if (keyVerificationStart.transactionId && keyVerificationStart.fromDevice)
        {
            [self cancelTransaction:keyVerificationStart.transactionId
                         fromUserId:event.sender
                          andDevice:keyVerificationStart.fromDevice
                               code:MXTransactionCancelCode.invalidMessage];
        }

        return;
    }


    MXDeviceVerificationTransaction *existingTransaction = [self transactionWithUser:keyVerificationStart.transactionId andDevice:keyVerificationStart.fromDevice];
    if (existingTransaction)
    {
        NSLog(@"[MXKeyVerification] handleStartEvent: already existing transaction. Cancel both");

        [existingTransaction cancelWithCancelCode:MXTransactionCancelCode.invalidMessage];
        [self cancelTransaction:keyVerificationStart.transactionId
                     fromUserId:event.sender
                      andDevice:keyVerificationStart.fromDevice
                           code:MXTransactionCancelCode.invalidMessage];
        return;
    }

    // TODO:
    // Multiple keyshares between two devices: any two devices may only have at most one key verification in flight at a time.
    // https://github.com/matrix-org/matrix-android-sdk/compare/feature/sas#diff-6798da25d58b7650862f263f51cb38e1R139

    // Make sure we have other device keys
    [self loadDeviceWithDeviceId:keyVerificationStart.fromDevice andUserId:event.sender success:^(MXDeviceInfo *otherDevice) {

        // We support only SAS at the moment
        MXIncomingSASTransaction *transaction = [[MXIncomingSASTransaction alloc] initWithOtherDevice:otherDevice startEvent:event andManager:self];
        if (transaction)
        {
            [self addTransaction:transaction];
        }
        else
        {
            NSLog(@"[MXKeyVerification] handleStartEvent: Unsupported transaction method: %@", event);

            [self cancelTransaction:keyVerificationStart.transactionId
                         fromUserId:event.sender
                          andDevice:keyVerificationStart.fromDevice
                               code:MXTransactionCancelCode.unknownMethod];
        }

    } failure:^(NSError *error) {
        NSLog(@"[MXKeyVerification] handleStartEvent: Failed to get other device keys: %@", event);

        [self cancelTransaction:keyVerificationStart.transactionId
                     fromUserId:event.sender
                      andDevice:keyVerificationStart.fromDevice
                           code:MXTransactionCancelCode.invalidMessage];
    }];
}

- (void)handleCancelEvent:(MXEvent*)event
{
    NSLog(@"[MXKeyVerification] handleCancelEvent");

    MXKeyVerificationCancel *cancelContent;
    MXJSONModelSetMXJSONModel(cancelContent, MXKeyVerificationCancel, event.content);

    if (cancelContent)
    {
        MXDeviceVerificationTransaction *transaction = [self transactionWithTransactionId:cancelContent.transactionId];
        if (transaction)
        {
            [transaction handleCancel:cancelContent];
            [self removeTransactionWithTransactionId:transaction.transactionId];
        }
        else
        {
            NSLog(@"[MXKeyVerification] handleCancelEvent. Unknown transaction: %@", event);
        }
    }
    else
    {
        NSLog(@"[MXKeyVerification] handleCancelEvent. Invalid event: %@", event);
    }
}

- (void)handleAcceptEvent:(MXEvent*)event
{
    NSLog(@"[MXKeyVerification] handleAcceptEvent");

    MXKeyVerificationAccept *acceptContent;
    MXJSONModelSetMXJSONModel(acceptContent, MXKeyVerificationAccept, event.content);

    if (acceptContent)
    {
        MXDeviceVerificationTransaction *transaction = [self transactionWithTransactionId:acceptContent.transactionId];
        if (transaction)
        {
            [transaction handleAccept:acceptContent];
        }
        else
        {
            NSLog(@"[MXKeyVerification] handleAcceptEvent. Unknown transaction: %@", event);
        }
    }
    else
    {
        NSLog(@"[MXKeyVerification] handleAcceptEvent. Invalid event: %@", event);
    }
}

- (void)handleKeyEvent:(MXEvent*)event
{
    NSLog(@"[MXKeyVerification] handleKeyEvent");

    MXKeyVerificationKey *keyContent;
    MXJSONModelSetMXJSONModel(keyContent, MXKeyVerificationKey, event.content);

    if (keyContent)
    {
        MXDeviceVerificationTransaction *transaction = [self transactionWithTransactionId:keyContent.transactionId];
        if (transaction)
        {
            [transaction handleKey:keyContent];
        }
        else
        {
            NSLog(@"[MXKeyVerification] handleKeyEvent. Unknown transaction: %@", event);
        }
    }
    else
    {
        NSLog(@"[MXKeyVerification] handleKeyEvent. Invalid event: %@", event);
    }
}

- (void)handleMacEvent:(MXEvent*)event
{
    NSLog(@"[MXKeyVerification] handleMacEvent");

    MXKeyVerificationMac *macContent;
    MXJSONModelSetMXJSONModel(macContent, MXKeyVerificationMac, event.content);

    if (macContent)
    {
        MXDeviceVerificationTransaction *transaction = [self transactionWithTransactionId:macContent.transactionId];
        if (transaction)
        {
            [transaction handleMac:macContent];
        }
        else
        {
            NSLog(@"[MXKeyVerification] handleMacEvent. Unknown transaction: %@", event);
        }
    }
    else
    {
        NSLog(@"[MXKeyVerification] handleMacEvent. Invalid event: %@", event);
    }
}


#pragma mark - Private methods -

- (void)loadDeviceWithDeviceId:(NSString*)deviceId
                     andUserId:(NSString*)userId
                       success:(void (^)(MXDeviceInfo *otherDevice))success
                       failure:(void (^)(NSError *error))failure
{
    MXWeakify(self);
    [_crypto downloadKeys:@[userId] forceDownload:NO success:^(MXUsersDevicesMap<MXDeviceInfo *> *usersDevicesInfoMap) {
        MXStrongifyAndReturnIfNil(self);

        dispatch_async(self->cryptoQueue, ^{
            MXDeviceInfo *otherDevice = [usersDevicesInfoMap objectForDevice:deviceId forUser:userId];
            if (otherDevice)
            {
                success(otherDevice);
            }
            else
            {
                NSError *error = [NSError errorWithDomain:kMXDeviceVerificationErrorDomain
                                                     code:MXDeviceVerificationUnknownDeviceCode
                                                 userInfo:@{
                                                            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unknown device: %@:%@", userId, deviceId]
                                                            }];
                failure(error);
            }
        });

    } failure:failure];
}

- (MXDeviceVerificationTransaction*)transactionWithUser:(NSString*)userId andDevice:(NSString*)deviceId
{
    return [transactions objectForDevice:deviceId forUser:userId];
}

- (NSArray<MXDeviceVerificationTransaction*>*)transactionsWithUser:(NSString*)userId
{
    return [transactions objectsForUser:userId];
}

- (MXDeviceVerificationTransaction*)transactionWithTransactionId:(NSString*)transactionId
{
    MXDeviceVerificationTransaction *transaction;
    for (MXDeviceVerificationTransaction *t in transactions.allObjects)
    {
        if ([t.transactionId isEqualToString:transactionId])
        {
            transaction = t;
            break;
        }
    }

    return transaction;
}

- (void)addTransaction:(MXDeviceVerificationTransaction*)transaction
{
    [transactions setObject:transaction forUser:transaction.otherUserId andDevice:transaction.otherDeviceId];

    dispatch_async(dispatch_get_main_queue(),^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kMXDeviceVerificationManagerNewTransactionNotification object:self userInfo:
         @{
           kMXDeviceVerificationManagerNotificationTransactionKey: transaction
           }];
    });
}

- (void)removeTransactionWithTransactionId:(NSString*)transactionId
{
    MXDeviceVerificationTransaction *transaction = [self transactionWithTransactionId:transactionId];
    if (transaction)
    {
        [transactions removeObjectForUser:transaction.otherUserId andDevice:transaction.otherDeviceId];
    }
}

@end
