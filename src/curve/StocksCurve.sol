// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Stocks.ink. All rights reserved. No license to use, copy, modify, deploy or distribute this code is granted without the written permission of Stocks.ink.

// ╔══════════════════════════════════════════════════════════════════╗
// ║                                                                  ║
// ║   S T O C K S . I N K                                            ║
// ║                                                                  ║
// ║   Tokenized Stock Treasuries (TSTs): the inverse of a Digital    ║
// ║   Asset Treasury (DAT).                                          ║
// ║                                                                  ║
// ╚══════════════════════════════════════════════════════════════════╝
//
// A TST turns its own trading volume into a growing on-chain treasury of
// tokenized equities, directed by its community and distributed to stakers.

pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {TSTToken} from "../TSTToken.sol";
import {StocksStaking} from "../StocksStaking.sol";
import {StocksStakingFactory} from "../StocksStakingFactory.sol";
import {StocksGraduator} from "../dex/v4/StocksGraduator.sol";
import {StocksPoolView} from "../dex/v4/StocksPoolView.sol";
import {StocksGovernorFactory} from "../governance/StocksGovernorFactory.sol";

/// @notice The part of the launch factory the curve reads its generation-wide configuration from.
interface IGovernableFactoryV5 {
    /// @notice Recipient of the protocol's share of the flywheel cost.
    function protocol() external view returns (address);
    /// @notice The v4 hook pools are created on.
    function hook() external view returns (address);
    /// @notice Governor spawner.
    function governorFactory() external view returns (address);
    /// @notice Staking spawner.
    function stakingFactory() external view returns (address);
    /// @notice Pool seeder.
    function v4Graduator() external view returns (address);
    /// @notice Governor voting delay, in seconds.
    function votingDelay() external view returns (uint48);
    /// @notice Governor voting period, in seconds.
    function votingPeriod() external view returns (uint32);
    /// @notice Proposal threshold in basis points of circulating supply.
    function proposalThresholdBps() external view returns (uint256);
}

/// @title StocksCurve
/// @notice The bonding curve a TST trades on from launch until graduation. Buyers pay in the tokenized stock
/// and receive TST; sellers do the reverse. No cost is charged on the curve.
/// @dev A constant-product curve over a VIRTUAL stock reserve: the invariant is
/// `(virtualStockReserve + realStockCollected) * (CURVE_SUPPLY - tokensSold)`, and every quote rounds against
/// the trader so the invariant can only grow. The curve holds the whole TST supply and all stock collected.
/// Once enough stock is collected anyone may call `graduate()`, which in one transaction deploys the token's
/// governor and staking contract, moves ALL collected stock and a price-matched amount of TST into a
/// permanently locked Uniswap v4 position, and burns every other TST the curve still holds. After that the
/// curve is inert. There is no owner and no privileged function.
contract StocksCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The TST this curve sells.
    TSTToken public immutable tstToken;
    /// @notice The tokenized stock the curve is priced in.
    IERC20 public immutable stockToken;
    /// @notice The launch factory that deployed this curve; source of the generation's configuration.
    address public immutable factory;
    /// @notice Deployment time; start of the anti-snipe window.
    uint256 public immutable launchTimestamp;
    /// @notice Stock (in wei) the curve must collect before it can graduate. Fixed at launch from the attested
    /// price: `graduationUsdThreshold / price`.
    uint256 public immutable graduationStockTarget;
    /// @notice The virtual stock reserve that sets the opening price: a third of the graduation target.
    uint256 public immutable virtualStockReserve;
    /// @notice Reward period the staking contract is created with at graduation.
    uint256 public immutable rewardsDuration;

    /// @notice Total TST supply.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    /// @notice TST available for sale on the curve.
    uint256 public constant CURVE_SUPPLY = 800_000_000e18;
    /// @notice TST never offered on the curve. It is not allocated to anyone: whatever of it is not needed to
    /// seed the pool is burned at graduation.
    uint256 public constant RESERVED_SUPPLY = TOTAL_SUPPLY - CURVE_SUPPLY;
    /// @notice The virtual reserve is the graduation target divided by this.
    uint256 public constant VIRTUAL_RESERVE_DIVISOR = 3;
    /// @notice Length of the anti-snipe window after launch.
    uint256 public constant SNIPE_WINDOW = 60 seconds;
    /// @notice Most TST one address may buy during the anti-snipe window, in basis points of `CURVE_SUPPLY`.
    /// @dev Per address, so it is a speed bump and not a guarantee: it can be split across addresses.
    uint256 public constant MAX_SNIPE_BUY_BPS = 500;
    /// @notice Basis-point denominator.
    uint256 public constant BPS_DENOM = 10_000;
    // External audit finding (AuditAgent, 2026-09-30): at the old 9,900 (99%) threshold, `remaining`
    // (CURVE_SUPPLY * 1% = 8,000,000e18 TST) was already below StocksGraduator's own 10,000,000e18 TST
    // minimum seed (1% of TOTAL_SUPPLY) -- the sold-out graduation path was mathematically guaranteed to
    // revert SeedTooSmall at its own trigger point, every time, for every launch. Lowered to a threshold
    // with real margin under the new buy()-side SeedWouldBeUnreachable guard (which independently caps
    // trading at roughly 98.75% in the best-funded case, less in others) so the sold-out path stays a
    // genuinely reachable fallback rather than silently becoming dead code once that guard exists.
    uint256 public constant SOLDOUT_THRESHOLD_BPS = 9_700;
    /// @notice The flywheel cost, in basis points, registered for the pool at graduation. Not charged on the curve.
    uint256 public constant FEE_BPS = 1000;
    /// @notice Oldest price attestation accepted at launch.
    uint256 public constant PRICE_MAX_AGE = 5 minutes;
    /// @notice Scale of the attested USD price and of the graduation threshold.
    uint256 public constant PRICE_DECIMALS = 1e18;

    /// @notice Quorum, as a percentage of circulating supply, given to the governor at graduation.
    uint256 public constant QUORUM_NUMERATOR = 10;

    /// @notice Where burned TST is sent.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Signer the launch price attestation was verified against.
    address public immutable trustedSigner;

    /// @notice Stock the curve has taken in from buys, net of what sells have paid back out. Donations sent
    /// straight to the curve are not counted here.
    uint256 public realStockCollected;
    /// @notice TST currently sold from the curve, net of what has been sold back.
    uint256 public tokensSold;
    /// @notice True once the pool has been seeded. Trading on the curve is closed from then on.
    bool public graduated;
    /// @notice The pool's view contract, set at graduation.
    address public pair;
    /// @notice The token's staking contract (its treasury), set at graduation.
    address public staking;
    /// @notice The token's governor, set at graduation.
    address public governor;

    /// @notice TST each address has bought during the anti-snipe window. Not reduced by selling.
    mapping(address => uint256) public snipeWindowBought;

    /// @notice Emitted on every buy.
    /// @param buyer The buyer.
    /// @param stockIn Stock the curve actually received.
    /// @param tstOut TST sent to the buyer.
    event Bought(address indexed buyer, uint256 stockIn, uint256 tstOut);
    /// @notice Emitted on every sell.
    /// @param seller The seller.
    /// @param tstIn TST returned to the curve.
    /// @param stockOut Stock the seller actually received.
    event Sold(address indexed seller, uint256 tstIn, uint256 stockOut);
    /// @notice Emitted once, at graduation.
    /// @param pair The pool's view contract.
    /// @param staking The token's staking contract.
    /// @param governor The token's governor.
    /// @param stockCollected Stock moved into the pool.
    /// @param tstReserved TST moved into the pool.
    event Graduated(
        address indexed pair, address indexed staking, address indexed governor, uint256 stockCollected, uint256 tstReserved
    );

    /// @notice The curve has graduated; trading here is closed.
    error AlreadyGraduated();
    /// @notice An amount, or the result it would produce, is zero.
    error ZeroAmount();
    /// @notice A constructor address argument was zero.
    error ZeroAddress();
    /// @notice The trade would return less than the caller's minimum.
    error SlippageExceeded();
    /// @notice The buy would take the caller past the anti-snipe cap.
    error SnipeCapExceeded();
    /// @notice The buy would exceed the curve's supply.
    error CurveSoldOut();
    /// @notice More TST is being sold back than the curve has sold.
    error InsufficientTstSupply();
    /// @notice Neither graduation condition is met yet.
    error NotReady();
    /// @notice The attested price is zero, or so large that the curve's reserves would round to zero.
    error InvalidPrice();
    /// @notice The attestation was not signed by the trusted signer.
    error InvalidSignature();
    /// @notice The attestation is older than `PRICE_MAX_AGE` or dated in the future.
    error StalePrice();
    /// @notice The reward duration is outside the allowed range.
    error InvalidRewardsDuration();
    /// @notice The stock token reports a `decimals()` other than 18.
    error UnsupportedStockDecimals();
    /// @notice The buy would leave too little TST to seed the pool at graduation.
    error SeedWouldBeUnreachable();

    /// @notice Verifies the price attestation and fixes the curve's shape.
    /// @dev Reverts unless the attestation is fresh and signed by `_trustedSigner` over
    /// (`_factory`, `_stockToken`, `price`, `priceTimestamp`).
    /// @param _tstToken The TST to sell.
    /// @param _stockToken The tokenized stock to price in. Must not report a `decimals()` other than 18.
    /// @param _trustedSigner Signer the attestation must recover to.
    /// @param price Attested USD price of one whole stock token, 18 decimals.
    /// @param priceTimestamp Time of the attestation.
    /// @param signature The attestation signature.
    /// @param _rewardsDuration Reward period for the staking contract created at graduation.
    /// @param _factory The launch factory. Part of the signed message.
    /// @param _graduationUsdThreshold USD (18 decimals) of stock the curve must collect to graduate.
    /// @param _minRewardsDuration Lower bound for `_rewardsDuration`.
    /// @param _maxRewardsDuration Upper bound for `_rewardsDuration`.
    constructor(
        address _tstToken,
        address _stockToken,
        address _trustedSigner,
        uint256 price,
        uint256 priceTimestamp,
        bytes memory signature,
        uint256 _rewardsDuration,
        address _factory,
        uint256 _graduationUsdThreshold,
        uint256 _minRewardsDuration,
        uint256 _maxRewardsDuration
    ) {
        if (_tstToken == address(0) || _stockToken == address(0) || _trustedSigner == address(0) || _factory == address(0)) {
            revert ZeroAddress();
        }
        if (_rewardsDuration < _minRewardsDuration || _rewardsDuration > _maxRewardsDuration) {
            revert InvalidRewardsDuration();
        }

        // Every quote and every reserve constant here assumes 18-decimal stock wei; a stock token that plainly
        // ADVERTISES a different decimals() would silently mis-price the whole curve (not a fund-theft path, a
        // deploy-time misconfiguration that could make graduation unreachable or trivial). A low-level staticcall,
        // not a high-level interface call: a token that does not implement decimals() at all (optional per EIP-20;
        // also every bare test placeholder address) returns no data and is left alone -- this can only catch a
        // clear, self-reported mismatch, not every malformed token. (A high-level `try IERC20Metadata(...).decimals()`
        // was tried first and reverted here instead of degrading gracefully: Foundry's test simulator hard-reverts a
        // call to an address with no code even inside try/catch, unlike a real chain, which just returns no data --
        // see feedback_foundry_nocode_call_bypasses_trycatch. The low-level staticcall behaves identically on both.)
        (bool decimalsOk, bytes memory decimalsData) = _stockToken.staticcall(abi.encodeWithSignature("decimals()"));
        if (decimalsOk && decimalsData.length >= 32 && abi.decode(decimalsData, (uint256)) != 18) {
            revert UnsupportedStockDecimals();
        }

        tstToken = TSTToken(_tstToken);
        stockToken = IERC20(_stockToken);
        trustedSigner = _trustedSigner;
        factory = _factory;
        launchTimestamp = block.timestamp;
        rewardsDuration = _rewardsDuration;

        if (price == 0) revert InvalidPrice();
        if (priceTimestamp > block.timestamp || block.timestamp - priceTimestamp > PRICE_MAX_AGE) {
            revert StalePrice();
        }

        bytes32 attestationHash = keccak256(abi.encodePacked(factory, _stockToken, price, priceTimestamp));
        address signer = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(attestationHash), signature);
        if (signer != _trustedSigner) revert InvalidSignature();

        graduationStockTarget = (_graduationUsdThreshold * PRICE_DECIMALS) / price;
        if (graduationStockTarget == 0) revert InvalidPrice();
        virtualStockReserve = graduationStockTarget / VIRTUAL_RESERVE_DIVISOR;
        // graduationStockTarget != 0 alone isn't enough: a target of 1 or 2 still floors this division to zero,
        // and quoteBuy()/quoteSell() use virtualStockReserve + realStockCollected as the pool's "old" side of the
        // constant-product formula -- with realStockCollected also at 0 pre-launch, that leaves oldVirtualStock at
        // 0 for the very first trade, so quoteBuy would hand the entire remaining curve supply to whoever buys
        // first, for any nonzero amount in. Only reachable via an extreme signed price (see InvalidPrice's other
        // guard above -- already a trusted-signer boundary), but the failure mode is total and irreversible, so
        // it gets its own explicit floor rather than relying on that trust alone.
        if (virtualStockReserve == 0) revert InvalidPrice();
    }

    /// @notice TST a buy of `stockIn` would return right now.
    /// @dev Constant product over the virtual reserve. The new TST reserve is rounded up, so the amount out is
    /// rounded down.
    /// @param stockIn Stock paid in.
    /// @return tstOut TST received.
    function quoteBuy(uint256 stockIn) public view returns (uint256 tstOut) {
        if (stockIn == 0) return 0;
        uint256 remaining = CURVE_SUPPLY - tokensSold;
        uint256 oldVirtualStock = virtualStockReserve + realStockCollected;
        uint256 newVirtualStock = oldVirtualStock + stockIn;
        tstOut = remaining - Math.ceilDiv(oldVirtualStock * remaining, newVirtualStock);
    }

    /// @notice Stock a sale of `tstIn` would return right now.
    /// @dev The new stock reserve is rounded up, so the amount out is rounded down. Selling everything the curve
    /// has sold can therefore never return more than `realStockCollected`.
    /// @param tstIn TST sold back.
    /// @return stockOut Stock received.
    function quoteSell(uint256 tstIn) public view returns (uint256 stockOut) {
        if (tstIn == 0) return 0;
        uint256 remaining = CURVE_SUPPLY - tokensSold;
        uint256 oldVirtualStock = virtualStockReserve + realStockCollected;
        uint256 newRemaining = remaining + tstIn;
        stockOut = oldVirtualStock - Math.ceilDiv(oldVirtualStock * remaining, newRemaining);
    }

    /// @notice Buys TST with stock.
    /// @dev Prices off the stock the curve actually receives, not the amount requested. Refuses any buy that
    /// would leave the curve unable to seed its pool, and applies the per-address cap during the anti-snipe
    /// window. Buying stays open after the graduation target is reached, until someone calls `graduate()`.
    /// @param stockIn Stock to pay. Must be approved to the curve.
    /// @param minTstOut Smallest acceptable amount of TST.
    /// @return tstOut TST sent to the caller.
    function buy(uint256 stockIn, uint256 minTstOut) external nonReentrant returns (uint256 tstOut) {
        if (graduated) revert AlreadyGraduated();
        if (stockIn == 0) revert ZeroAmount();

        uint256 balanceBefore = stockToken.balanceOf(address(this));
        stockToken.safeTransferFrom(msg.sender, address(this), stockIn);
        uint256 actualStockIn = stockToken.balanceOf(address(this)) - balanceBefore;
        if (actualStockIn == 0) revert ZeroAmount();

        tstOut = quoteBuy(actualStockIn);
        if (tstOut == 0) revert ZeroAmount();
        if (tokensSold + tstOut > CURVE_SUPPLY) revert CurveSoldOut();
        if (tstOut < minTstOut) revert SlippageExceeded();

        // External audit finding (AuditAgent, 2026-09-30): buy() had no cap preventing `tokensSold` from
        // approaching CURVE_SUPPLY, so sufficiently aggressive buying -- via EITHER the target-reached OR
        // sold-out graduation path, and regardless of which one a caller eventually uses -- could push
        // `remaining` (and so the price-matched seed `_graduate()` computes) below StocksGraduator's own
        // MIN_TST_SEED_SUPPLY_BPS floor, permanently preventing that curve from ever graduating. Confirmed
        // directly: at exactly the 99% SOLDOUT_THRESHOLD_BPS trigger, `remaining` (8,000,000e18 TST) is
        // already below the 10,000,000e18 TST minimum seed the graduator requires (1% of the full 1B
        // TOTAL_SUPPLY) -- the sold-out path was mathematically guaranteed to be unseedable at its own
        // trigger point, and continued buying past EITHER eligibility path could strand an otherwise-fine
        // curve the same way.
        //
        // A first version of this fix recomputed `_graduate()`'s own tstToSeed formula after EVERY trade
        // and was a genuine bug, caught before shipping: tstToSeed is
        // (realStockCollected * remaining) / oldVirtualStock, which is naturally SMALL for a curve that
        // has only just started (small realStockCollected), so checking its current value against the
        // minimum unconditionally also rejected completely ordinary EARLY buying, long before the curve
        // was anywhere near its graduation target.
        //
        // Round 22 (2026-10-01, self-audit of this very guard) then found the opposite error in its
        // replacement: capping `remaining` ALONE is necessary but NOT sufficient. The graduator checks
        // the seed it actually receives, which is tstToSeed, and tstToSeed is always strictly LESS than
        // `remaining` -- so buying right down to `remaining == minSeed` left tstToSeed at 9,875,000e18
        // against the graduator's required 10,000,000e18, and graduate() reverted SeedTooSmall at a point
        // this guard had explicitly allowed. (That state was recoverable -- selling raises `remaining`,
        // which on this side of the curve raises tstToSeed with it -- but an earlier version of this
        // comment claimed the cure was MORE BUYING, which is wrong twice over: buying shrinks `remaining`
        // rather than leaving it alone, and at the boundary buying is blocked outright.)
        //
        // Both errors are avoided by checking the real seed formula but only on the LATE side of the
        // curve. tstToSeed as a function of `remaining` is a downward parabola peaking at
        // remaining = CURVE_SUPPLY/2, so it falls below minSeed in two places: near CURVE_SUPPLY (early,
        // where the cure genuinely is more buying) and near zero (late, where more buying is exactly the
        // danger). Restricting the seed check to remaining < CURVE_SUPPLY/2 catches the late case without
        // touching the early one, and makes the guarantee a clean one: any buy this guard permits leaves
        // a curve that can actually graduate.
        {
            uint256 projectedTokensSold = tokensSold + tstOut;
            uint256 projectedRemaining = CURVE_SUPPLY - projectedTokensSold;
            // Mirrors StocksGraduator.MIN_TST_SEED_SUPPLY_BPS (100, i.e. 1%) directly -- a contract's own
            // public constant isn't accessible via Type.CONSTANT syntax without an instance in this solc
            // version, so this stays a literal, kept in sync by a dedicated regression test
            // (test/AuditAgentVerify.soldoutSeedConflict.t.sol) that fails loudly if either side drifts.
            uint256 minSeed = (TOTAL_SUPPLY * 100) / BPS_DENOM;
            if (projectedRemaining < minSeed) revert SeedWouldBeUnreachable();

            if (projectedRemaining < CURVE_SUPPLY / 2) {
                uint256 projectedCollected = realStockCollected + actualStockIn;
                uint256 projectedSeed =
                    (projectedCollected * projectedRemaining) / (virtualStockReserve + projectedCollected);
                if (projectedSeed < minSeed) revert SeedWouldBeUnreachable();
            }
        }

        if (block.timestamp < launchTimestamp + SNIPE_WINDOW) {
            uint256 totalBought = snipeWindowBought[msg.sender] + tstOut;
            if (totalBought > (CURVE_SUPPLY * MAX_SNIPE_BUY_BPS) / BPS_DENOM) revert SnipeCapExceeded();
            snipeWindowBought[msg.sender] = totalBought;
        }

        realStockCollected += actualStockIn;
        tokensSold += tstOut;

        IERC20(address(tstToken)).safeTransfer(msg.sender, tstOut);

        emit Bought(msg.sender, actualStockIn, tstOut);
    }

    /// @notice Sells TST back to the curve for stock.
    /// @dev The TST returns to the curve's inventory; it is not burned. The slippage check is made against what
    /// the seller actually received.
    /// @param tstIn TST to sell. Must be approved to the curve.
    /// @param minStockOut Smallest acceptable amount of stock.
    /// @return stockOut Stock the caller actually received.
    function sell(uint256 tstIn, uint256 minStockOut) external nonReentrant returns (uint256 stockOut) {
        if (graduated) revert AlreadyGraduated();
        if (tstIn == 0) revert ZeroAmount();
        if (tstIn > tokensSold) revert InsufficientTstSupply();

        uint256 quotedStockOut = quoteSell(tstIn);
        if (quotedStockOut == 0) revert ZeroAmount();

        // The curve's own internal state always uses the NOMINAL quoted amount: the contract genuinely
        // sends exactly `quotedStockOut` out of its own balance below, so this correctly reflects what
        // left the curve regardless of what the stock token's own transfer logic later does to it.
        realStockCollected -= quotedStockOut;
        tokensSold -= tstIn;

        IERC20(address(tstToken)).safeTransferFrom(msg.sender, address(this), tstIn);

        // External audit finding (AuditAgent, 2026-09-30): minStockOut used to be checked against the
        // nominal quoted amount BEFORE the transfer, not what the seller actually receives. If the stock
        // token ever charged an outbound transfer fee (already confirmed, via the real 723-wrapper
        // sweep, that none of the currently-attestable real tokens do -- this closes a theoretical gap,
        // not a currently-reachable one), the seller could receive less than their own specified minimum
        // while the check still passed. Fixed to mirror buy()'s own existing actualStockIn pattern
        // exactly, on the output side instead of the input side: measure the real balance delta and
        // check THAT against minStockOut, after the transfer -- the returned `stockOut` now means what
        // the caller actually received, not merely what the curve nominally sent.
        uint256 balanceBefore = stockToken.balanceOf(msg.sender);
        stockToken.safeTransfer(msg.sender, quotedStockOut);
        stockOut = stockToken.balanceOf(msg.sender) - balanceBefore;
        if (stockOut < minStockOut) revert SlippageExceeded();

        emit Sold(msg.sender, tstIn, stockOut);
    }

    /// @notice Moves the token from the curve to its Uniswap v4 pool. Callable by anyone once the curve has
    /// collected its target (or has sold almost its whole supply).
    /// @dev Reverts, and can simply be retried later, if the price-matched seed is below the graduator's minimum.
    function graduate() external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        bool targetReached = realStockCollected >= graduationStockTarget;
        bool soldOut = tokensSold >= (CURVE_SUPPLY * SOLDOUT_THRESHOLD_BPS) / BPS_DENOM;
        if (!targetReached && !soldOut) revert NotReady();
        _graduate();
    }

    /// @notice Burns any TST the curve holds beyond what its own accounting expects.
    /// @dev Covers TST sent to the curve by mistake before graduation. Callable by anyone; cannot touch inventory.
    function skim() external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        uint256 tstExpected = TOTAL_SUPPLY - tokensSold;
        uint256 tstExcess = IERC20(address(tstToken)).balanceOf(address(this)) - tstExpected;
        if (tstExcess > 0) IERC20(address(tstToken)).safeTransfer(BURN_ADDRESS, tstExcess);
    }

    /// @dev Deploys the governor and staking contract, burns the TST that will not be seeded, hands the seed and
    /// all collected stock to the graduator, and records the resulting addresses. `graduated` is set before the
    /// first external call. The TST seed is `realStockCollected * remaining / (virtual + real)`, which makes the
    /// pool open at exactly the curve's marginal price; the stock seed is the curve's whole stock balance, so
    /// stock donated to the curve raises the opening price at the donor's expense.
    function _graduate() internal {
        // Audit round 13 (external review lead): tstToSeed used to floor priceMatchedSeed up to minSeed when
        // an extreme single buy left `remaining` (unsold TST) too small -- silently opening the pool at a
        // WORSE (lower) price than the curve's own marginal rate, since stockToSeed stayed at the real
        // realStockCollected while tstToSeed alone got inflated. Measured directly: a 50x overshoot buy (the
        // top of this codebase's own existing fuzz range) opened the pool at only ~53% of the curve's true
        // marginal price -- existing holders' TST silently repriced ~47% lower the instant that pool opened.
        // There is no way to fix the RATIO while keeping the floor: proportionally scaling stockToSeed up to
        // match a floored tstToSeed would need MORE real stock than was ever actually collected, which
        // doesn't exist. So this refuses the floor outright instead of distorting price -- the seed is always
        // exactly price-matched, and StocksGraduator's own pre-existing SeedTooSmall() check (already there
        // for this exact reason) is left to revert graduation for a specific overshoot that's too extreme to
        // seed a meaningful pool at the correct price. This isn't a permanent brick: sell() lets tokensSold
        // (and so `remaining`) recover, after which a later graduate() call succeeds normally, price-correct.
        address graduator = IGovernableFactoryV5(factory).v4Graduator();
        uint256 remaining = CURVE_SUPPLY - tokensSold;
        uint256 oldVirtualStock = virtualStockReserve + realStockCollected;
        uint256 tstToSeed = (realStockCollected * remaining) / oldVirtualStock;

        graduated = true;

        IGovernableFactoryV5 f = IGovernableFactoryV5(factory);

        address gov = StocksGovernorFactory(f.governorFactory()).deploy(
            string.concat(tstToken.name(), " Governor"),
            IVotes(address(tstToken)),
            f.votingDelay(),
            f.votingPeriod(),
            f.proposalThresholdBps(),
            QUORUM_NUMERATOR
        );

        address stakingAddr = StocksStakingFactory(f.stakingFactory()).deploy(
            address(tstToken), address(stockToken), rewardsDuration, gov, f.hook()
        );

        // Everything the curve holds, donations included.
        uint256 stockToSeed = stockToken.balanceOf(address(this));

        // Burn all TST not going into the pool: the unsold remainder and the reserved supply.
        uint256 tstExcess = IERC20(address(tstToken)).balanceOf(address(this)) - tstToSeed;
        if (tstExcess > 0) IERC20(address(tstToken)).safeTransfer(BURN_ADDRESS, tstExcess);

        IERC20(address(tstToken)).forceApprove(graduator, tstToSeed);
        stockToken.forceApprove(graduator, stockToSeed);

        address poolView = StocksGraduator(graduator).graduate(
            address(tstToken), address(stockToken), stakingAddr, f.protocol(), FEE_BPS, tstToSeed, stockToSeed
        );

        // Only this curve can set the staking contract's pool, and only once.
        StocksStaking(stakingAddr).setPool(StocksPoolView(poolView).poolKey());

        pair = poolView;
        staking = stakingAddr;
        governor = gov;

        emit Graduated(poolView, stakingAddr, gov, stockToSeed, tstToSeed);
    }
}
