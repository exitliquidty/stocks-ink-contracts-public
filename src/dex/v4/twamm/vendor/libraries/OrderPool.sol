// SPDX-License-Identifier: UNLICENSED
// Derived from akshatmittal/v4-twamm-hook, used with the author's permission. Do not redistribute.

pragma solidity ^0.8.15;

library OrderPool {

    struct State {
        uint256 sellRateCurrent;
        uint256 sellRateAccounted;
        mapping(uint256 => uint256) sellRateEndingAtInterval;

        uint256 earningsFactorCurrent;
        mapping(uint256 => uint256) earningsFactorAtInterval;
    }

    function advanceWithoutCommit(State storage self, uint256 earningsFactor, uint256 usedSellRate) internal {
        unchecked {
            self.earningsFactorCurrent += earningsFactor;
            self.sellRateAccounted = usedSellRate;
        }
    }

    function advanceToInterval(State storage self, uint256 expiration, uint256 earningsFactor) internal {
        unchecked {
            self.earningsFactorCurrent += earningsFactor;
            self.earningsFactorAtInterval[expiration] = self.earningsFactorCurrent;
            self.sellRateCurrent -= self.sellRateEndingAtInterval[expiration];
            self.sellRateAccounted = 0;
        }
    }
}
