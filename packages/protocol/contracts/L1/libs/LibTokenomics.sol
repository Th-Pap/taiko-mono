// SPDX-License-Identifier: MIT
//  _____     _ _         _         _
// |_   _|_ _(_) |_____  | |   __ _| |__ ___
//   | |/ _` | | / / _ \ | |__/ _` | '_ (_-<
//   |_|\__,_|_|_\_\___/ |____\__,_|_.__/__/

pragma solidity ^0.8.18;

import {AddressResolver} from "../../common/AddressResolver.sol";
import {ChainData} from "../../common/IXchainSync.sol";
import {LibMath} from "../../libs/LibMath.sol";
import {
    SafeCastUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import {TaikoData} from "../TaikoData.sol";
import {TaikoToken} from "../TaikoToken.sol";

library LibTokenomics {
    using LibMath for uint256;
    uint256 private constant TWEI_TO_WEI = 1E12;

    error L1_INSUFFICIENT_TOKEN();

    function withdraw(
        TaikoData.State storage state,
        AddressResolver resolver,
        uint256 amount
    ) internal {
        uint256 balance = state.balances[msg.sender];
        if (balance <= amount) revert L1_INSUFFICIENT_TOKEN();

        uint256 x;
        {
            x = balance - amount;
        }
        if (x == 0) {
            x = 1;
        }

        state.balances[msg.sender] = x;

        unchecked {
            x = balance - x;
        }

        TaikoToken(resolver.resolve("taiko_token", false)).mint(msg.sender, x);
    }

    function deposit(
        TaikoData.State storage state,
        AddressResolver resolver,
        uint256 amount
    ) internal {
        if (amount > 0) {
            TaikoToken(resolver.resolve("taiko_token", false)).burn(
                msg.sender,
                amount
            );
            state.balances[msg.sender] += amount;
        }
    }

    function getBlockFee(
        TaikoData.State storage state,
        TaikoData.Config memory config
    )
        internal
        view
        returns (uint256 newFeeBase, uint256 fee, uint256 depositAmount)
    {
        if (state.nextBlockId <= config.constantFeeRewardBlocks) {
            fee = LibTokenomics.fromTwei(state.feeBaseTwei);
            newFeeBase = fee;
        } else {
            (newFeeBase, ) = LibTokenomics.getTimeAdjustedFee({
                config: config,
                feeBase: LibTokenomics.fromTwei(state.feeBaseTwei),
                isProposal: true,
                tNow: block.timestamp,
                tLast: state.lastProposedAt,
                tAvg: state.avgBlockTime,
                tTimeCap: config.blockTimeCap
            });
            fee = LibTokenomics.getSlotsAdjustedFee({
                state: state,
                config: config,
                isProposal: true,
                feeBase: newFeeBase
            });
        }
        fee = LibTokenomics.getBootstrapDiscountedFee(state, config, fee);
        unchecked {
            depositAmount = (fee * config.proposerDepositPctg) / 100;
        }
    }

    function getProofReward(
        TaikoData.State storage state,
        TaikoData.Config memory config,
        uint64 provenAt,
        uint64 proposedAt
    )
        internal
        view
        returns (uint256 newFeeBase, uint256 reward, uint256 tRelBp)
    {
        if (state.lastBlockId <= config.constantFeeRewardBlocks) {
            reward = LibTokenomics.fromTwei(state.feeBaseTwei);
            newFeeBase = reward;
            // tRelBp = 0;
        } else {
            (newFeeBase, tRelBp) = LibTokenomics.getTimeAdjustedFee({
                config: config,
                feeBase: LibTokenomics.fromTwei(state.feeBaseTwei),
                isProposal: false,
                tNow: provenAt,
                tLast: proposedAt,
                tAvg: state.avgProofTime,
                tTimeCap: config.proofTimeCap
            });
            reward = LibTokenomics.getSlotsAdjustedFee({
                state: state,
                config: config,
                isProposal: false,
                feeBase: newFeeBase
            });
        }
        unchecked {
            reward = (reward * (10000 - config.rewardBurnBips)) / 10000;
        }
    }

    // Implement "Slot-availability Multipliers", see the whitepaper.
    function getSlotsAdjustedFee(
        TaikoData.State storage state,
        TaikoData.Config memory config,
        bool isProposal,
        uint256 feeBase
    ) internal view returns (uint256) {
        uint256 m;
        uint256 n;
        uint256 k;
        // m is the `n'` in the whitepaper
        unchecked {
            m = 1000 * (config.maxNumBlocks - 1) + config.slotSmoothingFactor;
            // n is the number of unverified blocks
            n = 1000 * (state.nextBlockId - state.lastBlockId - 1);

            // k is `m − n + 1` or `m − n - 1`in the whitepaper
            k = isProposal ? m - n - 1000 : m - n + 1000;
        }
        return (feeBase * (m - 1000) * m) / (m - n) / k;
    }

    // Implement "Bootstrap Discount Multipliers", see the whitepaper.
    function getBootstrapDiscountedFee(
        TaikoData.State storage state,
        TaikoData.Config memory config,
        uint256 feeBase
    ) internal view returns (uint256 fee) {
        uint256 halves = uint256(block.timestamp - state.genesisTimestamp) /
            config.bootstrapDiscountHalvingPeriod;
        uint256 gamma;
        unchecked {
            gamma = 1024 - (1024 >> halves);
            fee = (feeBase * gamma) / 1024;
        }
    }

    // Implement "Incentive Multipliers", see the whitepaper.
    function getTimeAdjustedFee(
        TaikoData.Config memory config,
        uint256 feeBase,
        bool isProposal,
        uint256 tNow, // seconds
        uint256 tLast, // seconds
        uint256 tAvg, // milliseconds
        uint256 tTimeCap // milliseconds
    ) internal pure returns (uint256 newFeeBase, uint256 tRelBp) {
        if (tAvg == 0) {
            newFeeBase = feeBase;
            // tRelBp = 0;
        } else {
            unchecked {
                tNow *= 1000;
                tLast *= 1000;
                uint256 _tAvg = tAvg > tTimeCap ? tTimeCap : tAvg;
                uint256 tMax = (config.feeMaxPeriodPctg * _tAvg) / 100;
                uint256 a = tLast + (config.feeGracePeriodPctg * _tAvg) / 100;
                a = tNow > a ? tNow - a : 0;
                tRelBp = (a.min(tMax) * 10000) / tMax; // [0 - 10000]
                uint256 alpha = 10000 +
                    ((config.rewardMultiplierPctg - 100) * tRelBp) /
                    100;
                if (isProposal) {
                    newFeeBase = (feeBase * 10000) / alpha; // fee
                } else {
                    newFeeBase = (feeBase * alpha) / 10000; // reward
                }
            }
        }
    }

    function fromTwei(uint64 amount) internal pure returns (uint256) {
        if (amount == 0) {
            return TWEI_TO_WEI;
        } else {
            return amount * TWEI_TO_WEI;
        }
    }

    function toTwei(uint256 amount) internal pure returns (uint64) {
        uint256 _twei = amount / TWEI_TO_WEI;
        if (_twei > type(uint64).max) {
            return type(uint64).max;
        } else if (_twei == 0) {
            return uint64(1);
        } else {
            return uint64(_twei);
        }
    }
}
