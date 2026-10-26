// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Derives the storage keys of the rate limits of a Midnight Managed Account.
library LimitKeys {
    enum LimitKind {
        BorrowUnits,
        TokenBorrowUnits,
        BorrowAssetsOut,
        LendAssets,
        TokenLendAssets,
        WithdrawAssets,
        RepayAssets,
        CollateralAssetsIn,
        CollateralAssetsOut
    }

    function borrowUnits(bytes32 marketId) internal pure returns (bytes32) {
        return keccak256(abi.encode(LimitKind.BorrowUnits, marketId));
    }

    function borrowUnits(bytes32 marketId, address operator) internal pure returns (bytes32) {
        return keccak256(abi.encode(LimitKind.BorrowUnits, marketId, operator));
    }

    /// @dev Aggregated across all markets of the loan token.
    function tokenBorrowUnits(address loanToken) internal pure returns (bytes32) {
        return keccak256(abi.encode(LimitKind.TokenBorrowUnits, loanToken));
    }

    function borrowAssetsOut(bytes32 marketId, address receiver) internal pure returns (bytes32) {
        return keccak256(abi.encode(LimitKind.BorrowAssetsOut, marketId, receiver));
    }

    function lendAssets(bytes32 marketId) internal pure returns (bytes32) {
        return keccak256(abi.encode(LimitKind.LendAssets, marketId));
    }

    function lendAssets(bytes32 marketId, address operator) internal pure returns (bytes32) {
        return keccak256(abi.encode(LimitKind.LendAssets, marketId, operator));
    }

    /// @dev Aggregated across all markets of the loan token.
    function tokenLendAssets(address loanToken) internal pure returns (bytes32) {
        return keccak256(abi.encode(LimitKind.TokenLendAssets, loanToken));
    }

    function withdrawAssets(bytes32 marketId, address receiver) internal pure returns (bytes32) {
        return keccak256(abi.encode(LimitKind.WithdrawAssets, marketId, receiver));
    }

    function repayAssets(bytes32 marketId) internal pure returns (bytes32) {
        return keccak256(abi.encode(LimitKind.RepayAssets, marketId));
    }

    /// @dev Per collateral token, since amounts of different tokens are not comparable.
    function collateralAssetsIn(bytes32 marketId, address token) internal pure returns (bytes32) {
        return keccak256(abi.encode(LimitKind.CollateralAssetsIn, marketId, token));
    }

    function collateralAssetsOut(bytes32 marketId, address token, address receiver) internal pure returns (bytes32) {
        return keccak256(abi.encode(LimitKind.CollateralAssetsOut, marketId, token, receiver));
    }
}
