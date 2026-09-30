// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {StocksGraduator} from "../src/dex/v4/StocksGraduator.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract MockERC20G3 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }
}

/// @dev Takes a flat 1% cut on every transfer/transferFrom, sent to a dead sink -- the simplest
/// possible fee-on-transfer token, used here to pin down EXACTLY where in StocksGraduator's own
/// call stack a non-standard token first causes trouble, in isolation from the full
/// StocksLaunchFactory/StocksCurve flow the sibling StocksHook audit already exercised end to end.
contract FeeOnTransferMockERC20G3 is ERC20 {
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

contract MockCurveRegistryG3 {
    mapping(address => address) public curveOf;

    function setCurve(address token, address curve) external {
        curveOf[token] = curve;
    }
}

/// @notice Round-3 audit on StocksGraduator.sol -- isolates the graduator itself (bypassing the
/// full StocksLaunchFactory/StocksCurve flow) against a fee-on-transfer token, to pin down exactly
/// where and how it fails, corroborating the companion StocksHook round's finding (fee-on-transfer
/// stockToken bricks graduation via v4-core's CurrencyNotSettled) from this contract's own code
/// path rather than re-deriving it from scratch. Also documents that the existing
/// StocksGraduator.security.t.sol reentrancy suite (test_ReentrantTstToken_/StockToken_
/// CannotReenterGraduateDuringPull) already fully covers the malicious-token-reentrancy angle this
/// round was asked to check -- confirmed by reading those tests, not re-asserted here.
contract StocksGraduatorAudit3Test is Test {
    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant FEE_BPS = 1_000;

    IPoolManager poolManager;
    StocksHook hook;
    StocksGraduator graduator;
    MockCurveRegistryG3 registry;

    address realTreasury = address(0xCAFE);
    address realProtocol = address(0xF00D);

    function setUp() public {
        vm.createSelectFork("ink");
        poolManager = IPoolManager(POOL_MANAGER);
        require(address(poolManager).code.length > 0, "PoolManager not deployed on this fork");

        registry = new MockCurveRegistryG3();

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

    /// @dev FINDING (High, shared root cause with the companion StocksHook audit): graduate()
    /// trusts the REQUESTED tstAmount/stockAmount for every downstream calculation -- it pulls
    /// tokens in via plain transferFrom and then hands PoolManager the ORIGINAL requested amounts
    /// to settle, with no balance-diff check on what it actually received. For a fee-on-transfer
    /// stockToken, the graduator ends up holding strictly less than stockSeed, but still tries to
    /// settle PoolManager for the full stockSeed -- PoolManager's own exact-amount accounting
    /// (NonzeroDeltaCount) then reverts with CurrencyNotSettled(), permanently bricking graduation
    /// for that curve. This corroborates the StocksHook round's identical finding from this
    /// contract's own code path.
    function test_AUDIT_FeeOnTransferStockToken_FailsInsideGraduateItself() public {
        MockERC20G3 tst = new MockERC20G3("Acme", "ACME", SUPPLY);
        FeeOnTransferMockERC20G3 stock = new FeeOnTransferMockERC20G3("Stock", "STOCK", SUPPLY);
        registry.setCurve(address(tst), address(this));

        uint256 tstSeed = (tst.totalSupply() * 20) / 100;
        uint256 stockSeed = 5_000e18;
        tst.approve(address(graduator), tstSeed);
        stock.approve(address(graduator), stockSeed);

        vm.expectRevert();
        graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, tstSeed, stockSeed);

        console.log("CONFIRMED: a fee-on-transfer stockToken bricks graduate() (PoolManager settlement mismatch)");
    }

    function test_AUDIT_FeeOnTransferTstToken_FailsInsideGraduateItself() public {
        FeeOnTransferMockERC20G3 tst = new FeeOnTransferMockERC20G3("Acme", "ACME", SUPPLY);
        MockERC20G3 stock = new MockERC20G3("Stock", "STOCK", SUPPLY);
        registry.setCurve(address(tst), address(this));

        uint256 tstSeed = (tst.totalSupply() * 20) / 100;
        uint256 stockSeed = 5_000e18;
        tst.approve(address(graduator), tstSeed);
        stock.approve(address(graduator), stockSeed);

        vm.expectRevert();
        graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, tstSeed, stockSeed);

        console.log("CONFIRMED: a fee-on-transfer tstToken bricks graduate() too, from either token side");
    }
}
