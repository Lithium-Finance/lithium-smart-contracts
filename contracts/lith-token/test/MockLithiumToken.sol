// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
import "../token/ERC20.sol";

/**
 * @title LithiumToken
 *
 * @dev A minimal ERC20 token contract for the Lithium token.
 */
contract MockLithiumToken is ERC20("MockLithium", "MLITH") {
    function mint(address account, uint256 amount) public {
        _mint(account, amount);
    }
}
