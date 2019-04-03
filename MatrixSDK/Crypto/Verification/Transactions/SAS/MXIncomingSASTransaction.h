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

#import "MXSASTransaction.h"

#pragma mark - Constants

typedef enum : NSUInteger
{
    MXIncomingSASTransactionStateShowAccept = 0,
    MXIncomingSASTransactionStateWaitForPartnerKey,
    MXIncomingSASTransactionStateShowSAS,
    MXIncomingSASTransactionStateWaitForPartnerToConfirm,
    MXIncomingSASTransactionStateVerified,
    MXIncomingSASTransactionStateCancelled,
    MXIncomingSASTransactionStateNetworkError,
    MXIncomingSASTransactionStateError
} MXIncomingSASTransactionState;


NS_ASSUME_NONNULL_BEGIN

/**
 An handler on an incoming SAS device verification.
 */
@interface MXIncomingSASTransaction : MXSASTransaction

@property (nonatomic, readonly) MXIncomingSASTransactionState state;

/**
 Accept the device verification request.
 */
- (void)accept;

@end

NS_ASSUME_NONNULL_END
