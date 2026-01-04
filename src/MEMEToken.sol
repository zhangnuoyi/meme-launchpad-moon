// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title MetaNodeToken
 * @author MetaNode Team
 * @notice MEME 发射器部署的 ERC20 代币合约
 * 
 * ============ 合约职责 ============
 * 1. 标准 ERC20 代币功能
 * 2. 可销毁（用于归属计划的 BURN 模式）
 * 3. 转账限制（保护上线前的代币流通）
 * 
 * ============ 转账模式说明 ============
 * 
 * 【MODE_TRANSFER_RESTRICTED】初始状态
 * - 禁止所有转账（除铸造/销毁）
 * - 用于代币创建后、开盘前的保护期
 * 
 * 【MODE_TRANSFER_CONTROLLED】交易中
 * - 允许与 MEMECore 的买卖交互
 * - 禁止直接转账到交易对（防止绕过曲线）
 * - 允许归属合约释放代币
 * 
 * 【MODE_NORMAL】毕业后
 * - 完全开放转账
 * - 代币可在 DEX 自由交易
 * 
 * ============ 生命周期 ============
 * 
 * 1. 工厂部署 → RESTRICTED（全部代币在 MEMECore）
 * 2. 创建完成 → CONTROLLED（可通过曲线买卖）
 * 3. 待毕业   → RESTRICTED（暂停转账）
 * 4. 已毕业   → NORMAL（自由交易）
 */
contract MetaNodeToken is ERC20Burnable {

    // ============ 枚举定义 ============

    /**
     * @notice 转账模式枚举
     */
    enum TransferMode {
        MODE_NORMAL,              // 0: 正常模式（毕业后，自由转账）
        MODE_TRANSFER_RESTRICTED, // 1: 限制模式（禁止所有转账）
        MODE_TRANSFER_CONTROLLED  // 2: 受控模式（仅允许曲线交易）
    }

    // ============ 状态变量 ============

    /**
     * @notice 当前转账模式
     * @dev 由 MEMECore 通过 setTransferMode 设置
     * 初始值：MODE_TRANSFER_RESTRICTED
     */
    TransferMode public transferMode;

    /**
     * @notice 归属合约地址
     * @dev 归属合约的转出不受限制模式影响
     * 允许锁仓释放操作
     */
    address public vestingContract;

    /**
     * @notice DEX 交易对地址
     * @dev 用于判断是否允许转账到交易对
     * 非 NORMAL 模式下禁止直接转入 pair
     */
    address public pair;

    /**
     * @notice MEMECore 核心合约地址
     * @dev 拥有设置转账模式等管理权限
     * 构造时设置，不可更改
     */
    address public metaNodeCore;

    // ============ 错误定义 ============

    /// @notice 转账被限制（RESTRICTED 模式）
    error TransferRestricted();
    /// @notice 不允许转账到代币合约自身
    error TransferToTokenNotAllowed();
    /// @notice 非 NORMAL 模式下不允许转账到交易对
    error TransferNotAllowedToPair();
    /// @notice 转账不被允许
    error TransferNotAllowed();
    /// @notice 仅限 MEMECore 调用
    error onlyMetaNodeCall();
    /// @notice 零地址
    error ZeroAddress();

    // ============ 事件定义 ============

    /// @notice 转账模式变更事件
    event TransferModeChanged(TransferMode oldMode, TransferMode newMode);
    /// @notice 归属合约地址变更事件
    event VestingContractChanged(address vestingContract);
    /// @notice 交易对地址变更事件
    event PairChanged(address pair);

    // ============ 修饰器 ============

    /**
     * @notice 仅限 MEMECore 调用
     */
    modifier onlyMetaNode() {
        if (msg.sender != metaNodeCore) revert onlyMetaNodeCall();
        _;
    }

    // ============ 构造函数 ============

    /**
     * @notice 部署代币合约
     * @dev 由 MEMEFactory 通过 CREATE2 调用
     * 
     * @param name 代币名称
     * @param symbol 代币符号
     * @param totalSupply 总供应量（含18位小数）
     * @param _metaNode MEMECore 合约地址
     * 
     * ============ 初始化流程 ============
     * 1. 设置代币名称和符号（ERC20）
     * 2. 设置转账模式为 RESTRICTED
     * 3. 将全部代币铸造给 _metaNode
     * 4. 记录 metaNodeCore 地址
     */
    constructor(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        address _metaNode
    ) ERC20(name, symbol)  {
        if (_metaNode == address(0)) revert ZeroAddress();
        
        // 初始状态：禁止所有转账
        transferMode = TransferMode.MODE_TRANSFER_RESTRICTED;
        
        // 铸造全部代币给 MEMECore
        if (totalSupply > 0) {
            _mint(_metaNode, totalSupply);
        }
        
        metaNodeCore = _metaNode;
    }

    // ============ 管理函数 ============

    /**
     * @notice 设置转账模式
     * @dev 仅限 MEMECore 调用
     * 
     * @param _mode 新的转账模式
     * 
     * 调用时机：
     * - 创建完成 → CONTROLLED
     * - 待毕业   → RESTRICTED
     * - 毕业完成 → NORMAL
     */
    function setTransferMode(TransferMode _mode) external onlyMetaNode {
        TransferMode oldMode = transferMode;
        transferMode = _mode;
        emit TransferModeChanged(oldMode, _mode);
    }

    /**
     * @notice 设置归属合约地址
     * @dev 仅限 MEMECore 调用
     * 
     * @param _vestingContract 归属合约地址
     * 
     * 设置后，归属合约的转出操作不受模式限制
     */
    function setVestingContract(address _vestingContract) external onlyMetaNode {
        if (_vestingContract == address(0)) revert ZeroAddress();
        vestingContract = _vestingContract;
        emit VestingContractChanged(_vestingContract);
    }

    /**
     * @notice 设置 DEX 交易对地址
     * @dev 仅限 MEMECore 调用
     * 
     * @param _pair 交易对合约地址
     * 
     * 设置后，非 NORMAL 模式下禁止直接转入 pair
     * （必须通过曲线买卖）
     */
    function setPair(address _pair) external onlyMetaNode {
        if (_pair == address(0)) revert ZeroAddress();
        pair = _pair;
        emit PairChanged(_pair);
    }

    // ============ 内部函数 ============

    /**
     * @notice 转账前钩子 - 实现转账限制逻辑
     * @dev 重写 ERC20 的 _beforeTokenTransfer
     * 
     * @param from 发送方地址
     * @param to 接收方地址
     * @param amount 转账金额（未使用，但保留签名）
     * 
     * ============ 检查规则 ============
     * 
     * 1. 铸造（from=0）和销毁（to=0）始终允许
     * 
     * 2. 禁止转账到代币合约自身
     *    防止代币被永久锁定
     * 
     * 3. 归属合约转出始终允许
     *    支持锁仓释放功能
     * 
     * 4. 非 NORMAL 模式下禁止转入 pair
     *    防止绕过曲线直接卖出
     * 
     * 5. RESTRICTED 模式下禁止所有转账
     *    完全锁定代币流通
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        super._beforeTokenTransfer(from, to, amount);
        
        // 规则1：允许铸造和销毁
        if (from == address(0) || to == address(0)) {
            return;
        }

        // 规则2：禁止转账到代币合约自身
        if (to == address(this)) {
            revert TransferToTokenNotAllowed();
        }

        // 规则3：归属合约转出始终允许
        if (from == vestingContract && vestingContract != address(0)) {
            return;
        }

        // 规则4：非 NORMAL 模式禁止转入 pair
        if (transferMode != TransferMode.MODE_NORMAL && to == pair && pair != address(0)) {
            revert TransferNotAllowedToPair();
        }

        // 规则5：RESTRICTED 模式禁止所有转账
        if (transferMode == TransferMode.MODE_TRANSFER_RESTRICTED) {
            revert TransferRestricted();
        }
    }
}
