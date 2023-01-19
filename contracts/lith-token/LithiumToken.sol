// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
import "./token/ERC20.sol";

/**
 * @title LithiumToken
 *
 * @dev A minimal ERC20 token contract for the Lithium token.
 */
contract LithiumToken is ERC20("Lithium", "LITH") {
    uint256 private constant TOTAL_SUPPLY = 10000000000e18;

    constructor(address genesis_holder) {
        require(genesis_holder != address(0), "LithiumToken: zero address");
        _mint(genesis_holder, TOTAL_SUPPLY);
    }
}
