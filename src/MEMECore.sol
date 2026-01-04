// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMEMECore as IMetaNodeCore} from "./interfaces/IMEMECore.sol";
import {IMEMEFactory as IMetaNodeFactory} from "./interfaces/IMEMEFactory.sol";
import {IMEMEHelper as IMetaNodeHelper} from "./interfaces/IMEMEHelper.sol";
import {IMEMEVesting as IMetaNodeVesting} from "./interfaces/IMEMEVesting.sol";
import {MetaNodeToken} from "./MEMEToken.sol";

/**
 * @title MetaNodeCore
 * @author MetaNode Team
 * @notice MEME 发射器核心合约 - 管理代币的完整生命周期
 * 
 * ============ 合约概述 ============
 * 这是 MEME 发射器的核心业务合约，实现：
 * - 代币创建（通过签名验证）
 * - 联合曲线交易（买入/卖出）
 * - 毕业流程（添加 DEX 流动性）
 * - 代币状态管理（暂停/黑名单）
 * 
 * ============ 架构设计 ============
 * - 可升级代理模式（UUPS）
 * - 基于角色的权限控制
 * - 防重入保护
 * - 紧急暂停机制
 * 
 * ============ 业务流程图 ============
 * 
 * 【创建代币】
 * 前端构造参数 → 后端签名 → 用户调用 createToken
 *      ↓
 * 验证签名 → 扣除费用 → 部署代币 → 初始化曲线
 *      ↓
 * (可选) 初始买入 → (可选) 创建归属 → (可选) 存入保证金
 * 
 * 【买入代币】
 * 用户支付 BNB → 扣除手续费 → 按曲线计算代币量
 *      ↓
 * 更新曲线储备 → 转移代币 → 检查是否触发毕业
 * 
 * 【卖出代币】
 * 用户转入代币 → 按曲线计算 BNB → 扣除手续费
 *      ↓
 * 更新曲线储备 → 转移 BNB
 * 
 * 【毕业代币】
 * 可售量 < 阈值 → 管理员触发毕业
 *      ↓
 * 计算费用分配 → 添加 DEX 流动性 → 开放自由交易
 * 
 * ============ 费用说明 ============
 * - 创建费（creationFee）：发币时收取的固定费用
 * - 初始买入费（preBuyFeeRate）：初始买入时的手续费
 * - 交易费（tradingFeeRate）：每笔买卖收取的手续费
 * - 毕业费（graduationFeeRate）：毕业时从池中抽取的费用
 */
contract MetaNodeCore is IMetaNodeCore, Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ============ 角色常量 ============

    /**
     * @notice 管理员角色
     * @dev 权限：参数配置、合约升级、紧急操作
     */
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /**
     * @notice 签名者角色
     * @dev 权限：为创建请求生成有效签名
     * 通常由后端服务持有
     */
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    /**
     * @notice 部署者角色
     * @dev 权限：触发代币毕业
     * 通常由自动化服务或管理员持有
     */
    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

    /**
     * @notice 暂停者角色
     * @dev 权限：暂停/恢复单个代币的交易
     */
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ============ 系统常量 ============

    /**
     * @notice 签名请求有效期（秒）
     * @dev 请求时间戳 + REQUEST_EXPIRY 后签名失效
     * 防止签名被长期滥用
     */
    uint256 public constant REQUEST_EXPIRY = 3600; // 1小时

    /**
     * @notice 毕业触发阈值
     * @dev 当 availableTokens < MIN_LIQUIDITY 时触发待毕业
     * 单位：wei（18位小数）
     */
    uint256 public constant MIN_LIQUIDITY = 10 ether; // 10个代币

    /**
     * @notice 初始买入最大百分比（基点）
     * @dev 9990 = 99.9%，预留 0.1% 确保曲线有流动性
     */
    uint256 public constant MAX_INITIAL_BUY_PERCENTAGE = 9990;

    // ============ 可配置参数 ============

    /**
     * @notice 代币创建费用（wei）
     * @dev 每次发币时收取，转给平台
     * 默认：0.05 BNB
     */
    uint256 public creationFee;

    /**
     * @notice 初始买入手续费率（基点）
     * @dev 创建时初始买入的额外费用
     * 默认：300 = 3%
     */
    uint256 public preBuyFeeRate;

    /**
     * @notice 交易手续费率（基点）
     * @dev 每笔买卖收取的费用
     * 默认：100 = 1%
     */
    uint256 public tradingFeeRate;

    /**
     * @notice 毕业平台费率（基点）
     * @dev 毕业时从池中抽取给平台的比例
     * 默认：550 = 5.5%
     */
    uint256 public graduationPlatformFeeRate;

    /**
     * @notice 毕业创作者费率（基点）
     * @dev 毕业时从池中抽取给创建者的比例
     * 默认：250 = 2.5%
     */
    uint256 public graduationCreatorFeeRate;

    /**
     * @notice 归属最短锁仓时间（秒）
     * @dev LINEAR 模式的 duration 不能小于此值
     * 默认：86400 = 1天
     */
    uint256 public minLockTime;

    // ============ 合约依赖 ============

    /**
     * @notice 工厂合约实例
     * @dev 负责部署新的 MetaNodeToken
     */
    IMetaNodeFactory public factory;

    /**
     * @notice 助手合约实例
     * @dev 负责曲线计算和 DEX 操作
     */
    IMetaNodeHelper public helper;

    /**
     * @notice 归属合约实例
     * @dev 负责管理初始买入代币的锁仓释放
     */
    IMetaNodeVesting public vesting;

    /**
     * @notice 平台费接收地址
     * @dev 接收创建费、交易费
     */
    address public platformFeeReceiver;

    /**
     * @notice 保证金接收地址
     * @dev 接收创建时的保证金
     */
    address public marginReceiver;

    /**
     * @notice 当前链 ID
     * @dev 写入签名域，防止跨链重放
     */
    uint256 public CHAIN_ID;

    // ============ 存储映射 ============

    /**
     * @notice 代币基础信息映射
     * @dev token地址 => TokenInfo
     */
    mapping(address => TokenInfo) public tokenInfo;

    /**
     * @notice 联合曲线参数映射
     * @dev token地址 => BondingCurveParams
     */
    mapping(address => BondingCurveParams) public bondingCurve;

    /**
     * @notice 已使用的请求ID映射
     * @dev requestId => 是否已使用（防重放）
     */
    mapping(bytes32 => bool) public usedRequestIds;

    /**
     * @notice 毕业费接收地址
     * @dev 接收毕业时的平台费
     */
    address public graduateFeeReceiver;

    // ============ 修饰器 ============

    /**
     * @notice 验证代币存在
     */
    modifier validToken(address token) {
        if (tokenInfo[token].creator == address(0)) revert InvalidCreatorParameters();
        _;
    }

    /**
     * @notice 验证代币处于交易状态且已开盘
     */
    modifier onlyTradingToken(address token) {
        _onlyTradingToken(token);
        _;
    }

    // ============ 构造函数 ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ 初始化函数 ============

    /**
     * @notice 初始化核心合约
     * @dev 仅在代理部署时调用一次
     * 
     * @param _factory 工厂合约地址
     * @param _helper 助手合约地址
     * @param _signer 签名者地址（后端服务）
     * @param _platformFeeReceiver 平台费接收地址
     * @param _marginReceiver 保证金接收地址
     * @param _graduateFeeReceiver 毕业费接收地址
     * @param _admin 管理员地址
     * 
     * ============ 初始化内容 ============
     * 1. 初始化 OpenZeppelin 可升级组件
     * 2. 设置合约依赖
     * 3. 授予角色权限
     * 4. 设置默认费率参数
     */
    function initialize(
        address _factory,
        address _helper,
        address _signer,
        address _platformFeeReceiver,
        address _marginReceiver,
        address _graduateFeeReceiver,
        address _admin
    ) public initializer {
        // 初始化可升级组件
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        // 记录链 ID
        CHAIN_ID = block.chainid;
        
        // 设置合约依赖
        factory = IMetaNodeFactory(_factory);
        helper = IMetaNodeHelper(_helper);
        platformFeeReceiver = _platformFeeReceiver;
        marginReceiver = _marginReceiver;
        graduateFeeReceiver = _graduateFeeReceiver;

        // 授予角色
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(SIGNER_ROLE, _signer);
        _grantRole(DEPLOYER_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        
        // 设置默认费率
        creationFee = 0.05 ether;          // 创建费：0.05 BNB
        preBuyFeeRate = 300;               // 初始买入费：3%
        tradingFeeRate = 100;              // 交易费：1%
        graduationPlatformFeeRate = 550;   // 毕业平台费：5.5%
        graduationCreatorFeeRate = 250;    // 毕业创作者费：2.5%
        minLockTime = 86400;               // 最短锁仓：1天
    }

    // ============ 核心业务函数 ============

    /**
     * @notice 创建新代币
     * @dev 防重入、暂停保护
     * 
     * @param data ABI 编码的 CreateTokenParams
     * @param signature 后端对 data+chainId+address 的签名
     * @return tokenAddress 新部署的代币地址
     * 
     * ============ 完整执行流程 ============
     * 
     * 1. 【费用校验】
     *    - 检查 msg.value >= creationFee
     * 
     * 2. 【解码参数】
     *    - 从 data 解码 CreateTokenParams
     * 
     * 3. 【签名验证】
     *    - 计算消息哈希：hash(data, chainId, this)
     *    - 恢复签名者地址
     *    - 验证签名者拥有 SIGNER_ROLE
     * 
     * 4. 【请求校验】
     *    - 检查时间戳未过期
     *    - 检查 requestId 未被使用
     *    - 验证代币参数合法性
     * 
     * 5. 【计算支付】
     *    - 基础：creationFee
     *    - 可选：marginBnb（保证金）
     *    - 可选：initialBNB + preBuyFee（初始买入）
     * 
     * 6. 【部署代币】
     *    - 调用工厂合约部署 MetaNodeToken
     *    - 获取预计算的交易对地址
     *    - 设置代币的 pair 地址
     * 
     * 7. 【初始化曲线】
     *    - 设置虚拟储备（考虑初始买入调整）
     *    - 计算恒定乘积 k
     *    - 记录可售数量和已收集 BNB
     * 
     * 8. 【注册代币信息】
     *    - 记录创建者、时间、状态等
     * 
     * 9. 【设置转账模式】
     *    - 切换到 CONTROLLED 模式
     *    - 设置归属合约地址
     * 
     * 10.【处理初始买入】
     *    - 创建归属计划（如配置）
     *    - 或直接转移代币给创建者
     * 
     * 11.【处理保证金】
     *    - 转移保证金到 marginReceiver
     * 
     * 12.【转移费用】
     *    - 创建费和初始买入费转给平台
     * 
     * 13.【退还多余】
     *    - 如有多余 BNB，退还给用户
     */
    function createToken(
        bytes calldata data,
        bytes calldata signature
    ) external payable nonReentrant whenNotPaused returns (address tokenAddress){
        // 1. 费用校验
        if (msg.value < creationFee) revert InsufficientFee();
        
        // 2. 解码参数
        IMetaNodeCore.CreateTokenParams memory params = abi.decode(data, (IMetaNodeCore.CreateTokenParams));

        // 3. 签名验证
        bytes32 messageHash = keccak256(abi.encodePacked(data, CHAIN_ID, address(this)));
        address signer = messageHash.recover(signature);
        if (!hasRole(SIGNER_ROLE, signer)) revert InvalidSigner();

        // 4. 请求校验
        if (block.timestamp > params.timestamp + REQUEST_EXPIRY) revert RequestExpired();
        if (usedRequestIds[params.requestId]) revert RequestAlreadyProcessed();

        // 验证代币参数
        if (params.saleAmount > params.totalSupply) revert InvalidSaleParameters();
        if (params.saleAmount == 0) revert InvalidSaleParameters();
        if (params.saleAmount < params.totalSupply * params.initialBuyPercentage / 10000) revert InvalidSaleParameters();
        if (params.initialBuyPercentage > MAX_INITIAL_BUY_PERCENTAGE) revert InvalidInitialBuyPercentage();

        // 5. 计算总支付金额
        uint256 totalPaymentRequired = creationFee;
        uint256 initialTokens = 0;
        uint256 initialBNB = 0;
        uint256 adjustedBNBReserve = params.virtualBNBReserve;
        uint256 adjustedTokenReserve = params.virtualTokenReserve;
        uint256 preBuyFee;

        // 添加保证金
        if (params.marginBnb > 0) {
            totalPaymentRequired += params.marginBnb;
        }

        // 计算初始买入
        if (params.initialBuyPercentage > 0) {
            (initialTokens, initialBNB, adjustedBNBReserve, adjustedTokenReserve) =
            _calculateInitialBuy(
                params.totalSupply,
                params.virtualBNBReserve,
                params.virtualTokenReserve,
                params.initialBuyPercentage
            );
            preBuyFee = (initialBNB * preBuyFeeRate) / 10000;
            totalPaymentRequired += initialBNB + preBuyFee;
        }

        // 验证支付金额
        if (msg.value < totalPaymentRequired) revert InsufficientFee();

        // 标记请求已处理
        usedRequestIds[params.requestId] = true;

        // 6. 部署代币
        tokenAddress = factory.deployToken(
            params.name,
            params.symbol,
            params.totalSupply,
            params.timestamp,
            params.nonce
        );

        address pair = helper.getPairAddress(tokenAddress);
        if (pair == address(0)) revert InvalidPair();
        MetaNodeToken(tokenAddress).setPair(pair);

        // 7. 初始化曲线
        bondingCurve[tokenAddress] = BondingCurveParams({
            virtualBNBReserve: adjustedBNBReserve,
            virtualTokenReserve: adjustedTokenReserve,
            k: params.virtualBNBReserve * params.virtualTokenReserve,
            availableTokens: params.saleAmount - initialTokens,
            collectedBNB: initialBNB
        });

        // 8. 注册代币信息
        tokenInfo[tokenAddress] = TokenInfo({
            creator: params.creator,
            createdAt: block.timestamp,
            launchTime: params.launchTime,
            status: TokenStatus.TRADING,
            liquidityPool: pair
        });

        // 9. 设置转账模式
        MetaNodeToken(tokenAddress).setTransferMode(
            MetaNodeToken.TransferMode.MODE_TRANSFER_CONTROLLED
        );

        if (address(vesting) != address(0)) {
            MetaNodeToken(tokenAddress).setVestingContract(address(vesting));
        }

        // 10. 处理初始买入
        if (initialTokens > 0) {
            if (params.vestingAllocations.length > 0 && address(vesting) != address(0)) {
                uint256 tokensToTransfer = _createVestingSchedules(
                    tokenAddress,
                    params.creator,
                    initialTokens,
                    params.initialBuyPercentage,
                    params.totalSupply,
                    params.vestingAllocations
                );
                if (tokensToTransfer > 0) {
                    IERC20(tokenAddress).safeTransfer(params.creator, tokensToTransfer);
                }
            } else {
                IERC20(tokenAddress).safeTransfer(params.creator, initialTokens);
            }

            emit TokenCreatedWithInitialBuy(
                tokenAddress,
                params.creator,
                initialTokens,
                initialBNB,
                params.initialBuyPercentage
            );
        }

        // 11. 处理保证金
        if (params.marginBnb > 0) {
            if (marginReceiver == address(0)) revert MarginReceiverNotSet();
            payable(marginReceiver).transfer(params.marginBnb);
            emit MarginDeposited(
                tokenAddress,
                params.creator,
                params.marginBnb,
                params.marginTime
            );
        }

        // 12. 转移费用
        _sendValue(platformFeeReceiver, preBuyFee);
        _sendValue(platformFeeReceiver, creationFee);

        // 13. 退还多余
        if (msg.value > totalPaymentRequired) {
            payable(msg.sender).transfer(msg.value - totalPaymentRequired);
        }

        emit TokenCreated(tokenAddress, params.creator, params.name, params.symbol, params.totalSupply, params.requestId);
    }

    /**
     * @notice 从联合曲线买入代币
     * @dev 防重入、暂停保护、代币状态校验
     * 
     * @param token 代币地址
     * @param minTokenAmount 最小获得代币数（滑点保护）
     * @param deadline 交易截止时间
     * 
     * ============ 执行流程 ============
     * 
     * 1. 【时间校验】
     *    - deadline 在当前时间到+1天之间
     * 
     * 2. 【金额校验】
     *    - msg.value > 0
     * 
     * 3. 【手续费计算】
     *    - tradingFee = msg.value × tradingFeeRate / 10000
     *    - netBNBAmount = msg.value - tradingFee
     * 
     * 4. 【代币计算】
     *    - 使用 helper 按曲线计算可获得代币数
     * 
     * 5. 【余量处理】
     *    - 如果计算结果 > availableTokens
     *    - 改为购买全部剩余，重算 BNB 和手续费
     *    - 退还多余 BNB
     * 
     * 6. 【滑点校验】
     *    - tokenAmount >= minTokenAmount
     * 
     * 7. 【更新曲线】
     *    - virtualBNBReserve += netBNBAmount
     *    - virtualTokenReserve -= tokenAmount
     *    - availableTokens -= tokenAmount
     *    - collectedBNB += netBNBAmount
     * 
     * 8. 【转移资产】
     *    - 手续费转给平台
     *    - 代币转给买家
     * 
     * 9. 【检查毕业】
     *    - 如果 availableTokens < MIN_LIQUIDITY
     *    - 切换状态为 PENDING_GRADUATION
     *    - 代币切换为 RESTRICTED 模式
     */
    function buy(
        address token,
        uint256 minTokenAmount,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused validToken(token) onlyTradingToken(token) {
        // 1-2. 校验
        if (block.timestamp > deadline || deadline >= block.timestamp + 1 days) revert TransactionExpired();
        if (msg.value == 0) revert InvalidNativeAmount();

        // 3. 手续费计算
        uint256 tradingFee = (msg.value * tradingFeeRate) / 10000;
        uint256 netBNBAmount = msg.value - tradingFee;
        
        // 4. 代币计算
        uint256 tokenAmount = helper.calculateTokenAmountOut(netBNBAmount, bondingCurve[token]);

        // 5. 余量处理
        if (tokenAmount > bondingCurve[token].availableTokens) {
            tokenAmount = bondingCurve[token].availableTokens;
            netBNBAmount = helper.calculateRequiredBNB(tokenAmount, bondingCurve[token]);
            tradingFee = (netBNBAmount * tradingFeeRate) / (10000 - tradingFeeRate);
            uint256 actualPayment = netBNBAmount + tradingFee;

            if (msg.value > actualPayment) {
                payable(msg.sender).transfer(msg.value - actualPayment);
            }
        }
        
        // 6. 滑点校验
        if (tokenAmount < minTokenAmount) revert SlippageExceeded();

        // 7. 更新曲线
        bondingCurve[token].virtualBNBReserve += netBNBAmount;
        bondingCurve[token].virtualTokenReserve -= tokenAmount;
        bondingCurve[token].availableTokens -= tokenAmount;
        bondingCurve[token].collectedBNB += netBNBAmount;

        // 8. 转移资产
        _sendValue(platformFeeReceiver, tradingFee);
        IERC20(token).safeTransfer(msg.sender, tokenAmount);

        // 9. 检查毕业
        if (bondingCurve[token].availableTokens < MIN_LIQUIDITY) {
            _changeTokenStatus(token, TokenStatus.PENDING_GRADUATION);
            MetaNodeToken(token).setTransferMode(MetaNodeToken.TransferMode.MODE_TRANSFER_RESTRICTED);
        }

        emit TokenBought(
            token,
            msg.sender,
            netBNBAmount,
            tokenAmount,
            tradingFee,
            bondingCurve[token].virtualBNBReserve,
            bondingCurve[token].virtualTokenReserve,
            bondingCurve[token].availableTokens,
            bondingCurve[token].collectedBNB
        );
    }

    /**
     * @notice 向联合曲线卖出代币
     * @dev 防重入、暂停保护、代币状态校验
     * 
     * @param token 代币地址
     * @param tokenAmount 卖出的代币数量
     * @param minBNBAmount 最小获得 BNB（滑点保护）
     * @param deadline 交易截止时间
     * 
     * ============ 执行流程 ============
     * 
     * 1. 【校验】
     *    - deadline 未过期
     *    - tokenAmount > 0
     *    - 用户余额充足
     * 
     * 2. 【BNB 计算】
     *    - 使用 helper 按曲线计算可获得 BNB
     *    - 计算手续费
     *    - netBNBAmount = bnbAmount - tradingFee
     * 
     * 3. 【滑点校验】
     *    - netBNBAmount >= minBNBAmount
     * 
     * 4. 【池余额校验】
     *    - bnbAmount <= collectedBNB
     * 
     * 5. 【转入代币】
     *    - 从用户转入代币到合约
     * 
     * 6. 【更新曲线】
     *    - virtualBNBReserve -= bnbAmount
     *    - virtualTokenReserve += tokenAmount
     *    - availableTokens += tokenAmount
     *    - collectedBNB -= bnbAmount
     * 
     * 7. 【转移 BNB】
     *    - 手续费转给平台
     *    - 净额转给卖家
     */
    function sell(
        address token,
        uint256 tokenAmount,
        uint256 minBNBAmount,
        uint256 deadline
    ) external nonReentrant whenNotPaused validToken(token) onlyTradingToken(token) {
        // 1. 校验
        if (block.timestamp > deadline) revert TransactionExpired();
        if (tokenAmount == 0) revert InvalidParameters();
        if (IERC20(token).balanceOf(msg.sender) < tokenAmount) revert InsufficientBalance();

        // 2. BNB 计算
        uint256 bnbAmount = helper.calculateBNBAmountOut(tokenAmount, bondingCurve[token]);
        uint256 tradingFee = (bnbAmount * tradingFeeRate) / 10000;
        uint256 netBNBAmount = bnbAmount - tradingFee;

        // 3-4. 校验
        if (netBNBAmount < minBNBAmount) revert SlippageExceeded();
        if (bnbAmount > bondingCurve[token].collectedBNB) revert InsufficientBalance();

        // 5. 转入代币
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        // 6. 更新曲线
        bondingCurve[token].virtualBNBReserve -= bnbAmount;
        bondingCurve[token].virtualTokenReserve += tokenAmount;
        bondingCurve[token].availableTokens += tokenAmount;
        bondingCurve[token].collectedBNB -= bnbAmount;

        // 7. 转移 BNB
        _sendValue(platformFeeReceiver, tradingFee);
        _sendValue(msg.sender, netBNBAmount);

        emit TokenSold(
            token,
            msg.sender,
            tokenAmount,
            netBNBAmount,
            tradingFee,
            bondingCurve[token].virtualBNBReserve,
            bondingCurve[token].virtualTokenReserve,
            bondingCurve[token].availableTokens,
            bondingCurve[token].collectedBNB
        );
    }

    /**
     * @notice 毕业代币 - 添加 DEX 流动性
     * @dev 仅限 DEPLOYER_ROLE、防重入
     * 
     * @param token 代币地址
     * 
     * ============ 执行流程 ============
     * 
     * 1. 【读取数据】
     *    - 获取 collectedBNB 和 availableTokens
     * 
     * 2. 【计算费用分配】
     *    - platformFee = collectedBNB × graduationPlatformFeeRate / 10000
     *    - creatorFee = collectedBNB × graduationCreatorFeeRate / 10000
     *    - liquidityBNB = collectedBNB - platformFee - creatorFee
     *    - 代币同样按比例分配
     * 
     * 3. 【解除转账限制】
     *    - 切换代币为 NORMAL 模式
     * 
     * 4. 【添加流动性】
     *    - 授权 helper 操作代币
     *    - 调用 helper.addLiquidityV2
     *    - LP 代币发送到死地址（永久锁定）
     * 
     * 5. 【更新状态】
     *    - 切换为 GRADUATED
     * 
     * 6. 【分配费用】
     *    - BNB 平台费转给 graduateFeeReceiver
     *    - 代币平台费转给 graduateFeeReceiver
     *    - BNB 创作者费转给 creator
     *    - 代币创作者费转给 creator
     */
    function graduateToken(address token) external onlyRole(DEPLOYER_ROLE) validToken(token) nonReentrant {
        TokenInfo storage info = tokenInfo[token];
        BondingCurveParams storage curve = bondingCurve[token];

        // 1. 读取数据
        uint256 collectedBNB = curve.collectedBNB;
        uint256 remainingTokens = curve.availableTokens;

        // 2. 计算费用分配
        uint256 platformFee = collectedBNB * graduationPlatformFeeRate / 10000;
        uint256 creatorFee = collectedBNB * graduationCreatorFeeRate / 10000;
        uint256 liquidityBNB = collectedBNB - platformFee - creatorFee;

        uint256 tokenPlatformFee = remainingTokens * graduationPlatformFeeRate / 10000;
        uint256 tokenCreatorFee = remainingTokens * graduationCreatorFeeRate / 10000;
        uint256 liquidityTokens = remainingTokens - tokenPlatformFee - tokenCreatorFee;

        // 3. 解除转账限制
        MetaNodeToken(token).setTransferMode(MetaNodeToken.TransferMode.MODE_NORMAL);

        // 4. 添加流动性
        require(IERC20(token).balanceOf(address(this)) >= remainingTokens, "Insufficient token for liquidity");
        IERC20(token).approve(address(helper), liquidityTokens);
        uint256 liquidityResult = helper.addLiquidityV2{value: liquidityBNB}(token, liquidityBNB, liquidityTokens);

        // 5. 更新状态
        _changeTokenStatus(token, TokenStatus.GRADUATED);

        // 6. 分配费用
        _sendValue(graduateFeeReceiver, platformFee);
        if (tokenPlatformFee > 0) IERC20(token).safeTransfer(graduateFeeReceiver, tokenPlatformFee);
        _sendValue(info.creator, creatorFee);
        if (tokenCreatorFee > 0) IERC20(token).safeTransfer(info.creator, tokenCreatorFee);

        emit TokenGraduated(token, liquidityBNB, liquidityTokens, liquidityResult);
    }

    // ============ 代币状态管理 ============

    /**
     * @notice 暂停代币交易
     * @dev 仅限 PAUSER_ROLE
     */
    function pauseToken(address token) external onlyRole(PAUSER_ROLE) validToken(token) {
        _changeTokenStatus(token, TokenStatus.PAUSED);
        emit TokenPaused(token);
    }

    /**
     * @notice 恢复代币交易
     * @dev 仅限 PAUSER_ROLE，必须当前为 PAUSED
     */
    function unpauseToken(address token) external onlyRole(PAUSER_ROLE) validToken(token) {
        if (tokenInfo[token].status != TokenStatus.PAUSED) revert InvalidPausedStatus();
        _changeTokenStatus(token, TokenStatus.TRADING);
        emit TokenUnpaused(token);
    }

    /**
     * @notice 拉黑代币（紧急措施）
     * @dev 仅限 ADMIN_ROLE
     */
    function blacklistToken(address token) external onlyRole(ADMIN_ROLE) validToken(token) {
        _changeTokenStatus(token, TokenStatus.BLACKLISTED);
        emit TokenBlacklisted(token);
    }

    /**
     * @notice 解除代币黑名单
     * @dev 仅限 ADMIN_ROLE，必须当前为 BLACKLISTED
     */
    function removeFromBlacklist(address token) external onlyRole(ADMIN_ROLE) validToken(token) {
        if (tokenInfo[token].status != TokenStatus.BLACKLISTED) revert InvalidBlackListedStatus();
        _changeTokenStatus(token, TokenStatus.TRADING);
        emit TokenRemovedFromBlacklist(token);
    }

    // ============ 查询函数 ============

    /**
     * @notice 获取代币基础信息
     */
    function getTokenInfo(address token) external view returns (TokenInfo memory) {
        return tokenInfo[token];
    }

    /**
     * @notice 获取曲线参数
     */
    function getBondingCurve(address token) external view returns (BondingCurveParams memory) {
        return bondingCurve[token];
    }

    /**
     * @notice 计算买入可获得代币数（不含手续费）
     */
    function calculateBuyAmount(address token, uint256 bnbAmount) external view returns (uint256 tokenAmount) {
        BondingCurveParams memory curve = bondingCurve[token];
        tokenAmount = helper.calculateTokenAmountOut(bnbAmount, curve);
        if (tokenAmount > curve.availableTokens) {
            tokenAmount = curve.availableTokens;
        }
    }

    /**
     * @notice 计算买入可获得代币数（含手续费明细）
     */
    function calculateBuyAmountWithFee(address token, uint256 bnbAmount) external view returns (uint256 tokenOut, uint256 netBNB, uint256 feeBNB) {
        BondingCurveParams memory curve = bondingCurve[token];
        (tokenOut, netBNB, feeBNB) = helper.calculateTokenAmountOutWithFee(bnbAmount, curve, tradingFeeRate);
        if (tokenOut > curve.availableTokens) {
            tokenOut = curve.availableTokens;
            netBNB = helper.calculateRequiredBNB(tokenOut, curve);
            feeBNB = (netBNB * tradingFeeRate) / (10000 - tradingFeeRate);
        }
    }

    /**
     * @notice 计算卖出可获得 BNB（不含手续费）
     */
    function calculateSellReturn(address token, uint256 tokenAmount) external view returns (uint256) {
        return helper.calculateBNBAmountOut(tokenAmount, bondingCurve[token]);
    }

    /**
     * @notice 计算卖出可获得 BNB（含手续费明细）
     */
    function calculateSellReturnWithFee(address token, uint256 tokenAmount) external view returns (uint256 netBNB, uint256 feeBNB) {
        (netBNB, feeBNB) = helper.calculateBNBAmountOutWithFee(tokenAmount, bondingCurve[token], tradingFeeRate);
    }

    /**
     * @notice 计算初始买入所需 BNB
     * @param totalSupply 总供应量
     * @param virtualBNBReserve 初始虚拟 BNB 储备
     * @param virtualTokenReserve 初始虚拟代币储备
     * @param percentageBP 购买百分比（基点）
     * @return totalPayment 总支付金额（含手续费）
     * @return preBuyFee 初始买入手续费
     */
    function calculateInitialBuyBNB(
        uint256 totalSupply,
        uint256 virtualBNBReserve,
        uint256 virtualTokenReserve,
        uint256 percentageBP
    ) external view returns (uint256 totalPayment, uint256 preBuyFee) {
        if (percentageBP == 0) return (0, 0);
        if (percentageBP > MAX_INITIAL_BUY_PERCENTAGE) revert InvalidParameters();

        (, uint256 bnbRequired,,) = _calculateInitialBuy(
            totalSupply,
            virtualBNBReserve,
            virtualTokenReserve,
            percentageBP
        );
        preBuyFee = (bnbRequired * preBuyFeeRate) / 10000;
        totalPayment = bnbRequired + preBuyFee;
    }

    // ============ 内部函数 ============

    /**
     * @notice 安全发送 BNB
     * @dev 处理合约接收者和失败回退
     */
    function _sendValue(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (to == address(0)) {
            to = platformFeeReceiver;
            require(to != address(0), "Platform fee receiver not set");
        }
        uint32 size;
        assembly {
            size := extcodesize(to)
        }
        if (size > 0) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) {
                (bool fallbackSuccess,) = payable(platformFeeReceiver).call{value: amount}("");
                require(fallbackSuccess, "BNB_SEND_FAILED_TO_FALLBACK");
                emit CreatorFeeRedirected(to, platformFeeReceiver, amount);
            }
        } else {
            (bool ok,) = payable(to).call{value: amount}("");
            require(ok, "BNB_SEND_FAILED");
        }
    }

    /**
     * @notice 创建归属计划
     * @dev 处理初始买入代币的锁仓释放
     */
    function _createVestingSchedules(
        address tokenAddress,
        address beneficiary,
        uint256 initialTokens,
        uint256 initialBuyPercentage,
        uint256 totalSupply,
        VestingAllocation[] memory vestingAllocations
    ) internal returns (uint256 tokensToTransfer) {
        uint256 totalVestedAmount;
        uint256 totalBurnedAmount;

        // 统计归属和销毁数量
        for (uint256 i = 0; i < vestingAllocations.length; i++) {
            if (vestingAllocations[i].amount == 0) {
                revert InvalidAmountParameters();
            }
            if (vestingAllocations[i].mode == VestingMode.BURN) {
                totalBurnedAmount += vestingAllocations[i].amount;
            } else {
                totalVestedAmount += vestingAllocations[i].amount;
                if (vestingAllocations[i].mode == VestingMode.LINEAR) {
                    if (vestingAllocations[i].duration == 0) {
                        revert InvalidDurationParameters();
                    }
                    if (vestingAllocations[i].duration < minLockTime) {
                        revert InvalidDurationParameters();
                    }
                }
            }
        }

        if (initialBuyPercentage < totalVestedAmount + totalBurnedAmount) revert InvalidVestingParameters();
        
        // 计算实际代币数量
        uint256 tokensToVest = (totalSupply * totalVestedAmount) / 10000;
        uint256 tokensToBurn = (totalSupply * totalBurnedAmount) / 10000;
        if (initialTokens < tokensToVest + tokensToBurn) revert InvalidParameters();

        tokensToTransfer = initialTokens - tokensToVest - tokensToBurn;
        
        // 执行销毁
        if (tokensToBurn > 0) {
            MetaNodeToken(tokenAddress).burn(tokensToBurn);
            emit MetaNodeTokensBurned(tokenAddress, tokensToBurn);
        }
        
        // 创建归属计划
        if (tokensToVest > 0) {
            VestingAllocation[] memory actualVestingAllocations = new VestingAllocation[](vestingAllocations.length);

            uint256 allocatedTokens;
            TokenInfo memory info = tokenInfo[tokenAddress];
            uint256 actualLaunchTime = info.launchTime;
            if (actualLaunchTime == 0) {
                actualLaunchTime = block.timestamp;
            }
            
            int256 lastNonBurnIndex = - 1;
            for (uint256 i = 0; i < vestingAllocations.length; i++) {
                if (vestingAllocations[i].mode != VestingMode.BURN) {
                    lastNonBurnIndex = int256(i);
                }
            }
            
            for (uint256 i = 0; i < vestingAllocations.length; i++) {
                uint256 allocationAmount;
                if (vestingAllocations[i].mode == VestingMode.BURN) {
                    allocationAmount = 0;
                } else if (int256(i) == lastNonBurnIndex) {
                    allocationAmount = tokensToVest - allocatedTokens;
                } else {
                    allocationAmount = (totalSupply * vestingAllocations[i].amount) / 10000;
                    allocatedTokens += allocationAmount;
                }
                actualVestingAllocations[i] = VestingAllocation({
                    amount: allocationAmount,
                    launchTime: actualLaunchTime,
                    duration: vestingAllocations[i].duration,
                    mode: vestingAllocations[i].mode
                });
            }

            IERC20(tokenAddress).approve(address(vesting), tokensToVest);
            vesting.createVestingSchedules(
                tokenAddress,
                beneficiary,
                actualVestingAllocations
            );

            emit VestingCreated(
                tokenAddress,
                beneficiary,
                tokensToVest,
                actualVestingAllocations.length
            );
        }

        return tokensToTransfer;
    }

    /**
     * @notice 计算初始买入数量
     * @dev 使用恒定乘积公式反推
     */
    function _calculateInitialBuy(
        uint256 totalSupply,
        uint256 virtualBNBReserve,
        uint256 virtualTokenReserve,
        uint256 percentageBP
    ) internal pure returns (
        uint256 tokensOut,
        uint256 bnbRequired,
        uint256 newBNBReserve,
        uint256 newTokenReserve
    ) {
        if (percentageBP > MAX_INITIAL_BUY_PERCENTAGE) revert InvalidPercentageBP();
        
        // 计算目标代币数量
        tokensOut = (totalSupply * percentageBP) / 10000;

        // 使用恒定乘积公式计算
        uint256 k = virtualBNBReserve * virtualTokenReserve;
        newTokenReserve = virtualTokenReserve - tokensOut;
        newBNBReserve = k / newTokenReserve;
        bnbRequired = newBNBReserve - virtualBNBReserve;

        return (tokensOut, bnbRequired, newBNBReserve, newTokenReserve);
    }

    /**
     * @notice 更新代币状态
     */
    function _changeTokenStatus(address token, TokenStatus newStatus) internal {
        TokenStatus oldStatus = tokenInfo[token].status;
        tokenInfo[token].status = newStatus;
        emit TokenStatusChanged(token, oldStatus, newStatus);
    }

    /**
     * @notice 验证代币可交易
     */
    function _onlyTradingToken(address token) internal view {
        TokenInfo memory info = tokenInfo[token];
        if (info.status != TokenStatus.TRADING) {
            revert TokenNotTrading();
        }
        if (block.timestamp < info.launchTime) {
            revert TokenNotLaunchedYet();
        }
    }

    // ============ 管理函数 ============

    /**
     * @notice 设置平台费接收地址
     */
    function setPlatformFeeReceiver(address _receiver) external onlyRole(ADMIN_ROLE) {
        if (_receiver == address(0)) revert ZeroAddress();
        address oldPlatformFeeReceiver = platformFeeReceiver;
        platformFeeReceiver = _receiver;
        emit PlatformFeeReceiverChanged(oldPlatformFeeReceiver, _receiver);
    }

    /**
     * @notice 设置毕业费接收地址
     */
    function setGraduateFeeReceiver(address _receiver) external onlyRole(ADMIN_ROLE) {
        if (_receiver == address(0)) revert ZeroAddress();
        address oldGraduateFeeReceiver = graduateFeeReceiver;
        graduateFeeReceiver = _receiver;
        emit GraduateFeeReceiverChanged(oldGraduateFeeReceiver, _receiver);
    }

    /**
     * @notice 设置工厂合约
     */
    function setFactory(address _factory) external onlyRole(ADMIN_ROLE) {
        if (_factory == address(0)) revert ZeroAddress();
        address oldFactory = address(factory);
        factory = IMetaNodeFactory(_factory);
        emit FactoryChanged(oldFactory, _factory);
    }

    /**
     * @notice 设置助手合约
     */
    function setHelper(address _helper) external onlyRole(ADMIN_ROLE) {
        if (_helper == address(0)) revert ZeroAddress();
        address oldHelper = address(helper);
        helper = IMetaNodeHelper(_helper);
        emit HelperChanged(oldHelper, _helper);
    }

    /**
     * @notice 设置归属合约
     */
    function setVesting(address _vesting) external onlyRole(ADMIN_ROLE) {
        if (_vesting == address(0)) revert ZeroAddress();
        address oldVesting = _vesting;
        vesting = IMetaNodeVesting(_vesting);
        emit VestingChanged(oldVesting, _vesting);
    }

    /**
     * @notice 设置保证金接收地址
     */
    function setMarginReceiver(address _marginReceiver) external onlyRole(ADMIN_ROLE) {
        if (_marginReceiver == address(0)) revert ZeroAddress();
        address oldMarginReceiver = marginReceiver;
        marginReceiver = _marginReceiver;
        emit MarginReceiverChanged(oldMarginReceiver, _marginReceiver);
    }

    /**
     * @notice 设置创建费用
     * @param _fee 新费用（最大 0.1 BNB）
     */
    function setCreationFee(uint256 _fee) external onlyRole(ADMIN_ROLE) {
        if (_fee > 0.1 ether) revert InvalidAmountParameters();
        creationFee = _fee;
        emit CreationFeeChanged(_fee);
    }

    /**
     * @notice 设置初始买入费率
     * @param _rate 费率基点（最大 600 = 6%）
     */
    function setPreBuyFeeRate(uint256 _rate) external onlyRole(ADMIN_ROLE) {
        if (_rate > 600) revert InvalidAmountParameters();
        preBuyFeeRate = _rate;
        emit PreBuyFeeRateChanged(_rate);
    }

    /**
     * @notice 设置交易费率
     * @param _rate 费率基点（最大 200 = 2%）
     */
    function setTradingFeeRate(uint256 _rate) external onlyRole(ADMIN_ROLE) {
        if (_rate > 200) revert InvalidAmountParameters();
        tradingFeeRate = _rate;
        emit TradingFeeRateChanged(_rate);
    }

    /**
     * @notice 设置毕业费率
     * @param _platformRate 平台费率（最大 1100 = 11%）
     * @param _creatorRate 创作者费率（最大 500 = 5%）
     */
    function setGraduationFeeRates(uint256 _platformRate, uint256 _creatorRate) external onlyRole(ADMIN_ROLE) {
        if (_platformRate > 1100 || _creatorRate > 500) revert InvalidAmountParameters();
        graduationPlatformFeeRate = _platformRate;
        graduationCreatorFeeRate = _creatorRate;
        emit GraduationFeeRatesChanged(_platformRate, _creatorRate);
    }

    /**
     * @notice 设置最小锁仓时间
     */
    function setMinLockTime(uint256 _time) external onlyRole(ADMIN_ROLE) {
        minLockTime = _time;
        emit MinLockTimeChanged(_time);
    }

    /**
     * @notice 暂停合约
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice 恢复合约
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice 紧急提取资产
     * @param token 代币地址（address(0) 为 BNB）
     * @param amount 提取数量
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) {
            payable(msg.sender).transfer(amount);
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
    }

    /**
     * @notice 授权合约升级
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    /**
     * @notice 接收 BNB
     */
    receive() external payable {}
}
