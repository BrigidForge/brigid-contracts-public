// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title BrigidLaunchToken
/// @notice Fixed-supply ERC20 intended for Launchpad-driven deployments.
/// @dev Mints the full supply once in the constructor to the initial owner.
contract BrigidLaunchToken is ERC20, Ownable {
    uint8 private immutable _customDecimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address initialOwner_,
        uint256 initialSupply_
    ) ERC20(name_, symbol_) Ownable(initialOwner_) {
        require(initialOwner_ != address(0), "invalid owner");
        require(initialSupply_ > 0, "invalid supply");

        _customDecimals = decimals_;
        _mint(initialOwner_, initialSupply_);
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }
}
