// SPDX-License-Identifier: MIT

pragma solidity >=0.5.16;

import "./libs/SafeMath.sol";
import "./libs/SafeERC20.sol";
import "./libs/Ownable.sol";

contract GoatLocker is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    ///@notice the token to lock
    IERC20 public immutable lockedToken;

    ///@notice unlockable from (in epoch time)
    uint256 public immutable unlockableFrom;

    ///@notice months to lock tokens
    uint256 public immutable monthsToLock;

    ///@notice the address to receive unlocked tokens
    address public tokenReceiver;

    ///@notice unlocked so far
    uint256 public totalUnlocked;

    ///@notice months that owner claimed tokens
    uint256 public monthsClaimed;

    constructor(
        address _token,
        address _receiver,
        uint256 _from,
        uint256 _months
    ) {
        require(_token != address(0), "Invalid token");
        require(_receiver != address(0), "Invalid receiver");
        require(_from >= block.timestamp, "Invalid start time");
        require(_months > 0, "Invalid duration");

        lockedToken = IERC20(_token);
        tokenReceiver = _receiver;
        unlockableFrom = _from;
        monthsToLock = _months;
    }

    /**
     * @notice Update receiver address
     * @dev Only callable by owner
     */
    function updateReceiver(address _receiver) external onlyOwner {
        require(_receiver != address(0), "Invalid receiver address");
        tokenReceiver = _receiver;
    }

    /**
     * @notice Get claimable amount at the current time
     * @return claimable amount
     * @return months passed ( claimed months + claimable months )
     */
    function getClaimInfo() public view returns (uint256, uint256) {
        uint256 currentTime = block.timestamp;
        uint256 tokenBalance = lockedToken.balanceOf(address(this));

        // no token locked
        if (tokenBalance == 0) {
            return (0, monthsClaimed);
        }

        // before unlock start time
        if (currentTime < unlockableFrom) {
            return (0, 0);
        }
        // claimed until this month, should wait next month
        uint256 passedMonths = currentTime.sub(unlockableFrom).div(30 days);
        if (passedMonths < monthsClaimed) {
            return (0, monthsClaimed);
        }

        // lock finished and all tokens claimed, just tokens that were sent from token tax fee
        if (monthsClaimed > monthsToLock) {
            return (tokenBalance, monthsClaimed);
        }

        return (
            tokenBalance.mul(passedMonths.sub(monthsClaimed).add(1)).div(
                monthsToLock.sub(monthsClaimed)
            ),
            passedMonths.add(1)
        );
    }

    /**
     * @notice Claim tokens
     * @dev Only owner has right to call this function
     */
    function claim() external onlyOwner {
        (uint256 claimableAmount, uint256 passedMonths) = getClaimInfo();
        require(claimableAmount > 0, "Nothing to claim");
        
        lockedToken.safeTransfer(tokenReceiver, claimableAmount);
        totalUnlocked = totalUnlocked.add(claimableAmount);
        monthsClaimed = passedMonths;
    }
}
