// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from"@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMEMEHelper} from "./interfaces/IMEMEHelper.sol";
import {IMEMECore} from "./interfaces/IMEMECore.sol";
import {IPancakeFactory} from "./interfaces/IPancakeFactory.sol";
import {IPancakeRouter02} from "./interfaces/IPancakeRouter02.sol";
import {IPancakePair} from "./interfaces/IPancakePair.sol";

/**
 * @title MEMEHelper
 * @author MetaNode Team
 * @notice 联合曲线计算与 DEX 集成助手合约
 * 
 * ============ 合约职责 ============
 * 1. 联合曲线的数学计算
 * 2. PancakeSwap V2 流动性操作
 * 3. 交易对地址预测
 * 
 * ============ 恒定乘积公式详解 ============
 * 
 * 基本公式：k = x × y（始终不变）
 * - x = virtualBNBReserve（虚拟 BNB 储备）
 * - y = virtualTokenReserve（虚拟代币储备）
 * - k = 恒定乘积（创建时确定，不变）
 * 
 * 【买入计算】
 * 用户支付 Δx BNB，获得 Δy 代币
 * 
 * 交易后：(x + Δx) × (y - Δy) = k
 * 推导：y - Δy = k / (x + Δx)
 * 结果：Δy = y - k / (x + Δx)
 * 
 * 代码实现：
 * newBNBReserve = virtualBNBReserve + bnbIn
 * newTokenReserve = k / newBNBReserve
 * tokenOut = virtualTokenReserve - newTokenReserve
 * 
 * 【卖出计算】
 * 用户支付 Δy 代币，获得 Δx BNB
 * 
 * 交易后：(x - Δx) × (y + Δy) = k
 * 推导：x - Δx = k / (y + Δy)
 * 结果：Δx = x - k / (y + Δy)
 * 
 * 代码实现：
 * newTokenReserve = virtualTokenReserve + tokenIn
 * newBNBReserve = k / newTokenReserve
 * bnbOut = virtualBNBReserve - newBNBReserve
 * 
 * 【价格计算】
 * 当前价格 = x / y（BNB/代币）
 * 买入越多价格越高（x↑, y↓）
 * 卖出越多价格越低（x↓, y↑）
 * 
 * ============ DEX 集成说明 ============
 * 
 * 毕业时调用 addLiquidityV2：
 * 1. 将剩余代币和 BNB 添加到 PancakeSwap
 * 2. 获得 LP 代币（流动性凭证）
 * 3. LP 代币发送到死地址（永久锁定流动性）
 * 
 * 这确保：
 * - 流动性不会被撤走（Rug Pull 防护）
 * - 代币可以在 DEX 自由交易
 */
contract MEMEHelper is IMEMEHelper, AccessControl {
    using SafeERC20 for IERC20;

    // ============ 角色常量 ============

    /**
     * @notice 核心合约角色
     * @dev 拥有此角色才能调用 addLiquidityV2
     * 授予 MEMECore 合约
     */
    bytes32 public constant CORE_ROLE = keccak256("CORE_ROLE");

    // ============ 系统常量 ============

    /**
     * @notice 最小流动性（LP 代币）
     * @dev PancakeSwap 要求首次添加流动性时锁定最小数量
     * 防止操纵攻击
     */
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;

    // ============ 不可变变量 ============

    /**
     * @notice PancakeSwap V2 路由合约地址
     * @dev 用于添加流动性操作
     * BSC 主网：0x10ED43C718714eb63d5aA57B78B54704E256024E
     */
    address public immutable PANCAKE_V2_ROUTER;

    /**
     * @notice WBNB 合约地址
     * @dev 用于获取交易对地址
     * BSC 主网：0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c
     */
    address public immutable WBNB;

    // ============ 构造函数 ============

    /**
     * @notice 初始化助手合约
     * @param _admin 管理员地址
     * @param _router PancakeSwap V2 路由地址
     * @param _wbnb WBNB 合约地址
     */
    constructor(address _admin, address _router, address _wbnb) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(CORE_ROLE, _admin);
        if (_router == address(0)) revert ZeroAddress();
        if (_wbnb == address(0)) revert ZeroAddress();
        PANCAKE_V2_ROUTER = _router;
        WBNB = _wbnb;
    }

    // ============ DEX 操作函数 ============

    /**
     * @notice 添加 PancakeSwap V2 流动性
     * @dev 仅限 CORE_ROLE（MEMECore）调用
     * 
     * @param token 代币地址
     * @param bnbAmount 添加的 BNB 数量
     * @param tokenAmount 添加的代币数量
     * @return liquidity 获得的 LP 代币数量
     * 
     * ============ 执行流程 ============
     * 
     * 1. 【校验参数】
     *    - bnbAmount > 0
     *    - tokenAmount > 0
     * 
     * 2. 【转入代币】
     *    - 从调用者转入代币到本合约
     *    - 使用 SafeERC20 防止转账失败
     * 
     * 3. 【授权路由】
     *    - 授权 PancakeSwap 路由操作代币
     * 
     * 4. 【添加流动性】
     *    - 调用 addLiquidityETH
     *    - 设置 5% 滑点保护
     *    - LP 接收者设为死地址（永久锁定）
     * 
     * ============ 注意事项 ============
     * - LP 代币发送到死地址，流动性永久锁定
     * - 5% 滑点保护，可能部分代币/BNB 退回
     * - 5 分钟超时保护
     */
    function addLiquidityV2(
        address token,
        uint256 bnbAmount,
        uint256 tokenAmount
    ) external payable onlyRole(CORE_ROLE) returns (uint256 liquidity) {
        // 1. 校验参数
        if (bnbAmount == 0 || tokenAmount == 0) revert ZeroAmount();
        
        // 2. 转入代币
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        
        // 3. 授权路由
        IERC20(token).approve(PANCAKE_V2_ROUTER, tokenAmount);

        // 4. 添加流动性（LP 发送到死地址）
        (,, liquidity) = IPancakeRouter02(PANCAKE_V2_ROUTER).addLiquidityETH{value: bnbAmount}(
            token,
            tokenAmount,
            tokenAmount * 95 / 100,  // 最小代币数量（5% 滑点）
            bnbAmount * 95 / 100,    // 最小 BNB 数量（5% 滑点）
            block.timestamp + 300,   // 5 分钟超时
            true                     // LP 发送到死地址（永久锁定）
        );
    }

    /**
     * @notice 获取/预测交易对地址
     * @dev 如果交易对已存在则直接返回，否则使用 CREATE2 预测
     * 
     * @param token 代币地址
     * @return pair 交易对合约地址
     * 
     * ============ 地址计算说明 ============
     * 
     * PancakeSwap 使用 CREATE2 部署交易对：
     * pair = keccak256(0xff, factory, salt, INIT_CODE_HASH)
     * 
     * 其中：
     * - factory = PancakeSwap 工厂地址
     * - salt = keccak256(token0, token1)，token0 < token1
     * - INIT_CODE_HASH = 交易对合约的字节码哈希
     */
    function getPairAddress(address token) external view override returns (address pair) {
        address factory = IPancakeRouter02(PANCAKE_V2_ROUTER).factory();
        
        // 尝试获取已存在的交易对
        pair = IPancakeFactory(factory).getPair(token, WBNB);
        
        // 如果不存在，预测地址
        if (pair == address(0)) {
            // 排序代币地址（token0 < token1）
            (address token0, address token1) = token < WBNB
                ? (token, WBNB)
                : (WBNB, token);

            // 使用 CREATE2 公式计算
            pair = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                hex"ff",
                                factory,
                                keccak256(abi.encodePacked(token0, token1)),
                                IPancakeFactory(factory).INIT_CODE_HASH()
                            )
                        )
                    )
                )
            );
        }
    }

    /**
     * @notice 估算添加流动性获得的 LP 数量
     * @dev 仅用于首次添加流动性的估算
     * 
     * @param token 代币地址
     * @param bnbAmount BNB 数量
     * @param tokenAmount 代币数量
     * @return 估算的 LP 代币数量
     * 
     * ============ 计算公式 ============
     * 首次添加流动性：LP = sqrt(bnbAmount × tokenAmount) - MINIMUM_LIQUIDITY
     * 已有流动性：需要更复杂计算（此处返回 0）
     */
    function estimateLPTokens(
        address token,
        uint256 bnbAmount,
        uint256 tokenAmount
    ) external view returns (uint256) {
        address pair = IPancakeFactory(IPancakeRouter02(PANCAKE_V2_ROUTER).factory()).getPair(token, WBNB);
        
        if (pair == address(0)) {
            // 首次添加流动性
            uint256 product = bnbAmount * tokenAmount;
            uint256 liquidity = sqrt(product);

            if (liquidity > MINIMUM_LIQUIDITY) {
                return liquidity - MINIMUM_LIQUIDITY;
            } else {
                return 0;
            }
        } else {
            // 已有流动性，需要更复杂计算
            return 0;
        }
    }

    // ============ 曲线计算函数 ============

    /**
     * @notice 计算买入可获得的代币数量
     * @dev 不含手续费
     * 
     * @param bnbIn 输入的 BNB 数量（wei）
     * @param curve 当前曲线参数
     * @return tokenOut 可获得的代币数量（wei）
     * 
     * ============ 计算公式 ============
     * newBNBReserve = virtualBNBReserve + bnbIn
     * newTokenReserve = k / newBNBReserve
     * tokenOut = virtualTokenReserve - newTokenReserve
     */
    function calculateTokenAmountOut(
        uint256 bnbIn,
        IMEMECore.BondingCurveParams memory curve
    ) external pure override returns (uint256 tokenOut) {
        if (bnbIn == 0) return 0;
        if (curve.k == 0 || curve.virtualBNBReserve == 0) revert InvalidCurve();

        // 计算新的 BNB 储备
        uint256 newBNBReserve = curve.virtualBNBReserve + bnbIn;

        // 使用恒定乘积计算新的代币储备
        uint256 newTokenReserve = curve.k / newBNBReserve;

        // 计算代币输出量
        if (curve.virtualTokenReserve <= newTokenReserve) {return 0;}
        tokenOut = curve.virtualTokenReserve - newTokenReserve;
    }

    /**
     * @notice 计算买入（含手续费明细）
     * 
     * @param bnbIn 输入的 BNB 数量
     * @param curve 当前曲线参数
     * @param feeRate 手续费率（基点，如 100 = 1%）
     * @return tokenOut 可获得的代币数量
     * @return netBNB 扣除手续费后的 BNB
     * @return feeBNB 手续费
     */
    function calculateTokenAmountOutWithFee(
        uint256 bnbIn,
        IMEMECore.BondingCurveParams memory curve,
        uint256 feeRate
    ) external pure override returns (uint256 tokenOut, uint256 netBNB, uint256 feeBNB) {
        if (bnbIn == 0) return (0, 0, 0);
        if (curve.k == 0 || curve.virtualBNBReserve == 0) revert InvalidCurve();
        
        // 计算手续费
        feeBNB = (bnbIn * feeRate) / 10000;
        netBNB = bnbIn - feeBNB;
        
        // 用净额计算代币
        uint256 newBNBReserve = curve.virtualBNBReserve + netBNB;
        uint256 newTokenReserve = curve.k / newBNBReserve;
        
        if (curve.virtualTokenReserve <= newTokenReserve) {
            return (0, netBNB, feeBNB);
        }
        tokenOut = curve.virtualTokenReserve - newTokenReserve;
    }

    /**
     * @notice 计算卖出可获得的 BNB
     * @dev 不含手续费
     * 
     * @param tokenIn 输入的代币数量
     * @param curve 当前曲线参数
     * @return bnbOut 可获得的 BNB 数量
     * 
     * ============ 计算公式 ============
     * newTokenReserve = virtualTokenReserve + tokenIn
     * newBNBReserve = k / newTokenReserve
     * bnbOut = virtualBNBReserve - newBNBReserve
     */
    function calculateBNBAmountOut(
        uint256 tokenIn,
        IMEMECore.BondingCurveParams memory curve
    ) external pure override returns (uint256) {
        if (tokenIn == 0) return 0;
        if (curve.k == 0 || curve.virtualTokenReserve == 0) revert InvalidCurve();
        
        // 计算新的代币储备
        uint256 newTokenReserve = curve.virtualTokenReserve + tokenIn;
        
        // 使用恒定乘积计算新的 BNB 储备
        uint256 newBNBReserve = curve.k / newTokenReserve;
        
        // 计算 BNB 输出量
        if (curve.virtualBNBReserve <= newBNBReserve) return 0;
        return curve.virtualBNBReserve - newBNBReserve;
    }

    /**
     * @notice 计算卖出（含手续费明细）
     * 
     * @param tokenIn 输入的代币数量
     * @param curve 当前曲线参数
     * @param feeRate 手续费率（基点）
     * @return netBNB 扣除手续费后可获得的 BNB
     * @return feeBNB 手续费
     */
    function calculateBNBAmountOutWithFee(
        uint256 tokenIn,
        IMEMECore.BondingCurveParams memory curve,
        uint256 feeRate
    ) external pure override returns (uint256 netBNB, uint256 feeBNB) {
        if (tokenIn == 0) return (0, 0);
        if (curve.k == 0 || curve.virtualTokenReserve == 0) revert InvalidCurve();

        // 计算原始 BNB 输出
        uint256 newTokenReserve = curve.virtualTokenReserve + tokenIn;
        uint256 newBNBReserve = curve.k / newTokenReserve;

        if (curve.virtualBNBReserve <= newBNBReserve) return (0, 0);
        uint256 grossBNB = curve.virtualBNBReserve - newBNBReserve;
        
        // 计算手续费
        feeBNB = (grossBNB * feeRate) / 10000;
        netBNB = grossBNB - feeBNB;
    }

    /**
     * @notice 计算购买指定数量代币需要的 BNB
     * @dev 反向计算，用于精确购买
     * 
     * @param tokenOut 期望获得的代币数量
     * @param curve 当前曲线参数
     * @return bnbIn 需要支付的 BNB 数量
     * 
     * ============ 计算公式 ============
     * newTokenReserve = virtualTokenReserve - tokenOut
     * newBNBReserve = k / newTokenReserve
     * bnbIn = newBNBReserve - virtualBNBReserve
     */
    function calculateRequiredBNB(
        uint256 tokenOut,
        IMEMECore.BondingCurveParams memory curve
    ) external pure override returns (uint256 bnbIn) {
        if (tokenOut == 0) return 0;
        if (curve.k == 0 || curve.virtualTokenReserve == 0) revert InvalidCurve();
        
        // 计算购买后的代币储备
        uint256 newTokenReserve = curve.virtualTokenReserve - tokenOut;
        
        // 使用恒定乘积计算需要的 BNB 储备
        uint256 newBNBReserve = curve.k / newTokenReserve;
        
        // 计算需要输入的 BNB
        if (newBNBReserve <= curve.virtualBNBReserve) {
            return 0;
        }
        bnbIn = newBNBReserve - curve.virtualBNBReserve;
    }

    /**
     * @notice 获取当前代币价格
     * 
     * @param curve 曲线参数
     * @return price 价格（BNB/Token × 1e18）
     * 
     * ============ 计算公式 ============
     * price = virtualBNBReserve × 1e18 / virtualTokenReserve
     * 
     * 注意：乘以 1e18 是为了保留精度
     */
    function getPrice(
        IMEMECore.BondingCurveParams memory curve
    ) external pure override returns (uint256) {
        if (curve.virtualTokenReserve == 0) return 0;
        return (curve.virtualBNBReserve * 1e18) / curve.virtualTokenReserve;
    }

    // ============ 内部函数 ============

    /**
     * @notice 平方根计算（巴比伦法）
     * @dev 用于估算 LP 代币数量
     * 
     * @param x 输入值
     * @return 平方根（向下取整）
     */
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    /**
     * @notice 排序代币地址
     * @dev PancakeSwap 要求 token0 < token1
     */
    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "Zero address");
    }

    // ============ 管理函数 ============

    /**
     * @notice 紧急提取资产
     * @dev 仅限管理员，用于紧急情况
     * 
     * @param token 代币地址（address(0) 为 BNB）
     * @param amount 提取数量
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) {
            payable(msg.sender).transfer(amount);
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
    }

    /**
     * @notice 接收 BNB
     * @dev 用于接收添加流动性时的退款
     */
    receive() external payable {}
}
