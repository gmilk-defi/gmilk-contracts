// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "./libs/Ownable.sol";
import "./libs/ERC721.sol";
import "./libs/SafeMath.sol";
import "./libs/Strings.sol";

contract TheGoatSociety is Ownable, ERC721 {
    using SafeMath for uint256;
    using Strings for uint256;

    uint256 public sumonCost = 2;
    uint256 public sumonSupply = 0;
    uint256 public supply = 0;
    uint256 public price = 0.06 ether;
    uint256 public supplyL;
    uint256 public presaleSupplyL; //CONFIRM
    uint256 public maxGoatMint = 10;
    uint256 public sumon_token_id = 10001;

    string public baseURI = "";
    bool public initiateSale = false;
    bool public initiatePreSale = false;

    bool public sumonActive = false;
    bool public calledWithdrawES = false;
    bool public presaleWhitelistActive = true;

    address[] public GoatPresale;

    address public partner1 = 0x19E53469BdfD70e103B18D9De7627d88c4506DF2;
    address public partner2 = 0x7861e0f3b46e7C4Eac4c2fA3c603570d58bd1d97;
    address public splitAddy = 0xDF1A23195c13ea380E00DEe2e7f4c8d3b4b7Ef17;

    constructor(
        uint256 amount,
        uint256 presaleAmount,
        string memory _baseURI
    ) ERC721("Goat Society", "GS") {
        supplyL = amount;
        presaleSupplyL = presaleAmount;
        baseURI = _baseURI;
    }

    function tokenURI(uint256 token_id)
        public
        view
        override
        returns (string memory)
    {
        require(_exists(token_id), "nonexistent token");
        return
            bytes(baseURI).length > 0
                ? string(abi.encodePacked(baseURI, token_id.toString()))
                : "";
    }

    function flipValues(uint256 flip) external onlyOwner {
        if (flip == 0) {
            initiateSale = !initiateSale;
        } else if (flip == 1) {
            initiatePreSale = !initiatePreSale;
        } else if (flip == 2) {
            presaleWhitelistActive = !presaleWhitelistActive;
        } else if (flip == 3) {
            sumonActive = !sumonActive;
        }
    }

    function change_sumon_token(uint256 _sumon_token_id) external onlyOwner {
        sumon_token_id = _sumon_token_id;
    }

    function sumonAmount(uint256 _supplyLimit) external onlyOwner {
        require(_supplyLimit >= supply, "Error ");
        supplyL = _supplyLimit;
    }

    function sumon_maxGoatMint(uint256 _mintLimit) external onlyOwner {
        maxGoatMint = _mintLimit;
    }

    function sumon_mintPrice(uint256 _mintPrice) external onlyOwner {
        price = _mintPrice;
    }

    function set_uri(string memory _baseURI) external onlyOwner {
        baseURI = _baseURI;
    }

    function withdrawES() external onlyOwner {
        require(address(this).balance > 10 ether, "None");
        require(calledWithdrawES == false, "Already ran the withdraw method.");
        (bool withES, ) = splitAddy.call{value: 10 ether}("");
        calledWithdrawES = true;
        require(withES, "Not enough ethereum to withdraw");
    }

    function withdraw() external onlyOwner {
        require(address(this).balance > 0, "None");
        require(calledWithdrawES == true, "Already Ran");
        uint256 walletBalance = address(this).balance;

        (bool w1, ) = partner1.call{value: walletBalance.mul(50).div(100)}(""); //5
        (bool w2, ) = partner2.call{value: walletBalance.mul(50).div(100)}(""); //5

        require(w1 && w2, "Failed withdraw");
    }

    //Incase withdraw() fails run this method
    function emergencyWithdraw() external onlyOwner {
        (bool withES, ) = splitAddy.call{value: address(this).balance}("");
        require(withES, "Not enough ethereum to withdraw");
    }

    function populate_PreSaleWhitelist(
        address[] calldata preSaleWalletAddresses
    ) external onlyOwner {
        delete GoatPresale;
        GoatPresale = preSaleWalletAddresses;
        return;
    }

    function giveaway_goats() external onlyOwner {
        require(supply.add(25) <= supplyL, "Token error");

        uint256 token_id = supply;
        for (uint256 i = 0; i < 25; i++) {
            token_id += 1;
            supply = supply.add(1);
            _safeMint(msg.sender, token_id);
        }
    }

    function buy(uint256 nft) external payable {
        require(initiateSale, "Sale not available");
        require(nft <= maxGoatMint, "Too many");
        require(msg.value >= price.mul(nft), "Payment error");
        require(supply.add(nft) <= supplyL, "Token error");

        uint256 token_id = supply;
        for (uint256 i = 0; i < nft; i++) {
            token_id += 1;
            supply = supply.add(1);

            _safeMint(msg.sender, token_id);
        }
    }

    function buy_presale(uint256 nft) external payable {
        require(initiatePreSale, "Presale not available"); //YES
        require(nft <= maxGoatMint, "Too many"); //YES
        require(msg.value >= price.mul(nft), "Payment error"); //YES
        require(supply.add(nft) <= presaleSupplyL, "Token error"); //NO

        if (presaleWhitelistActive) {
            require(isWalletInPreSale(msg.sender), "Not in Presale");
            uint256 token_id = supply;
            for (uint256 i = 0; i < nft; i++) {
                token_id += 1;
                supply = supply.add(1);

                _safeMint(msg.sender, token_id);
            }
        } else {
            uint256 token_id = supply;
            for (uint256 i = 0; i < nft; i++) {
                token_id += 1;
                supply = supply.add(1);

                _safeMint(msg.sender, token_id);
            }
        }
    }

    function isWalletInPreSale(address _address) public view returns (bool) {
        for (uint256 i = 0; i < GoatPresale.length; i++) {
            if (GoatPresale[i] == _address) {
                return true;
            }
        }
        return false;
    }

    function sumon(uint256[] memory token_ids)
        public
        meetsOwnership(token_ids)
    {
        require(sumonActive, "Goat Summonings is not active");
        require(sumonSupply > 0, "No Summon Supply left");
        require(token_ids.length >= sumonCost, "Not enough Goats provided");

        for (uint256 i = 0; i < token_ids.length; i++) {
            _burn(token_ids[i]);
        }

        uint256 token_id = sumon_token_id;

        token_id += 1;
        sumon_token_id = sumon_token_id.add(1);
        _safeMint(msg.sender, token_id);

        sumonSupply -= 1;
    }

    function setsumonCost(uint256 newCost) public onlyOwner {
        require(newCost > 0, "sumonCost should be more than 0");
        sumonCost = newCost;
    }

    function setsumonSupply(uint256 newsumonSupply) public onlyOwner {
        sumonSupply = newsumonSupply;
    }

    modifier meetsOwnership(uint256[] memory token_ids) {
        for (uint256 i = 0; i < token_ids.length; i++) {
            require(
                this.ownerOf(token_ids[i]) == msg.sender,
                "You don't own these tokens"
            );
        }
        _;
    }
}
