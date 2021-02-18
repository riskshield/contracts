
//           DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
//                   Version 2, December 2004
// 
//Copyright (C) 2021 ins3project <ins3project@yahoo.com>
//
//Everyone is permitted to copy and distribute verbatim or modified
//copies of this license document, and changing it is allowed as long
//as the name is changed.
// 
//           DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
//  TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION
//
// You just DO WHAT THE FUCK YOU WANT TO.
pragma solidity >=0.6.0 <0.7.0;

import "./StakingPoolToken.sol";
import "./IUpgradable.sol";
import "./PriceMetaInfoDB.sol";
import "./RISHToken.sol";
import "./IStakingPool.sol";
import "./@openzeppelin/math/SafeMath.sol";
import "./@openzeppelin/math/Math.sol";
import "./@openzeppelin/utils/EnumerableSet.sol";

contract StakingTokenMintPool is IUpgradable
{
    using SafeMath for uint256;

    using EnumerableSet for EnumerableSet.UintSet;

    StakingPoolToken _stakingPoolToken;    
    mapping(uint256/*tokenId*/=>address/*account*/) _accounts;
    mapping(uint256/*tokenId*/=>uint256/*timestamp*/) _enterTimestamp;
    PriceMetaInfoDB  _priceMetaInfoDb;
    RISHToken _rishTokenHolder;
    mapping(address/*account*/=>EnumerableSet.UintSet) _tokenIds;

    uint256 public totalRISHRewardMinted; 
    uint256 public maxRISHRewards; 


    constructor() public{
    }

    function  updateDependentContractAddress() public override{
        address stakingPoolTokenAddress =register.getContract("SKPT");
        _stakingPoolToken=StakingPoolToken(stakingPoolTokenAddress);
        require(stakingPoolTokenAddress!=address(0),"Null for SKPT");

        address priceMetaInfoDbAddress = register.getContract("MIDB");
        _priceMetaInfoDb=PriceMetaInfoDB(priceMetaInfoDbAddress);
        require(priceMetaInfoDbAddress!=address(0),"Null for MIDB");
        maxRISHRewards = _priceMetaInfoDb.TOTAL_RISH_AMOUNT().mul(_priceMetaInfoDb.STAKING_MINT_PERCENT()).div(1000);
        address rishCoinHolderAddress = register.getContract("RISH");
        _rishTokenHolder=RISHToken(rishCoinHolderAddress);
        require(rishCoinHolderAddress!=address(0),"Null for RISH");
    }

    function isPledged(uint256 tokenId) view public returns(bool){
        return _accounts[tokenId]!=address(0);
    }

    function ownerOf(uint256 tokenId) view public returns(address){
        return  _accounts[tokenId];
    }

    function pledgedTimestamp(uint256 tokenId) view public returns(uint256){ 
        return  _enterTimestamp[tokenId];
    }


    function calcRISHRewards(uint256 tokenId, uint256 priceRISH) view public returns(uint256){
        require(isPledged(tokenId),"The NFT token did not pledged");
        require(priceRISH > 1e8,"invalid rish price");
        if(maxRISHRewards<=totalRISHRewardMinted){
            return 0;
        }

        uint256 timestamp=_enterTimestamp[tokenId];

        (uint256 principal,,,,address [] memory pools) = _stakingPoolToken.getTokenHolder(tokenId);
        uint256 endTm = 0;
        for (uint256 i=0;i<pools.length;++i){
            address poolAddr=pools[i];
            IStakingPool pool=IStakingPool(poolAddr);
            endTm = Math.max(endTm, pool.productTokenExpireTimestamp());
        }
        endTm = Math.min(endTm, _priceMetaInfoDb.currentTimestamp());        
        if (endTm<=timestamp){
            return 0;
        }
        uint256 period = endTm.sub(timestamp);
        uint256 rewards = _priceMetaInfoDb.RISHAPY().mul(principal).mul(period).mul(1e12).div(31536).div(priceRISH); 
        uint256 availableRISH = maxRISHRewards.sub(totalRISHRewardMinted);
        return Math.min(availableRISH,rewards);
    }

    function pledge(uint256 tokenId) whenNotPaused external{
        require(_stakingPoolToken.ownerOf(tokenId)==_msgSender(),"The NFT token does not belong to you");
        _stakingPoolToken.transferFrom(_msgSender(),address(this),tokenId);
        _accounts[tokenId]=_msgSender();
        _enterTimestamp[tokenId]=_priceMetaInfoDb.currentTimestamp();
        _tokenIds[_msgSender()].add(tokenId);
    }

    
    function harvestRISHRewards(uint256 tokenId, address priceNodePublicKey, uint256 priceRISH, uint256 expiresAt, uint8 _v, bytes32 _r, bytes32 _s) whenNotPaused external returns(bool){
        require(ownerOf(tokenId)==_msgSender(),"The NFT token does not belong to you");
        require(isPledged(tokenId),"The NFT token did not pledged");
        require(_tokenIds[_msgSender()].contains(tokenId),"The NFT token did not pledged");
        require(maxRISHRewards>totalRISHRewardMinted,"have no RISH for mint");

        require(verifyRISHPrice(priceNodePublicKey, priceRISH, expiresAt, _v, _r, _s), "RISH price verify sign failed");

        uint256 rewards = calcRISHRewards(tokenId,priceRISH);

        _enterTimestamp[tokenId] = _priceMetaInfoDb.currentTimestamp();
        if (rewards>0){
            totalRISHRewardMinted = totalRISHRewardMinted.add(rewards);
            _rishTokenHolder.mint(_msgSender(),rewards);
        }
        return true;
    }


    function ransom(uint256 tokenId, address priceNodePublicKey, uint256 priceRISH, uint256 expiresAt, uint8 _v, bytes32 _r, bytes32 _s) whenNotPaused external returns(bool){        
        require(ownerOf(tokenId)==_msgSender(),"The NFT token does not belong to you");
        require(isPledged(tokenId),"The NFT token did not pledged");
        require(_tokenIds[_msgSender()].contains(tokenId),"The NFT token did not pledged");

        require(verifyRISHPrice(priceNodePublicKey, priceRISH, expiresAt, _v, _r, _s), "RISH price verify sign failed");

        uint256 rewards = calcRISHRewards(tokenId,priceRISH);

        delete _accounts[tokenId];
        delete _enterTimestamp[tokenId];
        _tokenIds[_msgSender()].remove(tokenId);
        
        if (rewards>0){
            totalRISHRewardMinted = totalRISHRewardMinted.add(rewards);
            _rishTokenHolder.mint(_msgSender(),rewards);
        }
        _stakingPoolToken.safeTransferFrom(address(this),_msgSender(),tokenId);  
        return true;
    }

	function verifyRISHPrice(address priceNodePublicKey, uint256 price, uint256 expiresAt, uint8 v, bytes32 r, bytes32 s) public view returns(bool){
		require(address(_priceMetaInfoDb)!=address(0),"priceMetaInfoDb not set");
        require(price > 0,"rish price should > 0");
        require(_priceMetaInfoDb.PRICE_NODE_PUBLIC_KEY()==priceNodePublicKey,"The price node public key is not valid");
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                priceNodePublicKey,
                price,
                expiresAt
            )
        );
		return _priceMetaInfoDb.verifySign(messageHash,priceNodePublicKey,expiresAt,v,r,s);
    }

    function accountIdLength(address account) view public returns(uint256){
        EnumerableSet.UintSet storage tokens = _tokenIds[account];
        return tokens.length();
    }

    function allTokenIds(address account,uint256 index,uint256 count) view public returns(uint256[] memory){
        EnumerableSet.UintSet storage tokens=_tokenIds[account];
        uint256 startIndex=index.mul(count);
        uint256 length=Math.min(count,tokens.length().sub(startIndex));
        uint256 [] memory ts=new uint256[](length);
        for (uint256 i=0;i<length;++i){
            ts[i]=tokens.at(i.add(startIndex));
        }
        return ts;
    }
}