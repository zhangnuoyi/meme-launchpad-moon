// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


interface IBondingCurveParams {
    struct BondingCurveParams {
        uint256 virtualBNBReserve; // 虚拟BNB储备量（Wei）
        uint256 virtualTokenReserve; // 虚拟代币储备量（Wei）
        uint256 maxSupply; // 最大供应量（Wei）
        uint256 k; // 曲线参数
        uint256 availableTokens; // 剩余可售代币数量（Wei）
        uint256 collectedBNB; // 毕业时用于添加 DEX 流动性（Wei）


    }
}