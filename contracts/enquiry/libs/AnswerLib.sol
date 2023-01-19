// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

library AnswerLib {
    struct Answer {
        address stakeToken;
        uint256 rp;
        bytes signature;
        uint256 stakedAmount;
        bool claimed;
        bytes32 tokenId;
        bytes32 bidPrice;
        bytes32 askPrice;
    }
}
