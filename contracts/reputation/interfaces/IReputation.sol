// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IReputation {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);

    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Returns the time of user last action owned by `account`.
     */
    function lastActionTimeOf(address account) external view returns (uint256);

    /**
     * @dev Returns the burn rate of the rp token.
     */
    function burnRate() external view returns (uint32);

    function mint(address account, uint256 amount) external;

    function burn(address account, uint256 amount) external;
}
