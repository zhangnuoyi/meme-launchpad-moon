// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IMEMEVesting} from "./interfaces/IMEMEVesting.sol";

/**
 * @title MEMEVesting
 * @author MetaNode Team
 * @notice 代币归属（锁仓释放）合约
 * 
 * ============ 合约概述 ============
 * 管理 MEME 代币的锁仓和释放机制。
 * 当创建者在发币时进行"初始买入"，可以选择将部分代币锁定，
 * 按照指定的模式和时间表逐步释放。
 * 
 * ============ 归属模式 ============
 * 
 * 【BURN - 销毁模式】
 * 代币在创建时被永久销毁，不会释放给任何人。
 * 用于通缩机制，提升剩余代币价值。
 * 
 * 【CLIFF - 悬崖模式】
 * 代币在整个归属期内完全锁定，到期后一次性全部解锁。
 * 适用于确保创建者长期持有的场景。
 * 
 * 时间线：
 * |------- 锁定期 -------|一次性全部解锁
 * 
 * 【LINEAR - 线性模式】
 * 代币从开始时间到结束时间按比例逐步解锁。
 * 可领取数量 = 总量 × (已过时间 / 总时长) - 已领取数量
 * 
 * 时间线：
 * |------- 逐步释放 -------|
 * 10% 20% 30% ... 90% 100%
 * 
 * ============ 存储结构 ============
 * 
 * vestingSchedules[token][beneficiary][scheduleId] = VestingSchedule
 * 
 * 每个用户可以对同一代币有多个归属计划，
 * 每个计划独立计算可领取数量。
 * 
 * ============ 调用流程 ============
 * 
 * 1. MEMECore.createToken() 创建代币时
 *    → 调用 createVestingSchedules() 创建归属计划
 *    
 * 2. 受益人等待归属期
 *    → 调用 getClaimableAmount() 查看可领取数量
 *    
 * 3. 受益人领取代币
 *    → 调用 claim() 或 claimAll() 领取
 */

 contract MEMEVesting is IMEMEVesting , Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
//角色常量

    //管理员角色
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    //操作者角色
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
      /**
     * @notice 归属计划存储
     * @dev token地址 => 受益人地址 => 计划ID => VestingSchedule
     * 每个受益人可以有多个独立的归属计划
     */
     mapping(address => mapping(address => mapping(uint256 => VestingSchedule))) public vestingSchedules;

       /**
     * @notice 归属计划计数
     * @dev token地址 => 受益人地址 => 计划数量
     * 用于分配新的计划ID（自增）
     */
     mapping(address => mapping(address => uint256)) public vestingScheduleCount;

       /**
     * @notice 用户总归属数量
     * @dev token地址 => 受益人地址 => 总归属代币数
     * 便于快速查询用户的归属总量
     */

     mapping(address => mapping(address => uint256)) public totalVestedAmount;

     
    /**
     * @notice 合约锁定总量
     * @dev token地址 => 合约内锁定的代币总量
     * 用于紧急提款时的余额校验
     */
     mapping(address => uint256) public totalTokenLocked;


    constructor() {
        _disableInitializers(); // 禁用初始化函数，防止合约被初始化
    }

     /**
     * @notice 初始化归属合约
     * @dev 仅在代理部署时调用一次
     * 
     * @param _admin 管理员地址
     * @param _operator 操作员地址（通常是 MEMECore）
     */
     function initialize(address _admin,address _operator) initializer public {
        __AccessControl_init(); // 初始化访问控制合约
        __Pausable_init(); // 初始化暂停合约
        __ReentrancyGuard_init(); // 初始化重入守卫合约
        __UUPSUpgradeable_init(); // 初始化 UUPS 升级合约

        // 授予管理员角色
        _grantRole(ADMIN_ROLE, _admin);
        // 授予操作者角色
        _grantRole(OPERATOR_ROLE, _operator);
        //授予默认管理员角色
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
     }


     // ============ 核心业务函数 ============

    /**
     * @notice 批量创建归属计划
     * @dev 仅限 OPERATOR_ROLE（MEMECore）调用
     * 
     * @param token 代币地址
     * @param beneficiary 受益人地址
     * @param allocations 归属分配数组
     * @return scheduleIds 创建的计划ID数组
     * 
     * ============ 执行流程 ============
     * 
     * 1. 【参数校验】
     *    - token 和 beneficiary 非零地址
     *    - allocations 数组非空
     * 
     * 2. 【计算总量】
     *    - 累加所有非 BURN 分配的代币数量
     *    - BURN 模式的代币在 MEMECore 中已销毁，不转入
     * 
     * 3. 【转入代币】
     *    - 从调用者（MEMECore）转入总归属代币
     * 
     * 4. 【创建计划】
     *    - 为每个分配创建独立的 VestingSchedule
     *    - 分配唯一的 scheduleId
     *    - 设置开始时间和结束时间
     * 
     * 5. 【更新统计】
     *    - 更新用户总归属数量
     *    - 更新合约锁定总量
     */


     function  createVestingSchedules(
        address token,
        address beneficiary,
        VestingAllocation[] calldata allocations
    ) external onlyRole(OPERATOR_ROLE) returns (uint256[] memory scheduleIds) {
        // 校验参数
        if(token == address(0) || beneficiary == address(0)){
           revert InvalidAddressParameters(); 
        }
       if(allocations.length == 0){
           revert InvalidLengthParameters();
       }

        // 计算总归属数量
        uint256 totalVested = 0;
        for (uint256 i = 0; i < allocations.length; i++) {
            if (allocations[i].mode != VestingMode.BURN) {
                totalVested += allocations[i].amount;
            }
        }
        require(totalVested > 0, "Total vested amount must be greater than zero");

        // 从 MEMECore 转入总归属代币
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalVested);
        //创建计划

        for (uint256 i = 0; i < allocations.length; i++) {
            VestingAllocation memory allocation = allocations[i];
         
                // 创建归属计划
                uint256 scheduleId = vestingScheduleCount[token][beneficiary]++;
            // 计算时间
            if(allocation.startTime == 0){
                allocation.startTime = block.timestamp;
            }
            if(allocation.endTime == 0){
                allocation.endTime = allocation.startTime + allocation.duration;
            }

                vestingSchedules[token][beneficiary][scheduleId] = VestingSchedule({
                    amount: allocation.amount,
                    startTime: allocation.startTime,
                    endTime: allocation.endTime,
                    cliffTime: allocation.cliffTime,
                    revoked: false,
                    cliffAmount: 0,
                    mode: allocation.mode
                });
                scheduleIds[i] = scheduleId;
                // 更新总归属数量
                totalVestedAmount[token][beneficiary] += allocation.amount;
                // 更新合约锁定总量
                 if (allocation.mode != VestingMode.BURN) {
                    totalTokenLocked[token] += allocation.amount;
                 }
                 emit VestingScheduleCreated(
                    token,
                    beneficiary,
                    scheduleId,
                    allocation.amount,
                    allocation.startTime,
                    allocation.endTime
                );
        }
      
}
 /**
     * @notice 领取单个归属计划的代币
     * @dev 防重入保护
     * 
     * @param token 代币地址
     * @param scheduleId 计划ID
     * @return claimableAmount 实际领取的数量
     * 
     * ============ 执行流程 ============
     * 
     * 1. 【读取计划】
     *    - 获取指定的 VestingSchedule
     *    - 验证计划存在且未撤销
     * 
     * 2. 【计算可领取】
     *    - 调用 _calculateClaimableAmount
     *    - BURN 模式返回 0
     *    - CLIFF 模式：未到期=0，到期后=全部
     *    - LINEAR 模式：按时间比例计算
     * 
     * 3. 【更新状态】
     *    - 增加已领取数量
     *    - 减少合约锁定总量
     * 
     * 4. 【转移代币】
     *    - 将可领取代币转给调用者
     */

     function _claim(
        address token,
        uint256 scheduleId
    ) external  returns (uint256 claimableAmount) {
        // 读取计划
        VestingSchedule storage schedule = vestingSchedules[token][msg.sender][scheduleId];
        if (schedule.totalAmount == 0) revert ScheduleNotFound();
        if (schedule.revoked) revert ScheduleRevoked();

        //计算可领取
        claimableAmount = _calculateClaimableAmount(schedule);
        if (claimableAmount == 0) revert NoClaimableAmount();
        // 更新状态
        schedule.claimedAmount += claimableAmount;
        totalTokenLocked[token] -= claimableAmount;
      
        emit TokensClaimed(token, msg.sender, scheduleId, claimableAmount);
          // 转移代币
        
    }
    function claim(
        address token,
        uint256 scheduleId
    ) external override nonReentrant whenNotPaused  returns (uint256 claimableAmount){
        claimableAmount = _claim(token, scheduleId);
       IERC20(token).safeTransfer(msg.sender, claimableAmount);
    }

    
 /**
     * @notice 领取所有归属计划的代币
     * @dev 遍历所有计划，一次性领取全部可领取代币
     * 
     * @param token 代币地址
     * @return totalClaimed 总领取数量
     */

     function claimAll(address token) external override nonReentrant whenNotPaused returns (uint256 totalClaimed) {
        uint256 scheduleCount = vestingScheduleCount[token][msg.sender];
        for (uint256 i = 0; i < scheduleCount; i++) {
            totalClaimed += _claim(token, i);
        }
        emit AllTokensClaimed(token, msg.sender, totalClaimed);
        // 转移代币
        IERC20(token).safeTransfer(msg.sender, totalClaimed);
    }


// ============ 内部函数 ============

    /**
     * @notice 计算归属计划的可领取数量
     * @dev 根据模式和时间计算
     * 
     * @param schedule 归属计划
     * @return 可领取代币数量
     * 
     * ============ 计算逻辑 ============
     * 
     * 【BURN 模式】
     * 始终返回 0（代币已销毁）
     * 
     * 【时间未开始】
     * 当前时间 <= startTime → 返回 0
     * 
     * 【已完全解锁】
     * 当前时间 >= endTime → vestedAmount = totalAmount
     * 
     * 【进行中 - CLIFF】
     * 返回 0（等待到期）
     * 
     * 【进行中 - LINEAR】
     * vestedAmount = totalAmount × (当前时间 - 开始时间) / (结束时间 - 开始时间)
     * 
     * 【最终计算】
     * claimable = vestedAmount - claimedAmount
     */
     function _calculateClaimableAmount(
        VestingSchedule storage schedule
    ) private view returns (uint256) {
        //Burn 模式不可以l领取
        if (schedule.mode == VestingMode.BURN) return 0;

        //时间判断
        uint256 currentTime = block.timestamp;
        if (currentTime <= schedule.startTime) return 0;

        if (currentTime >= schedule.endTime) return schedule.totalAmount;

        if (schedule.mode == VestingMode.CLIFF && currentTime < schedule.cliffTime) return 0;
        uint256 vestedAmount = schedule.totalAmount * (currentTime - schedule.startTime) / (schedule.endTime - schedule.startTime);
        return vestedAmount - schedule.claimedAmount;
    }

      // ============ 查询函数 ============

    /**
     * @notice 获取归属计划详情
     */

     function getVestingSchedule(
        address token,
        address beneficiary,
        uint256 scheduleId
    ) external view returns (VestingSchedule memory) {
        return vestingSchedules[token][beneficiary][scheduleId];
    }


  /**
     * @notice 获取用户的归属计划数量
     */

     function getVestingScheduleCount(
        address token,
        address beneficiary
    ) external view returns (uint256) {
        return vestingScheduleCount[token][beneficiary];
    }

    /**
     * @notice 获取用户的归属计划数量
     */
     function getClaimableAmount(address token,address beneficiary,uint256 scheduleId)
        external view returns (uint256) {
            VestingSchedule memory schedule = vestingSchedules[token][beneficiary][scheduleId];

            if (schedule.totalAmount == 0 || schedule.revoked) return 0;
        return _calculateClaimableAmount(schedule);
    }

    /**
     * @notice 获取用户的所有归属计划的可领取总量
     */

     function getTotalClaimableAmount(address token,address beneficiary) external view returns (uint256 totalClaimable) {
        uint256 count = vestingScheduleCount[token][beneficiary];
        for (uint256 i = 0; i < count; i++) {
            VestingSchedule memory schedule = vestingSchedules[token][beneficiary][i];
            if (schedule.totalAmount > 0 && !schedule.revoked) {
                totalClaimable += _calculateClaimableAmount(schedule);
            }
        }

           /**
     * @notice 获取归属统计信息
     * @return vested 已解锁数量（可领取+已领取）
     * @return claimed 已领取数量
     * @return locked 仍锁定数量（未解锁）
     */

     function getTotalVestedAmount (address token,address beneficiary)
      external view returns (uint256 vested, uint256 claimed, uint256 locked) {
        uint256 count = vestingScheduleCount[token][beneficiary];
        for (uint256 i = 0; i < count; i++) {
            VestingSchedule memory schedule = vestingSchedules[token][beneficiary][i];
            if (schedule.totalAmount > 0 && !schedule.revoked) {
                if (schedule.mode == VestingMode.BURN) continue;
                 uint256 vestedForSchedule;
                 if(block.timestamp >= schedule.endTime) {
                    vestedForSchedule = schedule.totalAmount;
                 } else if (block.timestamp >= schedule.startTime) {
                    if(schedule.mode == VestingMode.CLIFF ){
                        uint256 timePassed = block.timestamp- schedule.startTime;
                        uint256 totalDuration = schedule.endTime - schedule.startTime;
                        vestedForSchedule = (schedule.totalAmount * timePassed) / totalDuration;
                    }
                 }

                vested += vestedForSchedule;
                claimed += schedule.claimedAmount;
                locked += schedule.totalAmount - vested - claimed;
            }
        }
        return (vested, claimed, locked);
    }
