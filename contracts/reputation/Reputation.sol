// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IReputation} from "./interfaces/IReputation.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ABDKMath64x64} from "./libs/ABDKMath64x64.sol";

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 * For a generic mechanism see {ERC20PresetMinterPauser}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.zeppelin.solutions/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * We have followed general OpenZeppelin Contracts guidelines: functions revert
 * instead returning `false` on failure. This behavior is nonetheless
 * conventional and does not conflict with the expectations of ERC20
 * applications.
 *
 * Additionally, an {Approval} event is emitted on calls to {transferFrom}.
 * This allows applications to reconstruct the allowance for all accounts just
 * by listening to said events. Other implementations of the EIP may not emit
 * these events, as it isn't required by the specification.
 *
 * Finally, the non-standard {decreaseAllowance} and {increaseAllowance}
 * functions have been added to mitigate the well-known issues around setting
 * allowances. See {IERC20-approve}.
 */
contract Reputation is IReputation, Ownable {
    struct UserInfo {
        uint256 balance;
        uint256 lastActionTime;
    }

    mapping(address => UserInfo) private userInfo;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    uint32 private _burnRate;

    // Service fee rate %  4 decimal place
    uint32 constant RATE_PRECISION_FACTOR = 1e6;

    // address => first time join or not
    mapping(address => bool) public claimedAcc;

    // address => enquiry pool address
    mapping(address => bool) public enquiryPools;

    // merkle root for claiming
    bytes32 public root;

    event Mint(address indexed account, uint256 balance, uint256 reducedBalance, uint256 amount);

    event Burn(address indexed account, uint256 balance, uint256 reducedBalance, uint256 amount);

    event Claim(address account, uint256 reward);

    event SetEnquiryPool(address admin, address pool, bool active);

    event SetRoot(address admin, bytes32 root);

    event SetBurnRate(address admin, uint256 rate);

    modifier onlyEnquiryPool() {
        require(enquiryPools[msg.sender], "NotPermitted");
        _;
    }

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * The default value of {decimals} is 18. To select a different value for
     * {decimals} you should overload it.
     *
     * All two of these values are immutable: they can only be set once during
     * construction.
     */
    constructor(string memory name_, string memory symbol_, address _admin) {
        require(_admin != address(0), "ZeroAddress");
        _name = name_;
        _symbol = symbol_;

        // transfer ownership
        transferOwnership(_admin);
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view override returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the value {ERC20} uses, unless this function is
     * overridden;
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public pure override returns (uint8) {
        return 8;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view override returns (uint256) {
        if (userInfo[account].balance == 0) return 0;
        uint256 day = (block.timestamp - userInfo[account].lastActionTime) / (1 days);

        int128 factor = ABDKMath64x64.div(
            ABDKMath64x64.mul(ABDKMath64x64.fromUInt(_burnRate), ABDKMath64x64.fromUInt(day)),
            ABDKMath64x64.fromUInt(365)
        );
        return
            ABDKMath64x64.mulu(
                ABDKMath64x64.exp(
                    ABDKMath64x64.neg(
                        ABDKMath64x64.div(factor, ABDKMath64x64.fromUInt(RATE_PRECISION_FACTOR))
                    )
                ),
                userInfo[account].balance
            );
    }

    function lastActionTimeOf(address account) external view override returns (uint256) {
        return userInfo[account].lastActionTime;
    }

    function burnRate() external view override returns (uint32) {
        return _burnRate;
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     */
    function mint(address account, uint256 amount) external override onlyEnquiryPool {
        _mint(account, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "RP: mint to the zero address");

        uint256 accountBalance = userInfo[account].balance;
        uint256 reducedBalance = balanceOf(account);

        _totalSupply = _totalSupply - accountBalance + amount + reducedBalance;
        userInfo[account].balance = reducedBalance + amount;
        userInfo[account].lastActionTime = block.timestamp;

        emit Mint(account, accountBalance, reducedBalance, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function burn(address account, uint256 amount) external override onlyEnquiryPool {
        _burn(account, amount);
    }

    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "RP: burn from the zero address");

        uint256 accountBalance = userInfo[account].balance;
        uint256 reducedBalance = balanceOf(account);
        require(reducedBalance >= amount, "RP: burn amount exceeds balance");

        unchecked {
            userInfo[account].balance = reducedBalance - amount;
        }
        _totalSupply = _totalSupply - accountBalance + reducedBalance - amount;
        userInfo[account].lastActionTime = block.timestamp;

        emit Burn(account, accountBalance, reducedBalance, amount);
    }

    function setBurnRate(uint32 _rate) external onlyOwner {
        // max rate is 1200%
        require(_rate <= 12 * RATE_PRECISION_FACTOR, "OverMax");
        _burnRate = _rate;
        emit SetBurnRate(msg.sender, _rate);
    }

    function setEnquiryPool(address _pool, bool _active) external onlyOwner {
        require(_pool != address(0), "ZeroAddress");
        enquiryPools[_pool] = _active;
        emit SetEnquiryPool(msg.sender, _pool, _active);
    }

    function setRoot(bytes32 _root) external onlyOwner {
        // the root can only be set 1 time only
        require(root == bytes32(0), "RootExist");

        // check if the result has a valid merkle root
        require(_root != bytes32(0), "EmptyRoot");

        root = _root;

        emit SetRoot(msg.sender, _root);
    }

    function claim(bytes32[] memory _proof, bytes memory _data) external {
        // check if the proof and leaf is valid
        require(MerkleProof.verify(_proof, root, keccak256(_data)), "ProofOrLeafNotCorrect");

        (uint256 reward, address account) = abi.decode(_data, (uint256, address));
        // check if claimed already or not
        require(!claimedAcc[account], "ClaimedAlready");

        claimedAcc[account] = true;
        _mint(account, reward);

        emit Claim(account, reward);
    }
}
