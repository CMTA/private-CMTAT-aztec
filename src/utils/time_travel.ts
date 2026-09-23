// Moving the chain's clock instead of waiting on it.
//
// Several values in the token are `DelayedPublicMutable`: a write becomes current only after
// `CHANGE_ROLES_DELAY_SECONDS`, which is one hour. Waiting that out in real time made the
// end-to-end suite take over an hour, so it stopped being run - and a suite that is not run
// stops reporting.
//
// A local network is backed by anvil, and the rollup exposes cheat codes that warp L1 time and
// mine; an L2 slot derives from the L1 timestamp, so advancing slots advances the timestamp a
// private function reads. Against a real network there are no cheat codes, so the wait is the
// only option: set E2E_REAL_CLOCK=true to force it.
import { EthCheatCodes, RollupCheatCodes } from '@aztec/ethereum/test';
import { SlotNumber } from '@aztec/foundation/branded-types';
import { DateProvider } from '@aztec/foundation/timer';
import type { AztecNode } from '@aztec/aztec.js/node';
import type { Logger } from '@aztec/aztec.js/log';

const { L1_URL = 'http://localhost:8545' } = process.env;

const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

/**
 * Advances the chain past `seconds`, by warping L1 when that is possible and by waiting when it
 * is not. Returns how it got there, so a test can log which path it took.
 */
export async function advancePastDelay(
    node: AztecNode,
    seconds: number,
    logger?: Logger,
): Promise<'warped' | 'waited'> {
    const margin = 12;

    if (process.env.E2E_REAL_CLOCK === 'true') {
        logger?.info(`E2E_REAL_CLOCK is set: waiting ${seconds}s for the delay to elapse`);
        await sleep((seconds + margin) * 1000);
        return 'waited';
    }

    try {
        const { l1ContractAddresses } = await node.getNodeInfo();
        // Built by hand rather than through RollupCheatCodes.create, because the factory keeps
        // the EthCheatCodes private and the date provider has to be synced afterwards.
        const eth = new EthCheatCodes([L1_URL], new DateProvider());
        const rollup = new RollupCheatCodes(eth, l1ContractAddresses);

        const { slotDuration } = await rollup.getConfig();
        const slots = Math.ceil((seconds + margin) / Number(slotDuration));

        // advanceToSlot rather than advanceSlots: the latter is relative to the L1 timestamp at
        // call time and races with real-time progression between the query and the warp.
        const current = await rollup.getSlot();
        const target = SlotNumber(Number(current) + slots);
        logger?.info(
            `Warping ${slots} slots of ${slotDuration}s (slot ${current} -> ${target}) ` +
                `to clear a ${seconds}s delay`,
        );
        await rollup.advanceToSlot(target);

        // The client computes a transaction's expiry from its own clock, so it has to follow the
        // chain it just warped; otherwise every later transaction looks already expired.
        await eth.syncDateProvider();
        return 'warped';
    } catch (error) {
        logger?.warn(
            `Cheat codes unavailable (${error instanceof Error ? error.message : String(error)}), ` +
                `falling back to waiting ${seconds}s`,
        );
        await sleep((seconds + margin) * 1000);
        return 'waited';
    }
}
