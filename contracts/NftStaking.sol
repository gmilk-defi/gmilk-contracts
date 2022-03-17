// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./libs/ReentrancyGuard.sol";
import "./libs/Pausable.sol";
import "./libs/IERC721.sol";
import "./libs/IERC721Receiver.sol";
import "./libs/EnumerableSet.sol";
import "./libs/SafeMath.sol";
import "./libs/SafeERC20.sol";
import "./libs/MerkleProof.sol";

contract NftStaking is ReentrancyGuard, Pausable, IERC721Receiver {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.UintSet;
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    enum Rarity {
        COMMON,
        RARE,
        ICONIC,
        GOLDEN
    }

    enum StakeType {
        UNLOCKED,
        LOCKED,
        PAIR_LOCKED
    }

    bytes32 public SEASON1_MERKLE_ROOT;
    bytes32 public SEASON2_MERKLE_ROOT;

    /** Season1 / Season2 NFT address */
    address public _season1Nft;
    address public _season2Nft;
    /** Reward Token address */
    address public _rewardToken;

    // Withdraw lock period
    uint256 public _lockPeriod = 60 days; // Lock period 60 days
    uint16 public _unstakeFee = 500; // Unstake fee 5%
    uint16 public _forcedUnstakeFee = 10000; // Force unstake fee 100%

    struct NftStakeInfo {
        Rarity _rarity;
        bool _isLocked;
        uint256 _pairedTokenId;
        uint256 _stakedAt;
    }

    struct UserInfo {
        EnumerableSet.UintSet _season1Nfts;
        EnumerableSet.UintSet _season2Nfts;
        mapping(uint256 => NftStakeInfo) _season1StakeInfos;
        mapping(uint256 => NftStakeInfo) _season2StakeInfos;
        uint256 _pending; // Not claimed
        uint256 _totalClaimed; // Claimed so far
        uint256 _lastClaimedAt;
        uint256 _pairCount; // Paired count
    }

    mapping(Rarity => uint256) _season1BaseRpds; // RPD: reward per day
    mapping(Rarity => uint16) _season1LockedExtras;
    mapping(Rarity => mapping(StakeType => uint16)) _season2Extras;

    // Info of each user that stakes LP tokens.
    mapping(address => UserInfo) private _userInfo;

    event Staked(
        address indexed account,
        uint256 tokenId,
        bool isSeason1,
        bool isLocked
    );
    event Unstaked(address indexed account, uint256 tokenId, bool isSeason1);
    event Locked(address indexed account, uint256 tokenId, bool isSeason1);
    event Paired(
        address indexed account,
        uint256 season1TokenId,
        uint256 season2TokenId
    );
    event Harvested(address indexed account, uint256 amount);
    event InsufficientRewardToken(
        address indexed account,
        uint256 amountNeeded,
        uint256 balance
    );

    constructor(address __rewardToken, address __season1Nft) {
        IERC20(__rewardToken).balanceOf(address(this));
        IERC721(__season1Nft).balanceOf(address(this));

        _rewardToken = __rewardToken;
        _season1Nft = __season1Nft;

        // Base reward per day
        _season1BaseRpds[Rarity.COMMON] = 50 ether;
        _season1BaseRpds[Rarity.RARE] = 125 ether;
        _season1BaseRpds[Rarity.ICONIC] = 250 ether;

        // Season1 locked cases extra percentage
        _season1LockedExtras[Rarity.COMMON] = 2000; // 20%
        _season1LockedExtras[Rarity.COMMON] = 2000; // 20%
        _season1LockedExtras[Rarity.COMMON] = 2000; // 20%

        // Season2 extra percentage
        _season2Extras[Rarity.COMMON][StakeType.UNLOCKED] = 1000;
        _season2Extras[Rarity.COMMON][StakeType.LOCKED] = 2000;
        _season2Extras[Rarity.COMMON][StakeType.PAIR_LOCKED] = 5000;
        _season2Extras[Rarity.RARE][StakeType.UNLOCKED] = 2000;
        _season2Extras[Rarity.RARE][StakeType.LOCKED] = 2000;
        _season2Extras[Rarity.RARE][StakeType.PAIR_LOCKED] = 5000;
        _season2Extras[Rarity.ICONIC][StakeType.UNLOCKED] = 3500;
        _season2Extras[Rarity.ICONIC][StakeType.LOCKED] = 2000;
        _season2Extras[Rarity.ICONIC][StakeType.PAIR_LOCKED] = 5000;
        _season2Extras[Rarity.GOLDEN][StakeType.UNLOCKED] = 5000;
        _season2Extras[Rarity.GOLDEN][StakeType.LOCKED] = 2000;
        _season2Extras[Rarity.GOLDEN][StakeType.PAIR_LOCKED] = 5000;
    }

    function setSeason2Nft(address __season2Nft) external onlyOwner {
        IERC721(__season2Nft).balanceOf(address(this));
        _season2Nft = __season2Nft;
    }

    function getRewardInNormal(
        uint256 __rpd,
        uint256 __stakedAt,
        uint256 __lastClaimedAt
    ) private view returns (uint256) {
        uint256 timePassed = __stakedAt > __lastClaimedAt
            ? block.timestamp.sub(__stakedAt)
            : block.timestamp.sub(__lastClaimedAt);
        return __rpd.mul(timePassed).div(1 days);
    }

    function getRewardInLocked(
        uint256 __rpd,
        uint256 __extraRate,
        uint256 __stakedAt,
        uint256 __lastClaimedAt
    ) private view returns (uint256 lockedAmount, uint256 unlockedAmount) {
        uint256 lockEndAt = __stakedAt.add(_lockPeriod);
        if (lockEndAt > block.timestamp) {
            lockedAmount = __rpd
                .mul(block.timestamp.sub(__stakedAt))
                .mul(uint256(10000).add(__extraRate))
                .div(10000)
                .div(1 days);
        } else {
            uint256 timePassed = __lastClaimedAt >= lockEndAt
                ? block.timestamp.sub(__lastClaimedAt)
                : block.timestamp.sub(__stakedAt);
            unlockedAmount = __rpd
                .mul(timePassed)
                .mul(uint256(10000).add(__extraRate))
                .div(10000)
                .div(1 days);
        }
    }

    function getSeason1Rewards(address __account, uint256 __nftId)
        private
        view
        returns (uint256 lockedAmount, uint256 unlockedAmount)
    {
        UserInfo storage user = _userInfo[__account];
        NftStakeInfo storage season1StakeInfo = user._season1StakeInfos[
            __nftId
        ];
        Rarity season1Rarity = season1StakeInfo._rarity;
        uint256 baseRpd = _season1BaseRpds[season1Rarity];

        // For the locked staking add extra percentage
        if (season1StakeInfo._isLocked) {
            (lockedAmount, unlockedAmount) = getRewardInLocked(
                baseRpd,
                _season1LockedExtras[season1Rarity],
                season1StakeInfo._stakedAt,
                user._lastClaimedAt
            );
        } else {
            unlockedAmount = getRewardInNormal(
                baseRpd,
                season1StakeInfo._stakedAt,
                user._lastClaimedAt
            );
        }
    }

    function getPairedSeason2Rewards(address __account, uint256 __nftId)
        private
        view
        returns (uint256 lockedAmount, uint256 unlockedAmount)
    {
        UserInfo storage user = _userInfo[__account];
        NftStakeInfo storage season1StakeInfo = user._season1StakeInfos[
            __nftId
        ];
        NftStakeInfo storage season2StakeInfo = user._season2StakeInfos[
            season1StakeInfo._pairedTokenId
        ];
        Rarity season1Rarity = season1StakeInfo._rarity;
        Rarity season2Rarity = season2StakeInfo._rarity;
        uint256 baseRpd = _season1BaseRpds[season1Rarity];
        if (season1StakeInfo._pairedTokenId == 0) {
            lockedAmount = 0;
            unlockedAmount = 0;
        } else if (season2StakeInfo._isLocked) {
            // extra rate is wheter season1 is locked or not
            uint256 rpdExtraRate = season1StakeInfo._isLocked
                ? _season2Extras[season2Rarity][StakeType.PAIR_LOCKED]
                : _season2Extras[season2Rarity][StakeType.LOCKED];
            (lockedAmount, unlockedAmount) = getRewardInLocked(
                baseRpd,
                rpdExtraRate,
                season2StakeInfo._stakedAt,
                user._lastClaimedAt
            );
        } else {
            // base rpd for the season2 unlocked
            baseRpd = baseRpd
                .mul(_season2Extras[season2Rarity][StakeType.UNLOCKED])
                .div(10000);
            unlockedAmount = getRewardInNormal(
                baseRpd,
                season2StakeInfo._stakedAt,
                user._lastClaimedAt
            );
        }
    }

    function viewProfit(address __account)
        public
        view
        returns (
            uint256 totalEarned,
            uint256 totalClaimed,
            uint256 lockedRewards,
            uint256 unlockedRewards
        )
    {
        UserInfo storage user = _userInfo[__account];
        totalClaimed = user._totalClaimed;
        unlockedRewards = user._pending;

        uint256 countSeason1Nfts = user._season1Nfts.length();
        uint256 index;
        for (index = 0; index < countSeason1Nfts; index++) {
            uint256 pendingLockedRewards = 0;
            uint256 pendingUnlockedRewards = 0;

            (pendingLockedRewards, pendingUnlockedRewards) = getSeason1Rewards(
                __account,
                user._season1Nfts.at(index)
            );

            // Add season1 reward
            if (pendingLockedRewards > 0) {
                lockedRewards = lockedRewards.add(pendingLockedRewards);
            }
            if (pendingUnlockedRewards > 0) {
                unlockedRewards = unlockedRewards.add(pendingUnlockedRewards);
            }

            (
                pendingLockedRewards,
                pendingUnlockedRewards
            ) = getPairedSeason2Rewards(__account, user._season1Nfts.at(index));

            // Add season2 reward
            if (pendingLockedRewards > 0) {
                lockedRewards = lockedRewards.add(pendingLockedRewards);
            }
            if (pendingUnlockedRewards > 0) {
                unlockedRewards = unlockedRewards.add(pendingUnlockedRewards);
            }
        }

        totalEarned = totalClaimed.add(lockedRewards).add(unlockedRewards);
    }

    /**
     * @notice Get season1 nfts
     */
    function viewSeason1Nfts(address __account)
        external
        view
        returns (uint256[] memory season1Nfts, bool[] memory lockStats)
    {
        UserInfo storage user = _userInfo[__account];
        uint256 countSeason1Nfts = user._season1Nfts.length();

        season1Nfts = new uint256[](countSeason1Nfts);
        lockStats = new bool[](countSeason1Nfts);
        uint256 index;
        uint256 tokenId;
        for (index = 0; index < countSeason1Nfts; index++) {
            tokenId = user._season1Nfts.at(index);
            season1Nfts[index] = tokenId;
            lockStats[index] = user._season1StakeInfos[tokenId]._isLocked;
        }
    }

    /**
     * @notice Get season2 nfts
     */
    function viewSeason2Nfts(address __account)
        external
        view
        returns (uint256[] memory season2Nfts, bool[] memory lockStats)
    {
        UserInfo storage user = _userInfo[__account];
        uint256 countSeason2Nfts = user._season2Nfts.length();

        season2Nfts = new uint256[](countSeason2Nfts);
        lockStats = new bool[](countSeason2Nfts);
        uint256 index;
        uint256 tokenId;
        for (index = 0; index < countSeason2Nfts; index++) {
            tokenId = user._season2Nfts.at(index);
            season2Nfts[index] = tokenId;
            lockStats[index] = user._season2StakeInfos[tokenId]._isLocked;
        }
    }

    /**
     * @notice Get paired season1 / season2 nfts
     */
    function viewPairedNfts(address __account)
        external
        view
        returns (
            uint256[] memory pairedSeason1Nfts,
            uint256[] memory pairedSeason2Nfts
        )
    {
        UserInfo storage user = _userInfo[__account];
        uint256 pairCount = user._pairCount;
        pairedSeason1Nfts = new uint256[](pairCount);
        pairedSeason2Nfts = new uint256[](pairCount);
        uint256 index;
        uint256 tokenId;
        uint256 rindex = 0;
        uint256 season2NftCount = user._season2Nfts.length();
        for (index = 0; index < season2NftCount; index++) {
            tokenId = user._season2Nfts.at(index);
            if (user._season2StakeInfos[tokenId]._pairedTokenId == 0) {
                continue;
            }
            pairedSeason1Nfts[rindex] = user
                ._season2StakeInfos[tokenId]
                ._pairedTokenId;
            pairedSeason2Nfts[rindex] = tokenId;
            rindex = rindex.add(1);
        }
    }

    // Verify that a given leaf is in the tree.
    function isWhiteListedSeason1(bytes32 _leafNode, bytes32[] memory _proof)
        public
        view
        returns (bool)
    {
        return MerkleProof.verify(_proof, SEASON1_MERKLE_ROOT, _leafNode);
    }

    function isWhiteListedSeason2(bytes32 _leafNode, bytes32[] memory _proof)
        public
        view
        returns (bool)
    {
        return MerkleProof.verify(_proof, SEASON2_MERKLE_ROOT, _leafNode);
    }

    // Generate the leaf node (just the hash of tokenID concatenated with the account address)
    function toLeaf(
        uint256 tokenID,
        uint256 index,
        uint256 amount
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(index, tokenID, amount));
    }

    function setMerkleRoot(bytes32 _season1Root, bytes32 _season2Root)
        external
        onlyOwner
    {
        SEASON1_MERKLE_ROOT = _season1Root;
        SEASON2_MERKLE_ROOT = _season2Root;
    }

    function updateFeeValues(uint16 __unstakeFee, uint16 __forcedUnstakeFee)
        external
        onlyOwner
    {
        _unstakeFee = __unstakeFee;
        _forcedUnstakeFee = __forcedUnstakeFee;
    }

    function updateLockPeriod(uint256 __lockPeriod) external onlyOwner {
        require(__lockPeriod > 0, "Invalid lock period");
        _lockPeriod = __lockPeriod;
    }

    function updateSeason1BaseRpd(Rarity __rarity, uint256 __rpd)
        external
        onlyOwner
    {
        require(__rpd > 0, "Non zero values required");
        _season1BaseRpds[__rarity] = __rpd;
    }

    function updateSeason1LockedExtraPercent(
        Rarity __rarity,
        uint16 __lockedExtraPercent
    ) external onlyOwner {
        _season1LockedExtras[__rarity] = __lockedExtraPercent;
    }

    function updateSeason2ExtraPercent(
        Rarity __rarity,
        StakeType __stakeType,
        uint16 __extraPercent
    ) external onlyOwner {
        _season2Extras[__rarity][__stakeType] = __extraPercent;
    }

    function isStaked(address __account, uint256 __tokenId)
        external
        view
        returns (bool)
    {
        UserInfo storage user = _userInfo[__account];
        return
            user._season1Nfts.contains(__tokenId) ||
            user._season2Nfts.contains(__tokenId);
    }

    /**
     * @notice Claim rewards
     */
    function claimRewards() external {
        UserInfo storage user = _userInfo[_msgSender()];
        (, , , uint256 unlockedRewards) = viewProfit(_msgSender());
        if (unlockedRewards > 0) {
            uint256 feeAmount = unlockedRewards.mul(_unstakeFee).div(10000);
            if (feeAmount > 0) {
                IERC20(_rewardToken).safeTransfer(DEAD, feeAmount);
                unlockedRewards = unlockedRewards.sub(feeAmount);
            }
            if (unlockedRewards > 0) {
                user._totalClaimed = user._totalClaimed.add(unlockedRewards);
                IERC20(_rewardToken).safeTransfer(_msgSender(), unlockedRewards);
            }
        }
        user._lastClaimedAt = block.timestamp;
    }

    /**
     * @notice Stake season1 nft
     */
    function stakeSeason1(
        bool __lockedStaking,
        uint256[] calldata __tokenIDList,
        uint256[] calldata __indexList,
        uint256[] calldata __rarityList,
        bytes32[][] calldata __proofList
    ) external nonReentrant whenNotPaused {
        require(
            IERC721(_season1Nft).isApprovedForAll(_msgSender(), address(this)),
            "Not approve nft to staker address"
        );

        UserInfo storage user = _userInfo[_msgSender()];
        for (uint256 i = 0; i < __tokenIDList.length; i++) {
            // Check if the params are correct
            require(
                isWhiteListedSeason1(
                    toLeaf(__tokenIDList[i], __indexList[i], __rarityList[i]),
                    __proofList[i]
                ),
                "Invalid params"
            );

            IERC721(_season1Nft).safeTransferFrom(
                _msgSender(),
                address(this),
                __tokenIDList[i]
            );

            user._season1Nfts.add(__tokenIDList[i]);
            user._season1StakeInfos[__tokenIDList[i]] = NftStakeInfo({
                _rarity: Rarity(__rarityList[i]),
                _isLocked: __lockedStaking,
                _stakedAt: block.timestamp,
                _pairedTokenId: 0
            });

            emit Staked(_msgSender(), __tokenIDList[i], true, __lockedStaking);
        }
    }

    /**
     * @notice Stake season2 nft
     */
    function stakeSeason2(
        bool __lockedStaking,
        uint256[] calldata __tokenIDList,
        uint256[] calldata __indexList,
        uint256[] calldata __rarityList,
        bytes32[][] calldata __proofList
    ) external nonReentrant whenNotPaused {
        require(
            IERC721(_season2Nft).isApprovedForAll(_msgSender(), address(this)),
            "Not approve nft to staker address"
        );

        UserInfo storage user = _userInfo[_msgSender()];
        for (uint256 i = 0; i < __tokenIDList.length; i++) {
            // Check if the params are correct
            require(
                isWhiteListedSeason2(
                    toLeaf(__tokenIDList[i], __indexList[i], __rarityList[i]),
                    __proofList[i]
                ),
                "Invalid params"
            );

            IERC721(_season2Nft).safeTransferFrom(
                _msgSender(),
                address(this),
                __tokenIDList[i]
            );

            user._season2Nfts.add(__tokenIDList[i]);
            user._season2StakeInfos[__tokenIDList[i]] = NftStakeInfo({
                _rarity: Rarity(__rarityList[i]),
                _isLocked: __lockedStaking,
                _stakedAt: block.timestamp,
                _pairedTokenId: 0
            });

            emit Staked(_msgSender(), __tokenIDList[i], false, __lockedStaking);
        }
    }

    function unstakeSeason1(uint256[] calldata __tokenIDList)
        external
        nonReentrant
    {
        UserInfo storage user = _userInfo[_msgSender()];
        for (uint256 i = 0; i < __tokenIDList.length; i++) {
            require(
                user._season1Nfts.contains(__tokenIDList[i]),
                "Not staked one of nfts"
            );

            IERC721(_season1Nft).safeTransferFrom(
                address(this),
                _msgSender(),
                __tokenIDList[i]
            );

            // locked rewards are sent to rewards back to the pool
            // unlocked rewards are added to the user rewards
            (, uint256 unlockedRewards) = getSeason1Rewards(
                _msgSender(),
                __tokenIDList[i]
            );
            user._pending = user._pending.add(unlockedRewards);

            user._season1Nfts.remove(__tokenIDList[i]);
            // If it was paired with a season2 nft, unpair them
            uint256 pairedTokenId = user
                ._season1StakeInfos[__tokenIDList[i]]
                ._pairedTokenId;
            if (pairedTokenId > 0) {
                user._season2StakeInfos[pairedTokenId]._pairedTokenId = 0;
                user._pairCount = user._pairCount.sub(1);
            }

            delete user._season1StakeInfos[__tokenIDList[i]];

            emit Unstaked(_msgSender(), __tokenIDList[i], true);
        }
    }

    function unstakeSeason2(uint256[] calldata __tokenIDList)
        external
        nonReentrant
    {
        UserInfo storage user = _userInfo[_msgSender()];
        for (uint256 i = 0; i < __tokenIDList.length; i++) {
            require(
                user._season2Nfts.contains(__tokenIDList[i]),
                "Not staked one of nfts"
            );

            IERC721(_season2Nft).safeTransferFrom(
                address(this),
                _msgSender(),
                __tokenIDList[i]
            );

            // If it was paired with a season1 nft, unpair them
            uint256 pairedTokenId = user
                ._season2StakeInfos[__tokenIDList[i]]
                ._pairedTokenId;

            if (pairedTokenId > 0) {
                // locked rewards are sent to rewards back to the pool
                // unlocked rewards are added to the user rewards
                (, uint256 unlockedRewards) = getPairedSeason2Rewards(
                    _msgSender(),
                    pairedTokenId
                );
                user._pending = user._pending.add(unlockedRewards);
            }

            user._season2Nfts.remove(__tokenIDList[i]);

            if (pairedTokenId > 0) {
                user._season1StakeInfos[pairedTokenId]._pairedTokenId = 0;
                user._pairCount = user._pairCount.sub(1);
            }
            delete user._season2StakeInfos[__tokenIDList[i]];

            emit Unstaked(_msgSender(), __tokenIDList[i], false);
        }
    }

    /**
     * @notice Lock season1 nft from the unlocked pool to the lock pool
     */
    function lockSeason1Nfts(uint256[] calldata __tokenIDList)
        external
        onlyOwner
    {
        UserInfo storage user = _userInfo[_msgSender()];
        for (uint256 i = 0; i < __tokenIDList.length; i++) {
            // Check if the params are correct
            require(
                user._season1Nfts.contains(__tokenIDList[i]),
                "One of nfts not staked yet"
            );
            require(
                !user._season1StakeInfos[__tokenIDList[i]]._isLocked,
                "Locked already"
            );
            (, uint256 unlockedRewards) = getSeason1Rewards(
                _msgSender(),
                __tokenIDList[i]
            );
            user._pending = user._pending.add(unlockedRewards);

            user._season1StakeInfos[__tokenIDList[i]]._isLocked = true;
            user._season1StakeInfos[__tokenIDList[i]]._stakedAt = block
                .timestamp;
            emit Locked(_msgSender(), __tokenIDList[i], true);
        }
    }

    /**
     * @notice Lock season2 nft from the unlocked pool to the lock pool
     */
    function lockSeason2Nfts(uint256[] calldata __tokenIDList)
        external
        onlyOwner
    {
        UserInfo storage user = _userInfo[_msgSender()];
        for (uint256 i = 0; i < __tokenIDList.length; i++) {
            // Check if the params are correct
            require(
                user._season2Nfts.contains(__tokenIDList[i]),
                "One of nfts not staked yet"
            );
            require(
                !user._season2StakeInfos[__tokenIDList[i]]._isLocked,
                "Locked already"
            );
            uint256 pairedTokenId = user
                ._season2StakeInfos[__tokenIDList[i]]
                ._pairedTokenId;

            if (pairedTokenId > 0) {
                (, uint256 unlockedRewards) = getPairedSeason2Rewards(
                    _msgSender(),
                    pairedTokenId
                );
                user._pending = user._pending.add(unlockedRewards);
            }
            user._season2StakeInfos[__tokenIDList[i]]._isLocked = true;
            user._season2StakeInfos[__tokenIDList[i]]._stakedAt = block
                .timestamp;

            emit Locked(_msgSender(), __tokenIDList[i], false);
        }
    }

    /**
     * @notice
     */
    function pairNfts(uint256 __season1TokenID, uint256 __season2TokenID)
        external
        nonReentrant
        whenNotPaused
    {
        UserInfo storage user = _userInfo[_msgSender()];
        require(
            user._season1Nfts.contains(__season1TokenID) &&
                user._season2Nfts.contains(__season2TokenID),
            "One of nfts is not staked"
        );
        require(
            user._season1StakeInfos[__season1TokenID]._pairedTokenId == 0 &&
                user._season2StakeInfos[__season2TokenID]._pairedTokenId == 0,
            "Already paired"
        );
        user
            ._season1StakeInfos[__season1TokenID]
            ._pairedTokenId = __season2TokenID;
        user
            ._season2StakeInfos[__season2TokenID]
            ._pairedTokenId = __season1TokenID;
        user._season2StakeInfos[__season2TokenID]._stakedAt = block.timestamp;
        user._pairCount = user._pairCount.add(1);

        emit Paired(_msgSender(), __season1TokenID, __season2TokenID);
    }

    function safeRewardTransfer(address __to, uint256 __amount)
        internal
        returns (uint256)
    {
        uint256 balance = IERC20(_rewardToken).balanceOf(address(this));
        if (balance >= __amount) {
            IERC20(_rewardToken).safeTransfer(__to, __amount);
            return __amount;
        }

        if (balance > 0) {
            IERC20(_rewardToken).safeTransfer(__to, balance);
        }
        emit InsufficientRewardToken(__to, __amount, balance);
        return balance;
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
