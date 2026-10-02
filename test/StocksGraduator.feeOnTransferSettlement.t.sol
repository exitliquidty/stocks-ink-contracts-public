// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {StocksGraduator} from "../src/dex/v4/StocksGraduator.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract PlainMockERC20FS is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }
}

/// @dev Takes a flat 1% cut on every transfer/transferFrom, sent to a dead sink.
contract FeeOnTransferMockERC20FS is ERC20 {
    uint256 public constant FEE_BPS = 100; // 1%

    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || value == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * FEE_BPS) / 10_000;
        super._update(from, address(0xFEE), fee);
        super._update(from, to, value - fee);
    }
}

contract MockCurveRegistryFS {
    mapping(address => address) public curveOf;

    function setCurve(address token, address curve) external {
        curveOf[token] = curve;
    }
}

/// @notice Round 24: a fee-on-transfer token must FAIL CLOSED at graduation, for a known reason.
///
/// StocksGraduator.audit3.t.sol documents that such a token cannot graduate, but only with a bare
/// `vm.expectRevert()`, which passes whatever the reason. This file pins the reason: the PoolManager credits
/// what it actually receives, the settlement comes up short by the token's cut, and `unlock` reverts with
/// v4-core's own `CurrencyNotSettled()`. Nothing moves; the curve keeps everything.
///
/// A candidate change was tried and rejected this round: have `_settleCurrency` measure what the PoolManager
/// received and top up the shortfall in a bounded loop. Measured against these same tokens it did not help.
/// The graduator sizes the position from its entire balance, so after the first settlement transfer it holds
/// only rounding dust, and the very first top-up reverted `ERC20InsufficientBalance`: same outcome, more code.
/// Making it genuinely work would mean sizing liquidity below what the graduator holds, and that would be the
/// wrong goal anyway. `StocksHook._takeExact` requires exact receipts on every swap that charges the flywheel
/// cost, so a fee-on-transfer stock that DID graduate would have its seed locked forever in a pool whose
/// swaps revert. Reverting at graduation, while holders can still sell back to the curve, is the safe
/// behaviour. No currently attestable token charges a transfer cut (the 723-wrapper sweep confirms it).
contract StocksGraduatorFeeOnTransferSettlementTest is Test {
    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant FEE_BPS = 1_000;

    IPoolManager poolManager;
    StocksHook hook;
    StocksGraduator graduator;
    MockCurveRegistryFS registry;

    address realTreasury = address(0xCAFE);
    address realProtocol = address(0xF00D);

    function setUp() public {
        vm.createSelectFork("ink");
        poolManager = IPoolManager(POOL_MANAGER);
        require(address(poolManager).code.length > 0, "PoolManager not deployed on this fork");

        registry = new MockCurveRegistryFS();

        uint256 nonceBeforeHook = vm.getNonce(address(this));
        address predictedGraduator = vm.computeCreateAddress(address(this), nonceBeforeHook + 1);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, predictedGraduator, uint256(1 hours));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(StocksHook).creationCode, constructorArgs);
        hook = new StocksHook{salt: salt}(poolManager, predictedGraduator, uint256(1 hours));
        require(address(hook) == hookAddress, "hook address mismatch");

        graduator = new StocksGraduator(poolManager, hook, address(registry));
        require(address(graduator) == predictedGraduator, "graduator address mismatch");
    }

    function test_FeeOnTransferStock_FailsClosed_WithCurrencyNotSettled() public {
        PlainMockERC20FS tst = new PlainMockERC20FS("Acme", "ACME", SUPPLY);
        FeeOnTransferMockERC20FS stock = new FeeOnTransferMockERC20FS("Stock", "STOCK", SUPPLY);
        registry.setCurve(address(tst), address(this));

        uint256 tstSeed = (tst.totalSupply() * 20) / 100;
        uint256 stockSeed = 5_000e18;
        tst.approve(address(graduator), tstSeed);
        stock.approve(address(graduator), stockSeed);

        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, tstSeed, stockSeed);

        assertEq(tst.balanceOf(address(this)), SUPPLY, "the curve keeps all its TST");
        assertEq(stock.balanceOf(address(this)), SUPPLY, "the curve keeps all its stock");
        assertEq(stock.balanceOf(address(hook)) + tst.balanceOf(address(hook)), 0, "nothing reached the hook");
    }

    function test_FeeOnTransferTst_FailsClosed_WithCurrencyNotSettled() public {
        FeeOnTransferMockERC20FS tst = new FeeOnTransferMockERC20FS("Acme", "ACME", SUPPLY);
        PlainMockERC20FS stock = new PlainMockERC20FS("Stock", "STOCK", SUPPLY);
        registry.setCurve(address(tst), address(this));

        uint256 tstSeed = (tst.totalSupply() * 20) / 100;
        uint256 stockSeed = 5_000e18;
        tst.approve(address(graduator), tstSeed);
        stock.approve(address(graduator), stockSeed);

        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, tstSeed, stockSeed);

        assertEq(tst.balanceOf(address(this)), SUPPLY, "the curve keeps all its TST");
        assertEq(stock.balanceOf(address(this)), SUPPLY, "the curve keeps all its stock");
        assertEq(stock.balanceOf(address(hook)) + tst.balanceOf(address(hook)), 0, "nothing reached the hook");
    }

    function test_PlainTokens_GraduateCleanly_ManagerReceivesExactlyWhatTheGraduatorSpent() public {
        PlainMockERC20FS tst = new PlainMockERC20FS("Acme", "ACME", SUPPLY);
        PlainMockERC20FS stock = new PlainMockERC20FS("Stock", "STOCK", SUPPLY);
        registry.setCurve(address(tst), address(this));

        uint256 tstSeed = (tst.totalSupply() * 20) / 100;
        uint256 stockSeed = 5_000e18;
        tst.approve(address(graduator), tstSeed);
        stock.approve(address(graduator), stockSeed);

        uint256 pmTstBefore = tst.balanceOf(address(poolManager));
        uint256 pmStockBefore = stock.balanceOf(address(poolManager));
        graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, tstSeed, stockSeed);

        uint256 pmTst = tst.balanceOf(address(poolManager)) - pmTstBefore;
        uint256 pmStock = stock.balanceOf(address(poolManager)) - pmStockBefore;
        console.log("pool TST / stock:", pmTst, pmStock);

        assertEq(tst.balanceOf(address(graduator)), 0, "graduator keeps no TST");
        assertEq(stock.balanceOf(address(graduator)), 0, "graduator keeps no stock");
        // Every wei is accounted for: pool + hook reserve + swept dust.
        assertEq(
            pmTst + graduator.HOOK_TST_RESERVE_WEI() + tst.balanceOf(graduator.BURN_ADDRESS()), tstSeed, "TST conserved"
        );
        assertEq(
            pmStock + graduator.HOOK_STOCK_RESERVE_WEI() + stock.balanceOf(realTreasury), stockSeed, "stock conserved"
        );
    }
}
