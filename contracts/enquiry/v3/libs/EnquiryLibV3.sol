// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

library EnquiryLibV3 {
    struct Enquiry {
        address seeker;
        uint256 reward;
        address rewardToken;
        address stakeAToken;
        address stakeBToken;
        uint256 startTime;
        uint256 endTime;
        uint256 userLimit;
        uint256 BACrossRate;
        uint256 maxRPTokenAMultiplier;
        uint256 tokenStakeThreshold;
        uint256 rpStakeThreshold;
        string uri;
        uint256 totalAnswer;
        uint256 totalStakedAToken;
        uint256 totalStakedBToken;
        uint256 totalStakedRp;
    }

    struct CreateEnquiryParam {
        uint256 reward;
        address rewardToken;
        address stakeAToken;
        address stakeBToken;
        uint256 startTime;
        uint256 endTime;
        uint256 userLimit;
        uint256 BACrossRate;
        uint256 maxRPTokenAMultiplier;
        uint256 tokenStakeThreshold;
        uint256 rpStakeThreshold;
        string uri;
    }
}
