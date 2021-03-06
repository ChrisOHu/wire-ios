// 
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
// 
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
// 
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
// 


#import "ConversationListContentController.h"

#import <PureLayout/PureLayout.h>
#import <Classy/Classy.h>

#import "zmessaging+iOS.h"
#import "ZMUserSession+iOS.h"
#import "ZMUserSession+Additions.h"

#import "ConversationListViewModel.h"

#import "WAZUIMagicIOS.h"
#import "UIColor+WAZExtensions.h"
#import "UIView+Borders.h"

#import "StopWatch.h"
#import "ProgressSpinner.h"

#import "ZClientViewController+Internal.h"

#import "ConversationListConnectRequestsItem.h"
#import "UIView+MTAnimation.h"
#import "ConversationListCollectionViewLayout.h"
#import "UIColor+WR_ColorScheme.h"

#import "ConnectRequestsCell.h"
#import "ConversationListCell.h"



static NSString * const CellReuseIdConversation = @"CellId";



@interface ConversationListContentController (VoiceChannel) <ZMVoiceChannelStateObserver>
@end



@interface ConversationListContentController () <ConversationListViewModelDelegate, UICollectionViewDelegateFlowLayout>

@property (nonatomic, strong) ConversationListViewModel *listViewModel;

@property (nonatomic) BOOL focusOnNextSelection;
@property (nonatomic) BOOL animateNextSelection;
@property (nonatomic, copy) dispatch_block_t selectConversationCompletion;

@property (nonatomic) ProgressSpinner *initialSyncSpinner;
@property (nonatomic) BOOL initialSyncCompleted;

@end

@interface ConversationListContentController (InitialSyncObserver) <ZMInitialSyncCompletionObserver>

@end

@interface ConversationListContentController (ConversationListCellDelegate) <ConversationListCellDelegate>

@end

@implementation ConversationListContentController

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [ZMUserSession removeInitalSyncCompletionObserver:self];
}

- (instancetype)init
{
    UICollectionViewFlowLayout *flowLayout = [[ConversationListCollectionViewLayout alloc] init];
    
    self = [super initWithCollectionViewLayout:flowLayout];
    if (self) {
        [ZMUserSession addInitalSyncCompletionObserver:self];
        self.initialSyncCompleted = [[[ZMUserSession sharedSession] initialSyncOnceCompleted] boolValue];
        StopWatch *stopWatch = [StopWatch stopWatch];
        StopWatchEvent *loadContactListEvent = [stopWatch stopEvent:@"LoadContactList"];
        if (loadContactListEvent) {
            DDLogDebug(@"Contact List load after %lums", (unsigned long)loadContactListEvent.elapsedTime);
        }
    }
    return self;
}

- (void)loadView
{
    [super loadView];
    
    self.listViewModel = [[ConversationListViewModel alloc] init];
    self.listViewModel.delegate = self;
    [self setupViews];
    [self createInitialConstraints];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    // This is here to ensure that the collection view is updated when going back to the list
    // from another view
    [self reload];
    [self scrollToCurrentSelectionAnimated:NO];
}

- (void)setupViews
{
    [self.collectionView registerClass:[ConnectRequestsCell class] forCellWithReuseIdentifier:self.listViewModel.contactRequestsItem.reuseIdentifier];
    [self.collectionView registerClass:[ConversationListCell class] forCellWithReuseIdentifier:CellReuseIdConversation];
    
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.alwaysBounceVertical = YES;
    self.collectionView.allowsSelection = YES;
    self.collectionView.allowsMultipleSelection = NO;
    self.clearsSelectionOnViewWillAppear = NO;
    
    self.initialSyncSpinner = [[ProgressSpinner alloc] initForAutoLayout];
    self.initialSyncSpinner.animating = ! self.initialSyncCompleted && [SessionObjectCache sharedCache].conversationList.count == 0;
    [self.view addSubview:self.initialSyncSpinner];
}

- (void)createInitialConstraints
{
     [self.initialSyncSpinner autoCenterInSuperview];
}

- (void)listViewModelShouldBeReloaded
{
    if (! self.initialSyncCompleted) {
        return;
    }

    [self reload];
}

- (void)listViewModel:(ConversationListViewModel *)model didUpdateSectionForReload:(NSUInteger)section
{
    if (! self.initialSyncCompleted) {
        return;
    }

    [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:section]];
    [self ensureCurrentSelection];
}

- (void)listViewModel:(ConversationListViewModel *)model didUpdateSection:(NSUInteger)section usingBlock:(dispatch_block_t)updateBlock withChangedIndexes:(ZMChangedIndexes *)changedIndexes
{
    if (! self.initialSyncCompleted) {
        return;
    }

    // NOTE: we ignore all "update" notifications, since we get too many (it breaks the collection view) and they
    // are unnecessary since the cells update themselves.
    
    // If we are about to delete the currently selected conversation, select a different one
    NSArray *selectedItems = [self.collectionView indexPathsForSelectedItems];
    [selectedItems enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        NSIndexPath *selectedIndexPath = obj;
        [changedIndexes.deletedIndexes enumerateIndexesWithOptions:0 usingBlock:^(NSUInteger idx, BOOL *stop) {
            if (selectedIndexPath.section == (NSInteger)section && selectedIndexPath.item == (NSInteger)idx) {
                // select a different conversation
                dispatch_async(dispatch_get_main_queue(), ^{
                    
                        BOOL activeCallConversationIsSelected = [[[SessionObjectCache sharedCache] activeCallConversations] firstObject] == self.listViewModel.selectedItem;
                    
                    if (! activeCallConversationIsSelected) {
                        [self selectListItemAfterRemovingIndex:selectedIndexPath.item section:selectedIndexPath.section];
                    }
                });
            }
        }];
    }];
    
    [self.collectionView performBatchUpdates:^{
        
        if (updateBlock) {
            updateBlock();
        }
        
        // Delete
        if (changedIndexes.deletedIndexes.count > 0) {
            [self.collectionView deleteItemsAtIndexPaths:[[self class] indexPathsForIndexes:changedIndexes.deletedIndexes inSection:section]];
        }
        
        // Insert
        if (changedIndexes.insertedIndexes.count > 0) {
            [self.collectionView insertItemsAtIndexPaths:[[self class] indexPathsForIndexes:changedIndexes.insertedIndexes inSection:section]];
        }
        
        // Move
        [changedIndexes enumerateMovedIndexes:^(NSUInteger from, NSUInteger to) {
            NSIndexPath *fromIndexPath = [NSIndexPath indexPathForItem:from inSection:section];
            NSIndexPath *toIndexPath = [NSIndexPath indexPathForItem:to inSection:section];
            
            [self.collectionView moveItemAtIndexPath:fromIndexPath toIndexPath:toIndexPath];
        }];
    } completion:^(BOOL finished) {
        [self ensureCurrentSelection];
    }];
}

- (void)listViewModel:(ConversationListViewModel *)model didSelectItem:(id)item
{
    if (item == nil) {
        // Deselect all items in the collection view
        NSArray *indexPaths = [self.collectionView indexPathsForSelectedItems];
        [indexPaths enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            [self.collectionView deselectItemAtIndexPath:obj animated:NO];
        }];
        [[ZClientViewController sharedZClientViewController] loadPlaceholderConversationControllerAnimated:YES];
    }
    else {
        
        if ([item isKindOfClass:[ZMConversation class]]) {
            
            ZMConversation *conversation = item;
            
            // Actually load the new view controller and optionally focus on it
            [[ZClientViewController sharedZClientViewController] loadConversation:conversation
                                                                      focusOnView:self.focusOnNextSelection
                                                                         animated:self.animateNextSelection
                                                                       completion:self.selectConversationCompletion];
            self.selectConversationCompletion = nil;
            
            [self.contentDelegate conversationList:self didSelectConversation:item focusOnView:! self.focusOnNextSelection];
        }
        else if ([item isKindOfClass:[ConversationListConnectRequestsItem class]]) {
            [[ZClientViewController sharedZClientViewController] loadIncomingContactRequestsAndFocusOnView:self.focusOnNextSelection animated:YES];
            [self.contentDelegate conversationList:self didSelectInteractiveItem:item focusOnView:! self.focusOnNextSelection];
        }
        else {
            NSAssert(NO, @"Invalid item in conversation list view model!!");
        }
        // Make sure the correct item is selected in the list, without triggering a collection view
        // callback
        [self ensureCurrentSelection];
    }
    
    self.focusOnNextSelection = NO;
}

- (void)listViewModel:(ConversationListViewModel *)model didUpdateConversationWithChange:(ConversationChangeInfo *)change
{
    if (! self.initialSyncCompleted) {
        return;
    }

    if (change.isArchivedChanged ||
        change.conversationListIndicatorChanged ||
        change.nameChanged ||
        change.unreadCountChanged ||
        change.connectionStateChanged ||
        change.isSilencedChanged) {
        
        for (UICollectionViewCell *cell in self.collectionView.visibleCells) {
            if ([cell isKindOfClass:[ConversationListCell class]]) {
                ConversationListCell *convListCell = (ConversationListCell *)cell;
                
                if ([convListCell.conversation isEqual:change.conversation]) {
                    [convListCell updateAppearance];
                }
            }
        }
    }
}

- (BOOL)selectConversation:(ZMConversation *)conversation focusOnView:(BOOL)focus animated:(BOOL)animated
{
    return [self selectConversation:conversation focusOnView:focus animated:animated completion:nil];
}

- (BOOL)selectConversation:(ZMConversation *)conversation focusOnView:(BOOL)focus animated:(BOOL)animated completion:(dispatch_block_t)completion
{
    self.focusOnNextSelection = focus;

    self.selectConversationCompletion = completion;
    self.animateNextSelection = animated;
    
    // Tell the model to select the item
    return [self selectModelItem:conversation];
}

- (BOOL)selectInboxAndFocusOnView:(BOOL)focus
{
    // If there is anything in the inbox, select it
    if ([self.listViewModel numberOfItemsInSection:0] > 0) {
        
        self.focusOnNextSelection = focus;
        [self selectModelItem:self.listViewModel.contactRequestsItem];
        return YES;
    }
    return NO;
}

- (void)setInitialSyncCompleted:(BOOL)initialSyncCompleted
{
    BOOL shouldReload = _initialSyncCompleted == NO && initialSyncCompleted == YES;
    _initialSyncCompleted = initialSyncCompleted;
    if (shouldReload) {
        [self reload];
    }
}

- (BOOL)selectModelItem:(id)itemToSelect
{
    if([itemToSelect isKindOfClass:[ZMConversation class]]) {
        
        ZMConversation *conversation = (ZMConversation *)itemToSelect;
        StopWatch *stopWatch = [StopWatch stopWatch];
        [stopWatch restartEvent:[NSString stringWithFormat:@"ConversationSelect%@", conversation.displayName]];
    }
    
    return [self.listViewModel selectItem:itemToSelect];
}

- (void)deselectAll
{
    [self selectModelItem:nil];
}

/**
 * ensures that the list selection state matches that of the model.
 */
- (void)ensureCurrentSelection
{
    if (self.listViewModel.selectedItem == nil) {
        return;
    }
    
    NSArray *selectedIndexPaths = [self.collectionView indexPathsForSelectedItems];
    NSIndexPath *currentIndexPath = [self.listViewModel indexPathForItem:self.listViewModel.selectedItem];
    
    if (! [selectedIndexPaths containsObject:currentIndexPath] && currentIndexPath != nil) {
        // This method doesn't trigger any delegate callbacks, so no worries about special handling
        [self.collectionView selectItemAtIndexPath:currentIndexPath animated:NO scrollPosition:UICollectionViewScrollPositionNone];
    }
}

- (void)scrollToCurrentSelectionAnimated:(BOOL)animated
{
    NSIndexPath *selectedIndexPath = [self.listViewModel indexPathForItem:self.listViewModel.selectedItem];
    
    if (selectedIndexPath != nil) {
        // Check if indexPath is valid for the collection view
        if (self.collectionView.numberOfSections > selectedIndexPath.section &&
            [self.collectionView numberOfItemsInSection:selectedIndexPath.section] > selectedIndexPath.item) {
            // Check for visibility
            NSArray *visibleIndexPaths = self.collectionView.indexPathsForVisibleItems;
            if (visibleIndexPaths.count > 0 && ! [visibleIndexPaths containsObject:selectedIndexPath]) {
                [self.collectionView scrollToItemAtIndexPath:selectedIndexPath atScrollPosition:UICollectionViewScrollPositionNone animated:animated];
            }
        }
    }
}

/**
 * Selects a new list item if the current selection is removed.
 */
- (void)selectListItemAfterRemovingIndex:(NSUInteger)index section:(NSUInteger)sectionIndex
{
    // Select the next item after the item previous to the one that was deleted (important!)
    NSIndexPath *itemIndex = [self.listViewModel itemAfterIndex:index-1 section:sectionIndex];
    
    if (itemIndex == nil) {
        // we are at the bottom, so go backwards instead
        itemIndex = [self.listViewModel itemPreviousToIndex:index section:sectionIndex];
    }
    
    if (itemIndex != nil) {
        [self.contentDelegate conversationList:self willSelectIndexPathAfterSelectionDeleted:itemIndex];
        [self.listViewModel selectItemAtIndexPath:itemIndex];
    } else { //nothing to select anymore, we select nothing
        [self.listViewModel selectItem:nil];
    }
}

- (void)reload
{
    if (! self.initialSyncCompleted) {
        return;
    }
    
    [self.collectionView reloadData];
    [self ensureCurrentSelection];
    
    // we MUST call layoutIfNeeded here because otherwise bad things happen when we close the archive, reload the conv
    // and then unarchive all at the same time
    [self.view layoutIfNeeded];
}

- (void)setEnableSubtitles:(BOOL)enableSubtitles
{
    _enableSubtitles = enableSubtitles;
    [self.collectionView reloadData];
}

#pragma mark - Custom

+ (NSArray *)indexPathsForIndexes:(NSIndexSet *)indexes inSection:(NSUInteger)section
{
    __block NSMutableArray * result = [NSMutableArray arrayWithCapacity:indexes.count];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        [result addObject:[NSIndexPath indexPathForItem:idx inSection:section]];
    }];
    return result;
}

@end



@implementation ConversationListContentController (UICollectionViewDataSource)

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView
{
    [self.collectionView.collectionViewLayout invalidateLayout];
    NSInteger sections = self.listViewModel.sectionCount;
    return sections;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    NSInteger c = [self.listViewModel numberOfItemsInSection:section];
    return c;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    id item = [self.listViewModel itemForIndexPath:indexPath];
    UICollectionViewCell *cell = nil;

    if ([item isKindOfClass:[ConversationListInteractiveItem class]]) {
        ConversationListInteractiveItem *customItem = (ConversationListInteractiveItem *)item;
        ConnectRequestsCell *labelCell = [self.collectionView dequeueReusableCellWithReuseIdentifier:customItem.reuseIdentifier forIndexPath:indexPath];
        [customItem featureCell:cell];
        cell = labelCell;
    }
    else if ([item isKindOfClass:[ZMConversation class]]) {
        ConversationListCell *listCell = [self.collectionView dequeueReusableCellWithReuseIdentifier:CellReuseIdConversation forIndexPath:indexPath];
        listCell.delegate = self;
        listCell.mutuallyExclusiveSwipeIdentifier = @"ConversationList";
        listCell.conversation = item;
        cell = listCell;
    }

    cell.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    return cell;
}

@end



@implementation ConversationListContentController (UICollectionViewDelegate)

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    id item = [self.listViewModel itemForIndexPath:indexPath];
    
    self.focusOnNextSelection = YES;
    self.animateNextSelection = YES;
    [self selectModelItem:item];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    // Close open drawers in the cells
    [[NSNotificationCenter defaultCenter] postNotificationName:SwipeMenuCollectionCellCloseDrawerNotification object:nil];
    if ([self.contentDelegate respondsToSelector:@selector(conversationListDidScroll:)]) {
        [self.contentDelegate conversationListDidScroll:self];
    }
}

@end



@implementation ConversationListContentController (UICollectionViewDelegateFlowLayout)

- (UIEdgeInsets)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout*)collectionViewLayout insetForSectionAtIndex:(NSInteger)section
{
    if (section == 0) {
        return UIEdgeInsetsMake(32, 0, 0, 0);
    }
    return UIEdgeInsetsZero;
}

@end

@implementation ConversationListContentController (InitialSyncObserver)

- (void)initialSyncCompleted:(NSNotification *)notification
{
    self.initialSyncSpinner.animating = NO;
    [self.listViewModel updateSection:SectionIndexAll];
    self.initialSyncCompleted = YES;
}

@end

@implementation ConversationListContentController (ConversationListCellDelegate)

- (void)conversationListCellOverscrolled:(ConversationListCell *)cell
{
    ZMConversation *conversation = cell.conversation;
    if (! conversation) {
        return;
    }
    
    if ([self.contentDelegate respondsToSelector:@selector(conversationListContentController:wantsActionMenuForConversation:)]) {
        [self.contentDelegate conversationListContentController:self wantsActionMenuForConversation:conversation];
    }
}

@end
