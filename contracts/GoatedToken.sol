// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./AntiBotERC20.sol";

contract GoatedToken is AntiBotERC20("GOATED", "GOATD") {
    using SafeMath for uint256;
    using Address for address;

    uint16 public constant MAX_BURN_FEE = 500; // 5% max
    uint16 public constant MAX_TREASURY_FEE = 500; // 5% max
    uint16 public constant MAX_STAKING_FEE = 500; // 5% max
    uint16 public constant MAX_COMMUNITY_FEE = 500; // 5% max
    
    uint16 public _burnFee = 500; // Fee for burning token
    uint16 public _treasuryFee = 500; // Fee for treasury pool
    uint16 public _stakingFee = 500; // Fee for staking rewards pool
    uint16 public _communityFee = 500; // Fee for community rewards pool

    address public _treasuryPool;
    address public _stakingPool;
    address public _communityPool;

    mapping(address => bool) private _isExcludedFromFee;
    mapping(address => bool) private _isGoatPair;

    constructor() {
        _isExcludedFromFee[_msgSender()] = true;
        _mint(_msgSender(), 10**26);
    }

    function excludeFromFee(address account) external onlyOwner {
        _isExcludedFromFee[account] = true;
    }

    function includeInFee(address account) external onlyOwner {
        _isExcludedFromFee[account] = false;
    }

    function isExcludedFromFee(address account) external view returns (bool) {
        return _isExcludedFromFee[account];
    }

    function excludeFromGoatPair(address lpAddress) external onlyOwner {
        _isGoatPair[lpAddress] = false;
    }

    function includeInGoatPair(address lpAddress) external onlyOwner {
        _isGoatPair[lpAddress] = true;
    }

    function isGoatPair(address lpAddress) external view returns (bool) {
        return _isGoatPair[lpAddress];
    }

    function setAllFeePercent(
        uint16 burnFee,
        uint16 treasuryFee,
        uint16 stakingFee,
        uint16 communityFee
    ) external onlyOwner {
        require(burnFee <= MAX_BURN_FEE, "Burn fee overflow");
        require(treasuryFee <= MAX_TREASURY_FEE, "Treasury fee overflow");
        require(stakingFee <= MAX_STAKING_FEE, "Staking fee overflow");
        require(communityFee <= MAX_COMMUNITY_FEE, "Community fee overflow");
        _burnFee = burnFee;
        _treasuryFee = treasuryFee;
        _stakingFee = stakingFee;
        _communityFee = communityFee;
    }

    function setPoolAddresses(
        address treasuryPool,
        address stakingPool,
        address communityPool
    ) external onlyOwner {
        require(treasuryPool != address(0), "Invalid treasury pool");
        require(stakingPool != address(0), "Invalid staking pool");
        require(communityPool != address(0), "Invalid community pool");
        _treasuryPool = treasuryPool;
        _stakingPool = stakingPool;
        _communityPool = communityPool;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "ERC20: transfer from zero address");
        require(to != address(0), "ERC20: transfer to zero address");
        require(amount > 0, "Transfer amount must be greater than zero");

        // indicates if fee should be deducted from transfer
        // if any account belongs to _isExcludedFromFee account then remove the fee
        bool takeFee = !_isExcludedFromFee[from] &&
            !_isExcludedFromFee[to] &&
            _isGoatPair[to];

        if (takeFee) {
            uint256 burnFeeAmount = amount.mul(_burnFee).div(10000);
            super._transfer(from, DEAD, burnFeeAmount);
            amount = amount.sub(burnFeeAmount);

            uint256 treasuryFeeAmount = amount.mul(_treasuryFee).div(10000);
            if (treasuryFeeAmount > 0 && _treasuryPool != address(0)) {
                super._transfer(from, _treasuryPool, treasuryFeeAmount);
                amount = amount.sub(treasuryFeeAmount);
            }
            
            uint256 stakingFeeAmount = amount.mul(_stakingFee).div(10000);
            if (stakingFeeAmount > 0 && _stakingPool != address(0)) {
                super._transfer(from, _stakingPool, stakingFeeAmount);
                amount = amount.sub(stakingFeeAmount);
            }
            
            uint256 communityFeeAmount = amount.mul(_communityFee).div(10000);
            if (communityFeeAmount > 0 && _communityPool != address(0)) {
                super._transfer(from, _communityPool, communityFeeAmount);
                amount = amount.sub(communityFeeAmount);
            }
        }

        super._transfer(from, to, amount);
    }
}
