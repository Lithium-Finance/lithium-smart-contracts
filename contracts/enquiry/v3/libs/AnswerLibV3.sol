// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

library AnswerLibV3 {
    struct Answer {
        address stakeToken;
        uint256 rp;
        bytes signature;
        uint256 stakedAmount;
        bool claimed;
        bool revealed;
        uint256[] tokenId;
        uint256[] bidPrice;
        uint256[] askPrice;
    }
}
