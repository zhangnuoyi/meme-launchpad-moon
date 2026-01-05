// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import { IMEMEFactory } from "./interfaces/IMEMEFactory.sol";
import { MetaNodeToken } from "./MEMEToken.sol";
/**
 * @title MEMEFactory
 * @author MetaNode Team
 * @notice 代币工厂合约 - 负责部署新的 MetaNodeToken
 * 
 * ============ 合约职责 ============
 * 1. 使用 CREATE2 部署代币（地址可预测）
 * 2. 管理部署权限（仅 MEMECore 可调用）
 * 3. 提供地址预测功能
 * 
 * ============ CREATE2 机制说明 ============
 * 普通 CREATE：地址 = hash(deployer, nonce) → 不可预测
 * CREATE2：address = hash(0xff, factory, salt, bytecodeHash) → 可预测
 * 
 * 优势：
 * - 前端可提前计算代币地址
 * - 相同参数 → 相同地址（确定性）
 * - 防止地址抢注
 * 
 * ============ 安全设计 ============
 * - 使用 AccessControl 管理权限
 * - DEPLOYER_ROLE 仅授予 MEMECore
 * - 盐值包含多个参数防止碰撞
 */

 contract MEMEFactory is IMEMEFactory ,AccessControl {

//状态变量

    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

    address public metaNode;//MetaNodeToken 合约地址

    constructor(address _metaNode) {
        metaNode = _metaNode;
        _grantRole(DEPLOYER_ROLE, _metaNode);
    }

    // ============ 核心函数 ============

    /**
     * @notice 部署新的 MetaNodeToken 合约
     * @dev 仅限 DEPLOYER_ROLE（MEMECore）调用
     * 
     * @param name 代币名称（如 "Doge Coin"）
     * @param symbol 代币符号（如 "DOGE"）
     * @param totalSupply 总供应量（包含18位小数，如 1000000e18）
     * @param timestamp 时间戳（用于盐值计算，防止碰撞）
     * @param nonce 随机数（用于盐值计算，防止碰撞）
     * @return 新部署的代币合约地址
     * 
     * ============ 执行流程 ============
     * 1. 计算盐值：hash(name, symbol, totalSupply, metaNode, timestamp, nonce)
     * 2. 使用 CREATE2 部署 MetaNodeToken
     * 3. MetaNodeToken 构造函数将所有代币铸造给 metaNode
     * 4. 触发 TokenDeployed 事件
     * 
     * ============ 注意事项 ============
     * - 相同参数会产生相同地址（如已部署则失败）
     * - metaNode 必须已设置
     */

     function deployToken(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        uint256 timestamp,
        uint256 nonce
     ) external onlyRole(DEPLOYER_ROLE) returns (address) {
        // 计算盐值
        bytes32 salt = keccak256(
            abi.encodePacked(name, symbol, totalSupply, metaNode, timestamp, nonce)
        );

        //部署MetaNodeToken合约
        address tokenAddress = address(
            new MetaNodeToken{salt: salt}(
                name,
                symbol,
                totalSupply,
                metaNode
            )
        );
        // 触发 TokenDeployed 事件
        emit TokenDeployed(tokenAddress, name, symbol, totalSupply, metaNode, timestamp, nonce);

        return tokenAddress;
     }

     /**
     * @notice 预测代币部署地址（不消耗 gas）
     * @dev 使用 CREATE2 公式计算，可在前端调用
     * 
     * @param name 代币名称
     * @param symbol 代币符号
     * @param totalSupply 总供应量
     * @param owner 代币接收者（通常是 metaNode）
     * @param timestamp 时间戳
     * @param nonce 随机数
     * @return 预测的合约地址
     * 
     * ============ CREATE2 地址计算公式 ============
     * address = keccak256(
     *     0xff,           // 固定前缀
     *     factory,        // 工厂合约地址
     *     salt,           // 盐值
     *     bytecodeHash    // 合约字节码哈希
     * )
     * 
     * 注意：bytecodeHash 包含构造函数参数
     */

     function predictTokenAddress(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        uint256 timestamp,
        uint256 nonce
     ) public view returns (address) {
        // 计算盐值
        bytes32 salt = keccak256(
            abi.encodePacked(name, symbol, totalSupply, metaNode, timestamp, nonce)
        );

       // 计算 CREATE2 地址
        bytes32 hash = keccak256(abi.encodePacked(
            bytes1(0xff),                    // CREATE2 前缀
            address(this),                   // 工厂合约地址
            salt,                            // 盐值
            keccak256(abi.encodePacked(
                type(MetaNodeToken).creationCode,  // 合约字节码
                abi.encode(name, symbol, totalSupply, owner)  // 构造函数参数
            ))
        ));

        return address(uint160(uint256(hash)));
     }  
   // ============ 管理函数 ============

    /**
     * @notice 设置 MetaNode 核心合约地址
     * @dev 仅限 DEFAULT_ADMIN_ROLE 调用
     * 
     * @param _metaNode 新的核心合约地址
     * 
     * ============ 执行流程 ============
     * 1. 校验非零地址
     * 2. 授予 _metaNode DEPLOYER_ROLE
     * 3. 更新 metaNode 状态变量
     * 
     * 注意：
     * - 旧地址的 DEPLOYER_ROLE 不会自动撤销
     * - 建议在初始化时调用一次
     */

     function setMetaNode(address _metaNode) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // 校验非零地址
        require(_metaNode != address(0), "Invalid metaNode address");

        // 授予 DEPLOYER_ROLE
        _grantRole(DEPLOYER_ROLE, _metaNode);

        // 更新 metaNode 状态变量
        metaNode = _metaNode;

        // 触发 MetaNodeUpdated 事件
        emit MetaNodeUpdated(_metaNode);
     }
 }