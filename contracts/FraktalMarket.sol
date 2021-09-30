pragma solidity >=0.8.0 <0.9.0;
//SPDX-License-Identifier: UNLICENSED

import './FraktalNFT.sol';
import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import '@openzeppelin/contracts-upgradeable/proxy/ClonesUpgradeable.sol';
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./EnumerableMap.sol";

contract FraktalMarket is Ownable, ReentrancyGuard, ERC1155Holder {
    using EnumerableMap for EnumerableMap.UintToAddressMap;
    uint16 public fee;
    uint256 private feesAccrued;
    struct Proposal {
      uint256 value;
      bool winner;
    }
    struct Listing {
      address tokenAddress;
      uint256 price;
      uint16 numberOfShares;
    }
    /* EnumerableMap.UintToAddressMap private fraktalNFTs; */
    mapping(address=> mapping(address => Listing)) listings;
    mapping (address => mapping(address => Proposal)) public offers;
    mapping (address => uint256) public sellersBalance;
    mapping (address => uint256) public maxPriceRegistered;


    event Bought(address buyer,address seller, address tokenAddress, uint16 numberOfShares);
    event FeeUpdated(uint16 newFee);
    event ItemListed(address owner, address tokenAddress, uint256 price, uint256 amountOfShares);
    event ItemPriceUpdated(address owner, address tokenAddress, uint256 newPrice);
    event FraktalClaimed(address owner, address tokenAddress);
    event SellerPaymentPull(address seller, uint256 balance);
    event AdminWithdrawFees(uint256 feesAccrued);
    event OfferMade(address offerer, address tokenAddress, uint256 value);

    // change it to a initializer function?
    constructor() {
        fee = 100;
    }

// Admin Functions
//////////////////////////////////
    function setFee(uint16 _newFee) external onlyOwner {
      require(_newFee >= 0, "FraktalMarket: negative fee not acceptable");
      fee = _newFee;
      emit FeeUpdated(_newFee);
    }
    function withdrawAccruedFees() external onlyOwner nonReentrant returns (bool){
      address addr1 = _msgSender();
      address payable wallet = payable(addr1);
      wallet.transfer(feesAccrued);
      emit AdminWithdrawFees(feesAccrued);
      feesAccrued = 0;
      return true;
    }

// Users Functions
//////////////////////////////////
    function rescueEth() public nonReentrant {
      require(sellersBalance[_msgSender()] > 0, 'You dont have any to claim');
      address payable seller = payable(_msgSender());
      uint256 balance = sellersBalance[_msgSender()];
      seller.transfer(balance);
      sellersBalance[_msgSender()] = 0;
      emit SellerPaymentPull(_msgSender(), balance);
    }
    function buyFraktions(address from, address tokenAddress, uint16 _numberOfShares)
      external
      payable
      nonReentrant
    {
      Listing storage listing = listings[tokenAddress][from];
      require(!FraktalNFT(tokenAddress).sold(), 'item sold');
      require(listing.numberOfShares >= _numberOfShares, 'Not enough Fraktions on sale');
      uint256 buyPrice = (listing.price * _numberOfShares);
      uint256 totalFees = buyPrice * fee / 10000;
      uint256 totalForSeller = buyPrice - totalFees;
      uint256 fraktionsIndex = FraktalNFT(tokenAddress).fraktionsIndex();
      require(msg.value > buyPrice, "FraktalMarket: insufficient funds");
      listing.numberOfShares = listing.numberOfShares - _numberOfShares;
      if(listing.price*10000 > maxPriceRegistered[tokenAddress]) {
        maxPriceRegistered[tokenAddress] = listing.price*10000;
      }
      FraktalNFT(tokenAddress).safeTransferFrom(
        from,
        _msgSender(),
        fraktionsIndex,
        _numberOfShares,
        ""
      );
      feesAccrued += msg.value - totalForSeller;
      sellersBalance[from] += totalForSeller;
      emit Bought(_msgSender(), from, tokenAddress, _numberOfShares);
    }

    function listItem(
        address _tokenAddress,
        uint256 _price,
        uint16 _numberOfShares
      ) external returns (bool) {
          uint256 fraktionsIndex = FraktalNFT(_tokenAddress).fraktionsIndex();
          require(FraktalNFT(_tokenAddress).balanceOf(address(this),0) == 1, 'nft not in market');
          require(!FraktalNFT(_tokenAddress).sold(), 'item sold');
          require(FraktalNFT(_tokenAddress).balanceOf(_msgSender(),fraktionsIndex) >= _numberOfShares, 'no valid Fraktions');
          Listing memory listed = listings[_tokenAddress][_msgSender()];
          require(listed.numberOfShares == 0, 'unlist first');
          Listing memory listing =
          Listing({
            tokenAddress: _tokenAddress,
            price: _price,
            numberOfShares: _numberOfShares
          });
        listings[_tokenAddress][_msgSender()] = listing;
        emit ItemListed(_msgSender(), _tokenAddress, _price, _numberOfShares);
        return true;
      }

    function makeOffer(address tokenAddress, uint256 _value) public payable {
      require(msg.value >= _value, 'No pay');
      // check interactions with sold items.. prob make a status in offers (or set winner)
      // sold items should allow to take out offers of losers, but block the winner and call claimFraktal
      Proposal storage prop = offers[_msgSender()][tokenAddress];
      address payable offerer = payable(_msgSender());
      require(!prop.winner,'offer accepted');
      if (_value > prop.value) {
        require(_value >= maxPriceRegistered[tokenAddress],'Min offer');
        require(msg.value >= _value - prop.value);
      } else {
          offerer.transfer(prop.value); // returns offer value
      }
      offers[_msgSender()][tokenAddress] = Proposal({
        value: _value,
	winner: false
        });
      emit OfferMade(_msgSender(), tokenAddress, _value);
    }

    function voteOffer(address offerer, address tokenAddress) public {
      uint256 fraktionsIndex = FraktalNFT(tokenAddress).fraktionsIndex();
      Proposal storage offer = offers[offerer][tokenAddress];
      uint lockedShares = FraktalNFT(tokenAddress).getLockedShares(fraktionsIndex,_msgSender());
      uint256 votesAvailable = FraktalNFT(tokenAddress).balanceOf(_msgSender(), fraktionsIndex) - lockedShares;
      FraktalNFT(tokenAddress).lockSharesTransfer(_msgSender(),votesAvailable, offerer);
      uint lockedToOfferer = FraktalNFT(tokenAddress).getLockedToTotal(fraktionsIndex,offerer);
      if(lockedToOfferer > FraktalNFT(tokenAddress).majority()){
        FraktalNFT(tokenAddress).sellItem();
	offer.winner = true;
      }
    }

    function claimFraktal(address tokenAddress) external {
       uint256 fraktionsIndex = FraktalNFT(tokenAddress).fraktionsIndex();
       // if item is sold, then we create the last revenue payment channel
       if(FraktalNFT(tokenAddress).sold()){
         Proposal memory offer = offers[_msgSender()][tokenAddress];
         require(FraktalNFT(tokenAddress).getLockedToTotal(fraktionsIndex,_msgSender())>FraktalNFT(tokenAddress).majority(), 'not buyer');
         FraktalNFT(tokenAddress).createRevenuePayment{value: offer.value}();
         // delete price register for future listings (different fraktionsIndex)
         maxPriceRegistered[tokenAddress] = 0;

       }
       // if is not sold, but 100% fraktions are locked, should allow to claim it to the
       // beneficiary address
       FraktalNFT(tokenAddress).safeTransferFrom(address(this),_msgSender(),0,1,'');
       emit FraktalClaimed(_msgSender(), tokenAddress);
    }

    function unlistItem(address tokenAddress) external {
      uint amount = getListingAmount(_msgSender(), tokenAddress); // needed?
      require(amount > 0, 'You have no listed Fraktions with this id'); // ??
      delete listings[tokenAddress][_msgSender()];
      emit ItemListed(_msgSender(), tokenAddress, 0, 0);
    }
// GETTERS
//////////////////////////////////
    function getFee() public view returns(uint256){
      return(fee);
    }
    function getListingPrice(address _listOwner, address tokenAddress) public view returns(uint256){
      return listings[tokenAddress][_listOwner].price;
    }
    function getListingAmount(address _listOwner, address tokenAddress) public view returns(uint256){
      return listings[tokenAddress][_listOwner].numberOfShares;
    }
    function getSellerBalance(address _who) public view returns(uint256){
      return(sellersBalance[_who]);
    }
    function getOffer(address offerer, address tokenAddress) public view returns(uint256){
      return(offers[offerer][tokenAddress].value);
    }
}
//////////////////////////
