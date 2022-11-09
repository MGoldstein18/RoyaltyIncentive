// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@thirdweb-dev/contracts/base/ERC721Base.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

contract RoyaltyIncentive is ERC721Base {
    constructor(
        string memory _name,
        string memory _symbol,
        address _royaltyRecipient,
        uint128 _royaltyBps,
        uint256 _creatorRoyalty
    ) ERC721Base(_name, _symbol, _royaltyRecipient, _royaltyBps) {
        creatorRoyalty = _creatorRoyalty;
    }

    /// @dev Variable to hold the creator's royalty percentage of the royalties.
    uint256 public creatorRoyalty;

    /// @dev Emitted when a token is made available for sale
    event MadeAvailableForSale(uint256 indexed tokenId, uint256 price);

    /// @dev Struct for storing pre-sale data for each sale
    struct PreSaleData {
        uint256 price;
        uint256 royaltyAmount;
    }

    /// @dev Map token ids to pre-sale data
    mapping(uint256 => PreSaleData) public preSaleData;

    /// @dev Struct for storing post-sale data for each sale
    struct PostSaleData {
        uint256 price;
        uint256 royaltyAmount;
        address seller;
    }

    /// @dev Map token ids to arrays of post-sale data
    mapping(uint256 => PostSaleData[]) public postSaleData;

    /// @dev Track whether or not an NFT is available for sale
    mapping(uint256 => bool) public isAvailableForSale;

    /// @dev Mapping of address to royalties allocated to them
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    EnumerableMap.AddressToUintMap internal royaltyAllocations;

    /**
     * @notice Make the NFT with `_tokenId` available for sale by setting a `_price`
     * @dev
     * Require that `msg.sender` is the current owner of the NFT with the provided ID or is approved to transfer it
     * Update `isAvailableForSale` to true at `_tokenId`
     * Add a new `PreSaleData` struct to `preSaleData` at `_tokenId`
     * Emit `MadeAvailableForSale` event
     * @param _tokenId The ID of the NFT to make available for sale
     * @param _price The price of the NFT
     * @return price The price of the NFT (excluding royalties)
     * @return royaltyAmount The royalty amount
     */
    function makeAvailableForSale(uint256 _tokenId, uint256 _price)
        external
        returns (uint256 price, uint256 royaltyAmount)
    {
        TokenOwnership memory prevOwnership = _ownershipOf(_tokenId);

        bool isApprovedOrOwner = (_msgSender() == prevOwnership.addr ||
            isApprovedForAll(prevOwnership.addr, _msgSender()) ||
            getApproved(_tokenId) == _msgSender());

        if (!isApprovedOrOwner) revert TransferCallerNotOwnerNorApproved();

        isAvailableForSale[_tokenId] = true;

        (, uint16 royaltyBps) = getRoyaltyInfoForToken(_tokenId);
        uint256 _royaltyAmount = (_price * royaltyBps) / 10000;

        preSaleData[_tokenId] = PreSaleData(_price, _royaltyAmount);

        emit MadeAvailableForSale(_tokenId, price);

        return (_price, _royaltyAmount);
    }

    /**
     * @notice Allocate royalties to the creator and previous sellers
     * @dev
     * Private function
     * Takes in royalty amount
     * Splits the amount between the creator and previous sellers
     * Interates through `postSaleData` to get the total value of all sales made for this token id
     * And then uses that to get the percentage of the royalty amount that should be allocated to each seller
     * Allocates that percentage of the `_royaltyAmount` minus the creator's cut to each seller by updated the `royaltyAllocations` mapping
     * @param _tokenId The ID of the NFT to allocate royalties for
     * @param _royaltyAmount The amount of royalties to allocate
     */
    function _allocateRoyalties(uint256 _tokenId, uint256 _royaltyAmount)
        private
    {
        uint256 creatorAmount = (_royaltyAmount * creatorRoyalty) / 100;
        uint256 sellerAmount = _royaltyAmount - creatorAmount;

        uint256 numberOfPreviousSales = postSaleData[_tokenId].length;

        uint256 totalSalesValue;
        for (uint256 i = 0; i < numberOfPreviousSales; i++) {
            totalSalesValue += postSaleData[_tokenId][i].price;
        }

        royaltyAllocations.set(owner(), creatorAmount);

        for (uint256 i = 0; i < numberOfPreviousSales; i++) {
            address seller = postSaleData[_tokenId][i].seller;
            (, uint256 currentAllocation) = royaltyAllocations.tryGet(seller);

            uint256 percentageOfTotalSales = (postSaleData[_tokenId][i].price /
                totalSalesValue) * 100;
            uint256 amountToAllocate = (sellerAmount * percentageOfTotalSales) /
                100;

            royaltyAllocations.set(
                seller,
                currentAllocation + amountToAllocate
            );
        }
    }

    /**
     * @notice Override the `transferFrom` function to a check for a price for the sale and allocate royalties
     * @dev
     * Require that the `to` is not zero address
     * Require that the `from` is either the owner of the NFT or is approved to transfer it
     * Check if there is pre-sale data for the token id
     * If there is, store the price and roaylty amount in variable and require that `msg.value` is equal to their sum
     * Delete the pre-sale data for the token id
     * Transger the price to the `from` address
     * Call the {_allocateRoyalties} function to allocate the royalties
     * Push the sale data to the `postSaleData` array for the token id
     * super.transferFrom(from, to, tokenId);
     * If there is no pre-sale data, call the super function,
     * @param from The address of the current owner of the NFT
     * @param to The address of the new owner of the NFT
     * @param tokenId The ID of the NFT to transfer
     */
    function transferWithRoyaltyIncentives(
        address from,
        address to,
        uint256 tokenId
    ) public payable {
        TokenOwnership memory prevOwnership = _ownershipOf(tokenId);

        if (prevOwnership.addr != from) revert TransferFromIncorrectOwner();

        bool isApprovedOrOwner = (_msgSender() == from ||
            isApprovedForAll(from, _msgSender()) ||
            getApproved(tokenId) == _msgSender());

        if (!isApprovedOrOwner) revert TransferCallerNotOwnerNorApproved();
        if (to == address(0)) revert TransferToZeroAddress();

        if (isAvailableForSale[tokenId]) {
            uint256 price = preSaleData[tokenId].price;
            uint256 royaltyAmount = preSaleData[tokenId].royaltyAmount;

            require(
                msg.value == price + royaltyAmount,
                "Incorrect amount sent"
            );

            delete preSaleData[tokenId];

            (bool sent, ) = from.call{value: price}("");
            require(sent, "Failed to send");

            _allocateRoyalties(tokenId, royaltyAmount);

            postSaleData[tokenId].push(
                PostSaleData(price, royaltyAmount, from)
            );

            isAvailableForSale[tokenId] = false;

            super.safeTransferFrom(from, to, tokenId);
        }
    }

    /**
     * @notice Claim the royalties allocated to the `msg.sender`
     * @dev
     * Require that the caller has a non-zero amount of royalties allocated to them
     * Get the amount of royalties allocated to the caller
     * Delete the amount of royalties allocated to the caller
     * Transfer the amount to the caller
     */
    function claimRoyaltyAllocation() public {
        (, uint256 amount) = royaltyAllocations.tryGet(_msgSender());
        require(amount > 0, "No royalty allocation");

        royaltyAllocations.set(_msgSender(), 0);

        (bool sent, ) = _msgSender().call{value: amount}("");
        require(sent, "Failed to send");
    }

    receive() external payable {}

    fallback() external payable {}

    function getBalance() public view returns (uint256) {
        return address(this).balance;
    }
}
