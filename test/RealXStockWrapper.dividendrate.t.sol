// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";

interface IXStockMultiplier {
    function multiplier() external view returns (uint256);
}

interface IWrapper4626 {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @notice Live-fork canary for the one assumption the whole dividend design rests on: the real
/// deployed xStocks wrapper's ERC-4626 exchange rate TRACKS the underlying xStock's live rebasing
/// multiplier. StocksStaking deliberately does nothing about dividends (no claim, no wrap/unwrap);
/// the treasury just holds wrapper shares and each share becomes redeemable for more raw stock as
/// the multiplier rises. xStocks' docs describe a legacy v1 wrapper that locks the multiplier at
/// first deposit (its rate would never rise) and a current one that reads it live. This proves the
/// wrappers this app actually pairs against (lib/stocks.ts's wrapperAddress, i.e. xStocks'
/// wrapperAddressV2) are the live-multiplier kind, for stocks that have really paid dividends.
contract RealXStockWrapperDividendRateTest is Test {
    struct Pair {
        string ticker;
        address raw;
        address wrapper;
    }

    Pair[4] pairs;

    function setUp() public {
        vm.createSelectFork("ink");
        // Real dividend payers, all with a multiplier above 1 on Ink today. Addresses are the
        // app's own (frontend/lib/stocks.ts).
        pairs[0] = Pair("AAPLx", 0x9d275685dC284C8eB1C79f6ABA7a63Dc75ec890a, 0x943BF64D566c32A2Bcd41AC92FB63C111cC9De8f);
        pairs[1] = Pair("MSFTx", 0x5621737f42dAE558b81269FcB9E9E70c19Aa6b35, 0x166Fbe68274b6a47e025F4ba17388c539f1fa1d0);
        pairs[2] = Pair("KOx", 0xdCC1a2699441079dA889B1F49e12B69cC791129b, 0xE4784B45415AAc58b289f9373314261c788C91e8);
        pairs[3] = Pair("PEPx", 0x36c424a6EC0e264b1616102Ad63eD2aD7857413e, 0x9622a9983F254f45a188BDAF3b3BbFB5343E5493);
    }

    /// @dev The wrapper's rate must equal the raw xStock's live multiplier, and that multiplier must
    /// actually be above 1 for a stock that has paid dividends (proving the rate has really risen
    /// since launch, not merely sits at its 1:1 starting value).
    function test_WrapperRate_EqualsLiveMultiplier_ForRealDividendPayers() public view {
        for (uint256 i; i < pairs.length; i++) {
            Pair memory p = pairs[i];
            assertEq(IWrapper4626(p.wrapper).asset(), p.raw, "wrapper must wrap the expected xStock");

            uint256 multiplier = IXStockMultiplier(p.raw).multiplier();
            uint256 rate = IWrapper4626(p.wrapper).convertToAssets(1e18);
            console.log(p.ticker, "multiplier:", multiplier);
            console.log(p.ticker, "wrapper rate:", rate);

            assertGt(multiplier, 1e18, "sanity: this stock has really paid dividends");
            assertEq(rate, multiplier, "wrapper rate must track the live multiplier, so dividends compound in share value");
        }
    }

    /// @dev The rate is LIVE, not a snapshot: the wrapper reads getCurrentMultiplier() off the raw
    /// xStock on every conversion (confirmed from the call trace), so when that multiplier rises
    /// (a dividend) the wrapper's rate follows on the very next read with no wrapper transaction.
    /// Simulated by mocking the raw token's getCurrentMultiplier() upward (keeping the rest of its
    /// return data untouched, so this holds whatever the tuple's exact shape is) and re-reading the
    /// real wrapper. This is exactly what distinguishes the current wrapper from the legacy v1 one,
    /// which locks the multiplier at first deposit.
    function test_WrapperRate_FollowsAMultiplierIncrease_WithNoWrapperInteraction() public {
        Pair memory p = pairs[0];
        bytes4 sel = bytes4(keccak256("getCurrentMultiplier()"));
        (bool ok, bytes memory ret) = p.raw.staticcall(abi.encodeWithSelector(sel));
        assertTrue(ok, "getCurrentMultiplier() must exist on the raw xStock");
        assertGe(ret.length, 32);

        uint256 multiplier = abi.decode(ret, (uint256));
        assertEq(multiplier, IXStockMultiplier(p.raw).multiplier(), "first return word is the multiplier");
        uint256 bumped = (multiplier * 105) / 100; // a 5% dividend-sized rebase

        // Swap only the first 32-byte word (the multiplier), keep every other returned word as-is.
        assembly {
            mstore(add(ret, 32), bumped)
        }
        vm.mockCall(p.raw, abi.encodeWithSelector(sel), ret);

        uint256 rateAfter = IWrapper4626(p.wrapper).convertToAssets(1e18);
        console.log("rate before:", multiplier);
        console.log("rate after a simulated 5% dividend:", rateAfter);

        assertEq(rateAfter, bumped, "wrapper rate must follow the raw multiplier live, with nothing to claim");
    }

    /// @dev totalAssets is derived from wrapped supply x live multiplier, so the whole vault's value
    /// (and therefore the treasury's slice of it) scales with the multiplier as well.
    function test_TotalAssets_IsSupplyTimesMultiplier() public view {
        Pair memory p = pairs[0]; // AAPLx has real wrapped supply on Ink
        uint256 supply = IWrapper4626(p.wrapper).totalSupply();
        assertGt(supply, 0, "sanity: real wrapped supply exists");
        uint256 expected = (supply * IXStockMultiplier(p.raw).multiplier()) / 1e18;
        // Real vault balances carry a few wei of rounding from past deposits and redeems.
        assertApproxEqAbs(IWrapper4626(p.wrapper).totalAssets(), expected, 1e6, "totalAssets == supply x multiplier");
    }
}
