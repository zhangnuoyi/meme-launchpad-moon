// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
/**
 * @title IVestingParams
 * @notice 代币归属（锁仓释放）参数接口
 * 
 * ============ 什么是代币归属？============
 * 归属（Vesting）是一种代币锁定机制：
 * - 代币在一段时间内逐步解锁
 * - 防止创建者立即抛售全部代币
 * - 保护普通投资者利益
 * 
 * ============ 本项目的归属场景 ============
 * 当创建者在发币时选择"初始买入"，可配置归属计划：
 * 1. BURN：直接销毁，减少总供应量
 * 2. CLIFF：悬崖期，到期后一次性解锁
 * 3. LINEAR：线性释放，按时间比例逐步解锁
 */

 interface IVestingParams{

    enum VestingMode {
        BURN, // 销毁模式
        CLIFF, // 悬崖模式
        LINEAR // 线性模式
    }

    struct VestingAllocation {
        uint256 amount; // 归属金额
        uint256 launchTime; // 归属开始时间（秒）
        VestingMode mode; // 归属模式
        uint256 cliff; // 悬崖期（秒）
        uint256 duration; // 归属期（秒）
    }
 }

