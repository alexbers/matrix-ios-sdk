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


#import <Foundation/Foundation.h>

#import "MXTransactionCancelCode.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Constants

/**
 Notification sent when the transaction has been updated.
 */
FOUNDATION_EXPORT NSString * _Nonnull const MXDeviceVerificationTransactionDidChangeNotification;


/**
 An handler on an interactive device verification.
 */
@interface MXDeviceVerificationTransaction: NSObject

/**
 The transaction id.
 */
@property (nonatomic, readonly) NSString *transactionId;

/**
 The other user id.
 */
@property (nonatomic, readonly) NSString *otherUser;

/**
 The other user device id.
 */
@property (nonatomic, readonly) NSString *otherDevice;

/**
 The cancellation reason, if any.
 */
@property (nonatomic, nullable) MXTransactionCancelCode *cancelCode;

/**
 Cancel this transaction.

 @param code the cancellation reason
 */
- (void)cancelWithCancelCode:(MXTransactionCancelCode*)code;

@end

NS_ASSUME_NONNULL_END
