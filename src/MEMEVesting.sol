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
contract MEMEVesting is IMEMEVesting, Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // ============ 角色常量 ============

    /**
     * @notice 管理员角色
     * @dev 权限：参数配置、紧急操作、撤销归属计划
     */
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /**
     * @notice 操作员角色
     * @dev 权限：创建归属计划
     * 通常授予 MEMECore 合约
     */
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ============ 存储映射 ============

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
    mapping(address => mapping(address => uint256)) public scheduleCount;

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

    // ============ 构造函数 ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ 初始化函数 ============

    /**
     * @notice 初始化归属合约
     * @dev 仅在代理部署时调用一次
     * 
     * @param _admin 管理员地址
     * @param _operator 操作员地址（通常是 MEMECore）
     */
    function initialize(
        address _admin,
        address _operator
    ) public initializer {
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _operator);
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
    function createVestingSchedules(
        address token,
        address beneficiary,
        VestingAllocation[] calldata allocations
    ) external override onlyRole(OPERATOR_ROLE) whenNotPaused returns (uint256[] memory scheduleIds) {
        // 1. 参数校验
        if (token == address(0) || beneficiary == address(0)) revert InvalidAddressParameters();
        if (allocations.length == 0) revert InvalidLengthParameters();

        scheduleIds = new uint256[](allocations.length);
        
        // 2. 计算总量
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < allocations.length; i++) {
            if (allocations[i].mode != VestingMode.BURN) {
                if (allocations[i].amount == 0) revert InvalidAmountParameters();
                totalAmount += allocations[i].amount;
            }
        }
        
        // 3. 转入代币
        if (totalAmount > 0) {
            IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);
        }
        
        // 4. 创建计划
        for (uint256 i = 0; i < allocations.length; i++) {
            // 分配新的计划ID
            uint256 scheduleId = scheduleCount[token][beneficiary];
            scheduleCount[token][beneficiary]++;

            // 计算时间
            uint256 startTime = allocations[i].launchTime;
            if (startTime == 0) {
                startTime = block.timestamp;
            }
            uint256 endTime = startTime + allocations[i].duration;

            // 创建归属计划
            vestingSchedules[token][beneficiary][scheduleId] = VestingSchedule({
                totalAmount: allocations[i].amount,
                startTime: startTime,
                endTime: endTime,
                claimedAmount: 0,
                revoked: false,
                mode: allocations[i].mode
            });

            scheduleIds[i] = scheduleId;
            
            // 5. 更新统计
            totalVestedAmount[token][beneficiary] += allocations[i].amount;
            if (allocations[i].mode != VestingMode.BURN) {
                totalTokenLocked[token] += allocations[i].amount;
            }

            emit VestingScheduleCreated(
                token,
                beneficiary,
                scheduleId,
                allocations[i].amount,
                startTime,
                endTime
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
    function claim(
        address token,
        uint256 scheduleId
    ) public override nonReentrant whenNotPaused returns (uint256 claimableAmount) {
        // 1. 读取计划
        VestingSchedule storage schedule = vestingSchedules[token][msg.sender][scheduleId];
        if (schedule.totalAmount == 0) revert ScheduleNotFound();
        if (schedule.revoked) revert ScheduleRevoked();
        
        // 2. 计算可领取
        claimableAmount = _calculateClaimableAmount(schedule);
        if (claimableAmount == 0) revert NoClaimableAmount();
        
        // 3. 更新状态
        schedule.claimedAmount += claimableAmount;
        totalTokenLocked[token] -= claimableAmount;
        
        // 4. 转移代币
        IERC20(token).safeTransfer(msg.sender, claimableAmount);
        emit TokensClaimed(token, msg.sender, scheduleId, claimableAmount);
    }

    /**
     * @notice 领取所有归属计划的代币
     * @dev 遍历所有计划，一次性领取全部可领取代币
     * 
     * @param token 代币地址
     * @return totalClaimed 总领取数量
     */
    function claimAll(
        address token
    ) external override nonReentrant whenNotPaused returns (uint256 totalClaimed) {
        uint256 count = scheduleCount[token][msg.sender];

        for (uint256 i = 0; i < count; i++) {
            VestingSchedule storage schedule = vestingSchedules[token][msg.sender][i];
            if (schedule.totalAmount == 0 || schedule.revoked) continue;
            
            uint256 claimableAmount = _calculateClaimableAmount(schedule);
            if (claimableAmount > 0) {
                schedule.claimedAmount += claimableAmount;
                totalTokenLocked[token] -= claimableAmount;
                totalClaimed += claimableAmount;
                emit TokensClaimed(token, msg.sender, i, claimableAmount);
            }
        }

        if (totalClaimed > 0) {
            IERC20(token).safeTransfer(msg.sender, totalClaimed);
        }
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
        VestingSchedule memory schedule
    ) private view returns (uint256) {
        // BURN 模式不可领取
        if (schedule.mode == VestingMode.BURN) {
            return 0;
        }
        
        // 未开始
        if (block.timestamp <= schedule.startTime) {
            return 0;
        }
        
        uint256 vestedAmount;
        
        // 已完全解锁
        if (block.timestamp >= schedule.endTime) {
            vestedAmount = schedule.totalAmount;
        } else {
            // 进行中
            if (schedule.mode == VestingMode.CLIFF) {
                // CLIFF：未到期返回 0
                vestedAmount = 0;
            } else if (schedule.mode == VestingMode.LINEAR) {
                // LINEAR：按时间比例
                uint256 timePassed = block.timestamp - schedule.startTime;
                uint256 totalDuration = schedule.endTime - schedule.startTime;
                vestedAmount = (schedule.totalAmount * timePassed) / totalDuration;
            }
        }
        
        // 扣除已领取
        return vestedAmount > schedule.claimedAmount ? vestedAmount - schedule.claimedAmount : 0;
    }

    // ============ 查询函数 ============

    /**
     * @notice 获取归属计划详情
     */
    function getVestingSchedule(
        address token,
        address beneficiary,
        uint256 scheduleId
    ) external view override returns (VestingSchedule memory) {
        return vestingSchedules[token][beneficiary][scheduleId];
    }

    /**
     * @notice 获取用户的归属计划数量
     */
    function getVestingScheduleCount(
        address token,
        address beneficiary
    ) external view override returns (uint256) {
        return scheduleCount[token][beneficiary];
    }

    /**
     * @notice 获取单个计划的可领取数量
     */
    function getClaimableAmount(
        address token,
        address beneficiary,
        uint256 scheduleId
    ) external view override returns (uint256) {
        VestingSchedule memory schedule = vestingSchedules[token][beneficiary][scheduleId];
        if (schedule.totalAmount == 0 || schedule.revoked) return 0;
        return _calculateClaimableAmount(schedule);
    }

    /**
     * @notice 获取所有计划的可领取总量
     */
    function getTotalClaimableAmount(
        address token,
        address beneficiary
    ) external view override returns (uint256 totalClaimable) {
        uint256 count = scheduleCount[token][beneficiary];
        for (uint256 i = 0; i < count; i++) {
            VestingSchedule memory schedule = vestingSchedules[token][beneficiary][i];
            if (schedule.totalAmount > 0 && !schedule.revoked) {
                totalClaimable += _calculateClaimableAmount(schedule);
            }
        }
    }

    /**
     * @notice 获取归属统计信息
     * @return vested 已解锁数量（可领取+已领取）
     * @return claimed 已领取数量
     * @return locked 仍锁定数量（未解锁）
     */
    function getTotalVestedAmount(
        address token,
        address beneficiary
    ) external view override returns (uint256 vested, uint256 claimed, uint256 locked) {
        uint256 count = scheduleCount[token][beneficiary];

        for (uint256 i = 0; i < count; i++) {
            VestingSchedule memory schedule = vestingSchedules[token][beneficiary][i];
            if (schedule.totalAmount > 0 && !schedule.revoked) {
                if (schedule.mode == VestingMode.BURN) {
                    continue;
                }
                
                uint256 vestedForSchedule;
                if (block.timestamp >= schedule.endTime) {
                    vestedForSchedule = schedule.totalAmount;
                } else if (block.timestamp > schedule.startTime) {
                    if (schedule.mode == VestingMode.LINEAR) {
                        uint256 timePassed = block.timestamp - schedule.startTime;
                        uint256 totalDuration = schedule.endTime - schedule.startTime;
                        vestedForSchedule = (schedule.totalAmount * timePassed) / totalDuration;
                    }
                }

                vested += vestedForSchedule;
                claimed += schedule.claimedAmount;
                locked += (schedule.totalAmount - vestedForSchedule);
            }
        }

        return (vested, claimed, locked);
    }

    // ============ 管理函数 ============

    /**
     * @notice 撤销归属计划
     * @dev 仅限 ADMIN_ROLE
     * 
     * @param token 代币地址
     * @param beneficiary 受益人地址
     * @param scheduleId 计划ID
     * 
     * ============ 执行流程 ============
     * 
     * 1. 验证计划存在且未撤销
     * 2. 计算并发放已解锁的代币给受益人
     * 3. 返还剩余锁定代币给管理员
     * 4. 标记计划为已撤销
     */
    function revokeVestingSchedule(
        address token,
        address beneficiary,
        uint256 scheduleId
    ) external override onlyRole(ADMIN_ROLE) {
        VestingSchedule storage schedule = vestingSchedules[token][beneficiary][scheduleId];

        if (schedule.totalAmount == 0) revert ScheduleNotFound();
        if (schedule.revoked) revert ScheduleRevoked();
        
        uint256 remainingAmount;
        if (schedule.mode != VestingMode.BURN) {
            // 发放已解锁部分给受益人
            uint256 claimableAmount = _calculateClaimableAmount(schedule);
            if (claimableAmount > 0) {
                schedule.claimedAmount += claimableAmount;
                totalTokenLocked[token] -= claimableAmount;
                IERC20(token).safeTransfer(beneficiary, claimableAmount);
            }
            
            // 返还剩余给管理员
            remainingAmount = schedule.totalAmount - schedule.claimedAmount;
            if (remainingAmount > 0) {
                totalTokenLocked[token] -= remainingAmount;
                totalVestedAmount[token][beneficiary] -= remainingAmount;
                IERC20(token).safeTransfer(msg.sender, remainingAmount);
            }
        }
        
        schedule.revoked = true;
        emit VestingScheduleRevoked(token, beneficiary, scheduleId, remainingAmount);
    }

    /**
     * @notice 紧急提取代币
     * @dev 仅限 ADMIN_ROLE，用于紧急情况
     */
    function emergencyWithdrawToken(
        address token,
        uint256 amount
    ) external override onlyRole(ADMIN_ROLE) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance();
        IERC20(token).safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(token, msg.sender, amount);
    }

    /**
     * @notice 暂停合约
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice 恢复合约
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice 授权合约升级
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}
}
