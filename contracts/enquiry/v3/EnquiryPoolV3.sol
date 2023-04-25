// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IReputation} from "../../reputation/interfaces/IReputation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {EnquiryLibV3} from "./libs/EnquiryLibV3.sol";
import {AnswerLibV3} from "./libs/AnswerLibV3.sol";

contract EnquiryPoolV3 is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Strings for uint256;
    using ECDSA for bytes32;
    using Address for address payable;

    // total number of created enquires
    uint256 public totalEnquiry;
    // enquiry id => question details
    mapping(uint256 => EnquiryLibV3.Enquiry) enquiries;
    // enquiry id => price expert => answer details
    mapping(uint256 => mapping(address => AnswerLibV3.Answer)) answers;
    // enquiry id => merkle tree root
    mapping(uint256 => bytes32) results;

    // RP Address
    IReputation public immutable RP_TOKEN;

    // Service fee rate
    uint32 public stakeServiceFeeRate;
    uint32 public rewardServiceFeeRate;

    // Treasury address
    address public treasury;

    // Max reward mint rp allowed
    uint256 public maxRewardRp;

    // Service fee rate %  4 decimal place
    uint32 constant SERVICE_FEE_PRECISION_FACTOR = 1e6;
    // Cross Rate precision factor
    uint64 constant CROSS_RATE_PRECISION_FACTOR = 1e6;
    // Multiplier precision factor
    uint16 constant MULTIPLIER_PRECISION_FACTOR = 1e4;
    // Max service fee rate 5 %
    uint16 constant MAX_SERVICE_FEE_RATE = 5 * 1e4;
    // Max time user can schedule an enquiry
    uint32 constant MAX_START_TIME_BUFFER = 4 weeks;
    // Max time enquiry can open
    uint32 constant MAX_END_TIME_BUFFER = 4 weeks;
    // Min time enquiry can open
    uint32 constant MIN_END_TIME_BUFFER = 1 days;
    // Max time the admin can post result time after question end time
    uint32 constant MAX_POST_RESULT_BUFFER = 2 weeks;
    // Max time the user to reveal answer time after question end time
    uint32 constant MAX_REVEAL_ANSWER_BUFFER = 1 weeks;
    // Max number of answers per user
    uint8 constant MAX_NUMBER_OF_ANSWER_PER_USER = 20;

    // Initialized status
    bool internal initialized;

    event Init();

    event CreateEnquiry(
        uint256 indexed enquiryId,
        address indexed seeker,
        uint256 reward,
        address rewardToken,
        address stakeAToken,
        address stakeBToken,
        uint256 startTime,
        uint256 endTime,
        uint256 userLimit,
        uint256 BACrossRate,
        uint256 maxRPTokenAMultiplier,
        uint256 tokenStakeThreshold,
        uint256 rpStakeThreshold,
        string uri
    );

    event RefundEnquiry(uint256 indexed enquiryId, address seeker, uint256 reward);

    event AddReward(uint256 indexed enquiryId, address sponsor, uint256 reward);

    event CreateAnswer(
        uint256 indexed enquiryId,
        address indexed expert,
        uint16 numOfTokenId,
        address stakeToken,
        uint256 rp,
        uint256 stakeAmount,
        bytes signature
    );

    event UpdateAnswer(
        uint256 indexed enquiryId,
        address indexed expert,
        uint16 numOfTokenId,
        uint256 rp,
        uint256 stakeAmount,
        bytes signature
    );

    event RevealAnswer(
        uint256 indexed enquiryId,
        address indexed expert,
        uint256[] tokenId,
        uint256[] bidPrice,
        uint256[] askPrice
    );

    event RefundAnswer(
        uint256 indexed enquiryId,
        address indexed expert,
        uint256 rp,
        uint256 stakeAmount
    );

    event ResultRoot(uint256 indexed enquiryId, address admin, bytes32 root);

    event ClaimReward(
        uint256 indexed enquiryId,
        address indexed expert,
        uint256 stakeAmount,
        uint256 tokenReward,
        uint256 stakeRp,
        uint256 rpReward
    );

    event SetMaxRewardRp(address admin, uint256 rp);

    event SetStakeServiceFeeRate(address admin, uint256 rate);

    event SetRewardServiceFeeRate(address admin, uint256 rate);

    event SetTreasury(address admin, address treasaury);

    modifier enquiryExists(uint256 enquiryId) {
        // check if the enquiry exist
        require(existsEnquiry(enquiryId), "EnquiryNotExist");
        _;
    }

    constructor(IReputation _rp, address _admin) {
        // Set RP token
        RP_TOKEN = _rp;

        initialized = false;

        // transfer ownership
        transferOwnership(_admin);
    }

    function init(address _treasury) external virtual onlyOwner {
        require(!initialized, "NotAllowed");
        // Set treasury
        setTreasury(_treasury);

        setMaxRewardRP(100000000000);

        initialized = true;

        emit Init();
    }

    function createEnquiry(EnquiryLibV3.CreateEnquiryParam calldata _enquiry)
        external
        payable
        virtual
        onlyOwner
        whenNotPaused
    {
        // check if the enquiry exist
        require(!existsEnquiry(totalEnquiry + 1), "EnquiryExist");

        // check if start time has passed or the start time is within a reasonable schedule time
        require(
            _enquiry.startTime >= block.timestamp &&
                _enquiry.startTime <= block.timestamp + MAX_START_TIME_BUFFER,
            "StartTimeNotAllowed"
        );
        // check if there's enough time for user to answer and within a reasonable to end the answer time
        require(
            _enquiry.endTime <= _enquiry.startTime + MAX_END_TIME_BUFFER &&
                _enquiry.endTime >= _enquiry.startTime + MIN_END_TIME_BUFFER,
            "EndTimeNotAllowed"
        );

        // check if the user limit is not zero
        require(_enquiry.userLimit > 0, "UserLimitZero");

        // check if the b to a exchange rate not zero
        require(_enquiry.BACrossRate > 0, "ZeroBACrossRate");

        // check if uri is empty
        require(bytes(_enquiry.uri).length > 0, "EmptyURI");

        if (_enquiry.reward > 0)
            _transferInToken(msg.sender, _enquiry.rewardToken, _enquiry.reward);

        totalEnquiry += 1;
        enquiries[totalEnquiry] = EnquiryLibV3.Enquiry({
            seeker: msg.sender,
            reward: _enquiry.reward,
            rewardToken: _enquiry.rewardToken,
            stakeAToken: _enquiry.stakeAToken,
            stakeBToken: _enquiry.stakeBToken,
            startTime: _enquiry.startTime,
            endTime: _enquiry.endTime,
            userLimit: _enquiry.userLimit,
            BACrossRate: _enquiry.BACrossRate,
            maxRPTokenAMultiplier: _enquiry.maxRPTokenAMultiplier,
            tokenStakeThreshold: _enquiry.tokenStakeThreshold,
            rpStakeThreshold: _enquiry.rpStakeThreshold,
            uri: _enquiry.uri,
            totalAnswer: 0,
            totalStakedAToken: 0,
            totalStakedBToken: 0,
            totalStakedRp: 0
        });

        emit CreateEnquiry(
            totalEnquiry,
            msg.sender,
            _enquiry.reward,
            _enquiry.rewardToken,
            _enquiry.stakeAToken,
            _enquiry.stakeBToken,
            _enquiry.startTime,
            _enquiry.endTime,
            _enquiry.userLimit,
            _enquiry.BACrossRate,
            _enquiry.maxRPTokenAMultiplier,
            _enquiry.tokenStakeThreshold,
            _enquiry.rpStakeThreshold,
            _enquiry.uri
        );
    }

    function addReward(uint256 _enquiryId, uint256 _reward)
        external
        payable
        enquiryExists(_enquiryId)
    {
        EnquiryLibV3.Enquiry storage enquiry = enquiries[_enquiryId];

        require(enquiries[_enquiryId].endTime >= block.timestamp, "OutsideAllowTime");

        require(_reward > 0, "ZeroReward");

        _transferInToken(msg.sender, enquiry.rewardToken, _reward);

        enquiry.reward += _reward;

        emit AddReward(_enquiryId, msg.sender, _reward);
    }

    function refundEnquiry(uint256 _enquiryId) external enquiryExists(_enquiryId) onlyOwner {
        EnquiryLibV3.Enquiry storage enquiry = enquiries[_enquiryId];

        uint256 remain = enquiry.reward;
        enquiry.userLimit = 0;
        enquiry.reward = 0;

        if (remain > 0) _transferOutToken(payable(enquiry.seeker), enquiry.rewardToken, remain);

        emit RefundEnquiry(_enquiryId, msg.sender, remain);
    }

    function verifyAnswer(
        address _expert,
        uint256 _enquiryId,
        bytes32 _tokenId,
        bytes32 _bidPrice,
        bytes32 _askPrice,
        address _stakeToken,
        uint256 _rp,
        uint256 _stakeAmount,
        string calldata _secret,
        bytes memory _signature
    ) public pure returns (bool) {
        require(_expert != address(0), "ZeroAddress");
        return
            keccak256(
                abi.encodePacked(
                    _enquiryId,
                    _tokenId,
                    _bidPrice,
                    _askPrice,
                    _stakeToken,
                    _rp,
                    _stakeAmount,
                    _secret
                )
            ).toEthSignedMessageHash().recover(_signature) == _expert;
    }

    function createAnswer(
        uint256 _enquiryId,
        uint8 _numOfTokenId,
        address _stakeToken,
        uint256 _rp,
        uint256 _stakeAmount,
        bytes calldata _signature
    ) external payable enquiryExists(_enquiryId) whenNotPaused nonReentrant {
        // check if answer exist
        require(!existsAnswer(_enquiryId, msg.sender), "AnswerExist");
        // check if the enquiry still allow people to create/update answer
        require(
            enquiries[_enquiryId].endTime >= block.timestamp &&
                enquiries[_enquiryId].startTime <= block.timestamp,
            "OutsideAllowTime"
        );

        // check if the enquiry user limit is over
        require(
            enquiries[_enquiryId].userLimit >= enquiries[_enquiryId].totalAnswer + 1,
            "OverUserLimit"
        );

        // check if the stake token
        require(
            enquiries[_enquiryId].stakeAToken == _stakeToken ||
                enquiries[_enquiryId].stakeBToken == _stakeToken,
            "StakeTokenIncorrect"
        );

        // check if answered too many
        require(
            _numOfTokenId > 0 && _numOfTokenId <= MAX_NUMBER_OF_ANSWER_PER_USER,
            "OutsideAnswerLimit"
        );

        // check stake ratio
        require(withinStakeLimits(_enquiryId, _stakeToken, _rp, _stakeAmount), "OutsideStakeLimit");

        // check signature and encrypted message cannot be empty
        require(_signature.length > 0, "EmptySignature");

        if (_stakeAmount > 0) _transferInToken(msg.sender, _stakeToken, _stakeAmount);

        if (_rp > 0)
            // burn the RP
            RP_TOKEN.burn(msg.sender, _rp);

        enquiries[_enquiryId].totalAnswer += 1;
        _addTotalStakedToken(_enquiryId, _stakeToken, _stakeAmount);
        enquiries[_enquiryId].totalStakedRp += _rp;

        answers[_enquiryId][msg.sender] = AnswerLibV3.Answer({
            stakeToken: _stakeToken,
            rp: _rp,
            signature: _signature,
            stakedAmount: _stakeAmount,
            claimed: false,
            revealed: false,
            tokenId: new uint256[](_numOfTokenId),
            bidPrice: new uint256[](_numOfTokenId),
            askPrice: new uint256[](_numOfTokenId)
        });

        emit CreateAnswer(
            _enquiryId,
            msg.sender,
            _numOfTokenId,
            _stakeToken,
            _rp,
            _stakeAmount,
            _signature
        );
    }

    function updateAnswer(
        uint256 _enquiryId,
        uint8 _numOfTokenId,
        uint256 _rp,
        uint256 _stakeAmount,
        bytes calldata _signature
    ) external payable whenNotPaused nonReentrant {
        // check if answer exist
        require(existsAnswer(_enquiryId, msg.sender), "AnswerNotExist");

        // check if the enquiry still allow people to create/update answer
        require(
            enquiries[_enquiryId].endTime >= block.timestamp &&
                enquiries[_enquiryId].startTime <= block.timestamp,
            "OutsideAllowTime"
        );

        require(
            _numOfTokenId > 0 && _numOfTokenId <= MAX_NUMBER_OF_ANSWER_PER_USER,
            "OutsideAnswerLimit"
        );

        uint256 rp = answers[_enquiryId][msg.sender].rp;
        address stakeToken = answers[_enquiryId][msg.sender].stakeToken;
        uint256 stakedAmount = answers[_enquiryId][msg.sender].stakedAmount;

        if (_stakeAmount == stakedAmount) require(msg.value == 0, "AmountNotMatch");

        if (_rp != rp || _stakeAmount != stakedAmount) {
            require(
                withinStakeLimits(_enquiryId, stakeToken, _rp, _stakeAmount),
                "OutsideStakeLimit"
            );

            uint256 amount;
            if (_rp > rp) {
                amount = _rp - rp;
                RP_TOKEN.burn(msg.sender, amount);
                answers[_enquiryId][msg.sender].rp = _rp;
                enquiries[_enquiryId].totalStakedRp += amount;
            } else if (_rp < rp) {
                amount = rp - _rp;
                answers[_enquiryId][msg.sender].rp = _rp;
                enquiries[_enquiryId].totalStakedRp -= amount;
                RP_TOKEN.mint(msg.sender, amount);
            }

            if (_stakeAmount > stakedAmount) {
                amount = _stakeAmount - stakedAmount;
                _transferInToken(msg.sender, stakeToken, amount);
                answers[_enquiryId][msg.sender].stakedAmount = _stakeAmount;
                _addTotalStakedToken(_enquiryId, stakeToken, amount);
            } else if (_stakeAmount < stakedAmount) {
                amount = stakedAmount - _stakeAmount;
                uint256 transferAmount = stakeToken == address(0) ? amount + msg.value : amount;
                answers[_enquiryId][msg.sender].stakedAmount = _stakeAmount;
                _subTotalStakedToken(_enquiryId, stakeToken, amount);
                _transferOutToken(payable(msg.sender), stakeToken, transferAmount);
            }
        }

        if (
            _signature.length > 0 &&
            keccak256(_signature) != keccak256(answers[_enquiryId][msg.sender].signature)
        ) answers[_enquiryId][msg.sender].signature = _signature;

        if (answers[_enquiryId][msg.sender].tokenId.length != _numOfTokenId) {
            answers[_enquiryId][msg.sender].tokenId = new uint256[](_numOfTokenId);
            answers[_enquiryId][msg.sender].bidPrice = new uint256[](_numOfTokenId);
            answers[_enquiryId][msg.sender].askPrice = new uint256[](_numOfTokenId);
        }

        emit UpdateAnswer(_enquiryId, msg.sender, _numOfTokenId, _rp, _stakeAmount, _signature);
    }

    function revealAnswer(
        uint256 _enquiryId,
        uint256[] calldata _tokenId,
        uint256[] calldata _bidPrice,
        uint256[] calldata _askPrice,
        string calldata _secret
    ) external enquiryExists(_enquiryId) nonReentrant {
        // check if answer exist
        require(existsAnswer(_enquiryId, msg.sender), "AnswerNotExist");
        // check if the enquiry still allow people to reveal answer
        require(
            enquiries[_enquiryId].endTime < block.timestamp &&
                enquiries[_enquiryId].endTime + MAX_REVEAL_ANSWER_BUFFER >= block.timestamp,
            "OutsideAllowTime"
        );

        AnswerLibV3.Answer storage answer = answers[_enquiryId][msg.sender];

        // check if answer reveal or not
        require(!answer.revealed, "AnswerRevealed");

        require(
            _bidPrice.length == _askPrice.length &&
                _askPrice.length == _tokenId.length &&
                _tokenId.length == answer.tokenId.length,
            "AnswerLengthIncorrect"
        );

        bytes32 bidPriceData = keccak256(abi.encodePacked(_bidPrice));

        bytes32 askPriceData = keccak256(abi.encodePacked(_askPrice));

        bytes32 tokenIdData = keccak256(abi.encodePacked(_tokenId));

        require(
            verifyAnswer(
                msg.sender,
                _enquiryId,
                tokenIdData,
                bidPriceData,
                askPriceData,
                answer.stakeToken,
                answer.rp,
                answer.stakedAmount,
                _secret,
                answer.signature
            ),
            "AnswerNotCorrect"
        );

        for (uint8 i = 0; i < _tokenId.length; i++) {
            answer.tokenId[i] = _tokenId[i];
            answer.bidPrice[i] = _bidPrice[i];
            answer.askPrice[i] = _askPrice[i];
        }

        answer.revealed = true;

        emit RevealAnswer(_enquiryId, msg.sender, _tokenId, _bidPrice, _askPrice);
    }

    function refundAnswer(uint256 _enquiryId) external nonReentrant {
        require(existsAnswer(_enquiryId, msg.sender), "AnswerNotExist");

        // check if enquiry cancelled or during commit answer time
        require(
            (enquiries[_enquiryId].endTime >= block.timestamp &&
                enquiries[_enquiryId].startTime <= block.timestamp) ||
                ((enquiries[_enquiryId].endTime + MAX_POST_RESULT_BUFFER < block.timestamp) &&
                    !existsEnquiryResult(_enquiryId)) ||
                (enquiries[_enquiryId].userLimit == 0),
            "RefundNotAllow"
        );

        AnswerLibV3.Answer storage answer = answers[_enquiryId][msg.sender];
        // check if the reward is claimed
        require(!answer.claimed, "RewardClaimed");

        address stakeToken = answer.stakeToken;
        uint256 stakedAmount = answer.stakedAmount;
        uint256 rp = answer.rp;

        //check if token stake token is zero after refund
        require(
            stakeToken == enquiries[_enquiryId].stakeAToken
                ? enquiries[_enquiryId].totalStakedAToken >= stakedAmount
                : enquiries[_enquiryId].totalStakedBToken >= stakedAmount &&
                    enquiries[_enquiryId].totalStakedRp >= rp,
            "StakeOverClaimed"
        );

        enquiries[_enquiryId].totalStakedRp -= rp;
        _subTotalStakedToken(_enquiryId, stakeToken, stakedAmount);
        enquiries[_enquiryId].totalAnswer -= 1;
        delete answers[_enquiryId][msg.sender];

        // refund the user
        if (stakedAmount > 0) _transferOutToken(payable(msg.sender), stakeToken, stakedAmount);

        if (rp > 0)
            // mint the RP
            RP_TOKEN.mint(msg.sender, rp);

        emit RefundAnswer(_enquiryId, msg.sender, rp, stakedAmount);
    }

    function verifyMerkleTree(
        bytes32 _root,
        bytes32[] calldata _proof,
        bytes calldata _data
    ) public pure returns (bool) {
        return MerkleProof.verify(_proof, _root, keccak256(_data));
    }

    function postResultRoot(uint256 _enquiryId, bytes32 _root)
        external
        enquiryExists(_enquiryId)
        onlyOwner
    {
        // check if the commit time has pass
        require(
            (enquiries[_enquiryId].endTime + MAX_REVEAL_ANSWER_BUFFER) < block.timestamp &&
                (enquiries[_enquiryId].endTime + MAX_POST_RESULT_BUFFER) >= block.timestamp,
            "OutsideAllowTime"
        );

        // check if the result exist
        require(!existsEnquiryResult(_enquiryId), "ResultExist");

        // check if the result has a valid merkle root
        require(_root != bytes32(0), "EmptyRoot");

        results[_enquiryId] = _root;

        emit ResultRoot(_enquiryId, msg.sender, _root);
    }

    function claimReward(
        uint256 _enquiryId,
        bytes32[] calldata _proof,
        bytes calldata _data
    ) external enquiryExists(_enquiryId) nonReentrant {
        // check if the result exist
        require(existsEnquiryResult(_enquiryId), "ResultNotExist");
        // check if the proof and leaf is valid
        require(verifyMerkleTree(results[_enquiryId], _proof, _data), "ProofOrLeafNotCorrect");

        (
            uint256 tokenReward,
            uint256 rpReward,
            uint256 stakeRp,
            address expert,
            bytes memory signature
        ) = abi.decode(_data, (uint256, uint256, uint256, address, bytes));

        // check if answer exist
        require(existsAnswer(_enquiryId, expert), "AnswerNotExist");

        AnswerLibV3.Answer storage answer = answers[_enquiryId][expert];

        // check if the stakedAmount is less than deposit
        require(answer.rp >= stakeRp, "StakeRpNotCorrect");

        // check if the answer is correct
        require(keccak256(answer.signature) == keccak256(signature), "SignatureNotCorrect");

        // check if the reward is claimed
        require(!answer.claimed, "RewardClaimed");

        EnquiryLibV3.Enquiry storage enquiry = enquiries[_enquiryId];

        answer.claimed = true;
        require(enquiry.reward >= tokenReward, "OverClaimed");
        if (tokenReward > 0) enquiries[_enquiryId].reward -= tokenReward;

        // add checking for rp minting max
        require(rpReward <= maxRewardRp, "OverRpRewardLimit");

        uint256 stakedAmount = answer.stakedAmount;
        //check if token stake token is zero after refund
        require(
            answer.stakeToken == enquiry.stakeAToken
                ? enquiry.totalStakedAToken >= stakedAmount
                : enquiry.totalStakedBToken >= stakedAmount && enquiry.totalStakedRp >= answer.rp,
            "StakeOverClaimed"
        );

        enquiry.totalStakedRp -= answer.rp;
        _subTotalStakedToken(_enquiryId, answer.stakeToken, stakedAmount);
        answer.stakedAmount = 0;
        answer.rp = 0;

        if (stakedAmount > 0) {
            // calculate the service fee
            uint256 serviceFee = (stakedAmount * stakeServiceFeeRate) /
                SERVICE_FEE_PRECISION_FACTOR;
            if (serviceFee > 0) _transferOutToken(payable(treasury), answer.stakeToken, serviceFee);
            // transfer the reward to the user
            _transferOutToken(payable(expert), answer.stakeToken, stakedAmount - serviceFee);
        }

        if (tokenReward > 0) {
            // calculate the service fee
            uint256 serviceFee = (tokenReward * rewardServiceFeeRate) /
                SERVICE_FEE_PRECISION_FACTOR;
            if (serviceFee > 0)
                _transferOutToken(payable(treasury), enquiry.rewardToken, serviceFee);
            // transfer the reward to the user
            _transferOutToken(payable(expert), enquiry.rewardToken, tokenReward - serviceFee);
        }

        uint256 claimRp = rpReward + stakeRp;
        if (claimRp > 0)
            // mint the RP
            RP_TOKEN.mint(expert, rpReward);

        emit ClaimReward(_enquiryId, expert, stakedAmount, tokenReward, stakeRp, rpReward);
    }

    function _addTotalStakedToken(
        uint256 _enquiryId,
        address _stakeToken,
        uint256 _stakeAmount
    ) internal {
        if (_stakeToken == enquiries[_enquiryId].stakeAToken) {
            enquiries[_enquiryId].totalStakedAToken += _stakeAmount;
        } else {
            enquiries[_enquiryId].totalStakedBToken += _stakeAmount;
        }
    }

    function _subTotalStakedToken(
        uint256 _enquiryId,
        address _stakeToken,
        uint256 _stakeAmount
    ) internal {
        if (_stakeToken == enquiries[_enquiryId].stakeAToken) {
            enquiries[_enquiryId].totalStakedAToken -= _stakeAmount;
        } else {
            enquiries[_enquiryId].totalStakedBToken -= _stakeAmount;
        }
    }

    function _transferOutToken(
        address payable _account,
        address _token,
        uint256 _amount
    ) internal {
        if (_token == address(0)) {
            // Transfer native token reward to seeker
            _account.sendValue(_amount);
        } else {
            // Transfer erc20 reward to the seeker
            IERC20(_token).safeTransfer(_account, _amount);
        }
    }

    function _transferInToken(
        address _account,
        address _token,
        uint256 _amount
    ) internal {
        if (_token == address(0)) {
            // check if the native token matches the transferred value
            require(msg.value == _amount, "AmountNotMatch");
        } else {
            // Transfer token to the contract for reward
            IERC20(_token).safeTransferFrom(_account, address(this), _amount);
        }
    }

    function getEnquiry(uint256 _enquiryId) external view returns (EnquiryLibV3.Enquiry memory) {
        return enquiries[_enquiryId];
    }

    function getResult(uint256 _enquiryId) external view returns (bytes32) {
        return results[_enquiryId];
    }

    function getAnswer(uint256 _enquiryId, address _account)
        external
        view
        returns (AnswerLibV3.Answer memory)
    {
        return answers[_enquiryId][_account];
    }

    function withinStakeLimits(
        uint256 _enquiryId,
        address _stakeToken,
        uint256 _rp,
        uint256 _stakeAmount
    ) public view returns (bool) {
        uint16 precision = MULTIPLIER_PRECISION_FACTOR;
        uint256 amount;

        if (enquiries[_enquiryId].stakeBToken == _stakeToken) {
            amount =
                (_stakeAmount * enquiries[_enquiryId].BACrossRate) /
                CROSS_RATE_PRECISION_FACTOR;
        } else {
            amount = _stakeAmount;
        }

        // check if the stake amount pass the lithThreshold and require to check ratio
        uint256 maxTokenStake = (_rp * enquiries[_enquiryId].maxRPTokenAMultiplier) / precision;
        uint256 maxRPStake = ((amount * precision) / enquiries[_enquiryId].maxRPTokenAMultiplier) +
            100000000;
        bool tokenCheck = amount <= enquiries[_enquiryId].tokenStakeThreshold ||
            amount <= maxTokenStake;
        bool rpCheck = _rp <= enquiries[_enquiryId].rpStakeThreshold || _rp <= maxRPStake;

        return tokenCheck && rpCheck;
    }

    function existsEnquiry(uint256 _enquiryId) public view returns (bool) {
        return enquiries[_enquiryId].seeker != address(0) && enquiries[_enquiryId].userLimit > 0;
    }

    function existsAnswer(uint256 _enquiryId, address _account) public view returns (bool) {
        return _account != address(0) && answers[_enquiryId][_account].signature.length > 0;
    }

    function existsEnquiryResult(uint256 _enquiryId) public view returns (bool) {
        return results[_enquiryId] != bytes32(0);
    }

    function setMaxRewardRP(uint64 _rp) public onlyOwner {
        require(_rp <= 1000000000000, "OverMax");
        maxRewardRp = _rp;
        emit SetMaxRewardRp(msg.sender, _rp);
    }

    function setRewardServiceFeeRate(uint32 _rate) public onlyOwner {
        require(_rate <= MAX_SERVICE_FEE_RATE, "OverMax");
        rewardServiceFeeRate = _rate;
        emit SetRewardServiceFeeRate(msg.sender, _rate);
    }

    function setStakeServiceFeeRate(uint32 _rate) public onlyOwner {
        require(_rate <= MAX_SERVICE_FEE_RATE, "OverMax");
        stakeServiceFeeRate = _rate;
        emit SetStakeServiceFeeRate(msg.sender, _rate);
    }

    function setTreasury(address _account) public onlyOwner {
        require(_account != address(0), "ZeroAddress");
        treasury = _account;
        emit SetTreasury(msg.sender, _account);
    }

    function togglePause() external onlyOwner {
        if (paused()) {
            _unpause();
        } else {
            _pause();
        }
    }
}
