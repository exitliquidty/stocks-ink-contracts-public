// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Minimal stand-in for StocksHook's own IStocksHookMinimal surface -- just
/// enough real behavior (pull the sell amount in on submitOrder, release a fixed-rate amount of
/// tstToken pro-rata to elapsed time on claim) to exercise StocksStaking's OWN
/// accounting (vested-floor protection, rewardRate reduction, pendingLiquidationExpiration
/// gating) in isolation from TWAMM's real pricing/order-matching internals -- those are already
/// proven against a real PoolManager by StocksLaunchFactory.freshfork.t.sol. Deliberately supports
/// only ONE outstanding order at a time (matching StocksStaking's own single-slot
/// design), keyed by owner, not the full OrderKey space a real TWAMM tracks.
contract MockHookV5 {
    struct SubmitOrderParams {
        PoolKey key;
        bool zeroForOne;
        uint256 duration;
        uint256 amountIn;
    }

    struct OrderKey {
        address owner;
        uint160 expiration;
        bool zeroForOne;
    }

    struct SyncParams {
        PoolKey key;
        OrderKey orderKey;
    }

    struct Order {
        uint256 amountIn;
        uint256 claimed;
        uint256 startedAt;
        uint256 expiration;
    }

    IERC20 public immutable stockToken;
    IERC20 public immutable tstToken;
    uint256 public immutable expirationInterval;
    // Fixed exchange rate for this mock only -- real TWAMM prices against live pool liquidity;
    // this just needs to release SOME TST deterministically so the staking contract's own
    // accounting (not TWAMM's pricing) can be tested. 1 stock wei -> RATE TST wei.
    uint256 public immutable rate;

    mapping(address => Order) public orders;

    // ABI-shape-compatible with IStocksHookMinimal.Order (StocksStaking.sol) / real TWAMM's own
    // Order struct -- Solidity's ABI encoding only cares about the field types/order matching,
    // not the struct name, so this cross-contract call works despite the different declared type.
    struct HookOrder {
        uint256 sellRate;
        uint256 earningsFactorLast;
    }

    error OrderAlreadyExists();
    error NoOrder();

    // The two things in-kind redemption reads from the real hook (StocksHook.launches / PROTOCOL_FEE_SHARE_BPS):
    // who the protocol's share goes to, and this pool's cost in bps. Defaults match a real pool (10%, protocol
    // gets 20% of it); tests can change them.
    address public launchProtocol = address(0xFEED);
    uint256 public launchFeeBps = 1_000;
    uint256 public constant PROTOCOL_FEE_SHARE_BPS = 2_000;

    function setLaunchInfo(address protocol_, uint256 feeBps_) external {
        launchProtocol = protocol_;
        launchFeeBps = feeBps_;
    }

    function launches(bytes32)
        external
        view
        returns (bool, bool, address, address, address, address, uint256)
    {
        return (true, false, address(tstToken), address(stockToken), address(0), launchProtocol, launchFeeBps);
    }

    constructor(IERC20 stockToken_, IERC20 tstToken_, uint256 expirationInterval_, uint256 rate_) {
        stockToken = stockToken_;
        tstToken = tstToken_;
        expirationInterval = expirationInterval_;
        rate = rate_;
    }

    function submitOrder(SubmitOrderParams calldata params) external returns (bytes32 orderId, OrderKey memory orderKey) {
        if (orders[msg.sender].expiration > block.timestamp) revert OrderAlreadyExists();
        stockToken.transferFrom(msg.sender, address(this), params.amountIn);
        uint256 expiration = ((block.timestamp / expirationInterval) * expirationInterval) + params.duration;
        orderKey = OrderKey({owner: msg.sender, expiration: uint160(expiration), zeroForOne: params.zeroForOne});
        orderId = keccak256(abi.encode(orderKey));
        orders[msg.sender] = Order({amountIn: params.amountIn, claimed: 0, startedAt: block.timestamp, expiration: expiration});
    }

    function sync(SyncParams calldata) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    /// @dev Releases tstToken pro-rata to elapsed time since the order started, same "claim
    /// whatever has filled so far, repeatable" semantics as real TWAMM. token0/token1 assignment
    /// mirrors whichever currency in `key` isn't the stock side.
    function claimTokensByPoolKey(PoolKey calldata key) external returns (uint256 tokens0, uint256 tokens1) {
        Order storage o = orders[msg.sender];
        if (o.amountIn == 0) revert NoOrder();

        uint256 elapsed = block.timestamp >= o.expiration ? o.expiration - o.startedAt : block.timestamp - o.startedAt;
        uint256 totalDuration = o.expiration - o.startedAt;
        uint256 totalTstOut = o.amountIn * rate;
        uint256 vested = totalDuration == 0 ? totalTstOut : (totalTstOut * elapsed) / totalDuration;
        uint256 owed = vested > o.claimed ? vested - o.claimed : 0;
        o.claimed += owed;

        if (owed > 0) tstToken.transfer(msg.sender, owed);

        bool stockIsCurrency0 = Currency.unwrap(key.currency0) == address(stockToken);
        if (stockIsCurrency0) {
            tokens1 = owed;
        } else {
            tokens0 = owed;
        }
    }

    /// @dev Added for StocksStaking.liquidateTreasury's own AUDIT FIX (see that function's
    /// comment): a real, non-reverting lookup callers use to check "is there still something
    /// unclaimed here" before deciding whether to auto-claim. sellRate != 0 exactly when this
    /// owner's order still has unclaimed value -- 0 both for an owner that never submitted one
    /// (mapping default) and for one that's been fully claimed out, matching real TWAMM's own
    /// "deleted once fully settled" semantics closely enough for this mock's purpose.
    function getOrder(PoolKey calldata, OrderKey calldata orderKey) external view returns (HookOrder memory) {
        Order storage o = orders[orderKey.owner];
        uint256 totalTstOut = o.amountIn * rate;
        uint256 sellRate = o.claimed < totalTstOut ? o.amountIn : 0;
        return HookOrder({sellRate: sellRate, earningsFactorLast: 0});
    }
}
