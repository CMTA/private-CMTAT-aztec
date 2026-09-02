import { NO_FROM } from "@aztec/aztec.js/account";
import { AztecAddress } from "@aztec/aztec.js/addresses";
import { createEthereumChain } from "@aztec/ethereum/chain";
import { createExtendedL1Client } from "@aztec/ethereum/client";
import { L1FeeJuicePortalManager } from "@aztec/aztec.js/ethereum";
import type { L2AmountClaim } from "@aztec/aztec.js/ethereum";
import { FeeJuicePaymentMethodWithClaim } from "@aztec/aztec.js/fee";
import type { SponsoredFeePaymentMethod } from "@aztec/aztec.js/fee/testing";
import { Fr, GrumpkinScalar } from "@aztec/aztec.js/fields";
import { createLogger } from "@aztec/aztec.js/log";
import type { Logger } from "@aztec/aztec.js/log";
import { getFeeJuiceBalance } from "@aztec/aztec.js/utils";
import type { AztecNode } from "@aztec/aztec.js/node";
import type { AccountManager } from "@aztec/aztec.js/wallet";
import type { EmbeddedWallet } from "@aztec/wallets/embedded";
import { spawn } from 'child_process';

import { CMTATokenContract as TokenContract } from "../../artifacts/CMTAToken.js";
import { getSponsoredPaymentMethod } from "../../utils/sponsored_fpc.js";
import { setupWallet } from "../../utils/setup_pxe.js";

const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

describe("Accounts", () => {
    let node: AztecNode;
    let wallet: EmbeddedWallet;
    let logger: Logger;
    let sandboxInstance: ReturnType<typeof spawn> | undefined;
    let sponsoredPaymentMethod: SponsoredFeePaymentMethod;
    let owner: AztecAddress;

    let randomAccounts: AccountManager[] = [];
    let randomAddresses: AztecAddress[] = [];

    let l1PortalManager: L1FeeJuicePortalManager;
    let skipSandbox: boolean;

    const tokenName = 'TEST';
    const tokenSymbol = 'TT';
    const tokenDecimals = 18;

    beforeAll(async () => {
        skipSandbox = process.env.SKIP_SANDBOX === 'true';
        if (!skipSandbox) {
            sandboxInstance = spawn("aztec", ["start", "--sandbox"], {
                detached: true,
                stdio: 'ignore',
            });
            await sleep(15000);
        }

        logger = createLogger('aztec:cmtat:accounts');
        logger.info("private-CMTAT-aztec account tests running.");

        ({ node, wallet } = await setupWallet());
        sponsoredPaymentMethod = await getSponsoredPaymentMethod(wallet);

        // create default ethereum clients
        const nodeInfo = await node.getNodeInfo();
        const chain = createEthereumChain(['http://localhost:8545'], nodeInfo.l1ChainId);
        const DefaultMnemonic = 'test test test test test test test test test test test junk';
        const l1Client = createExtendedL1Client(chain.rpcUrls, DefaultMnemonic, chain.chainInfo);

        l1PortalManager = await L1FeeJuicePortalManager.new(node, l1Client, logger);

        const ownerAccount = await wallet.createSchnorrAccount(
            Fr.random(),
            Fr.random(),
            GrumpkinScalar.random(),
        );
        const ownerDeploy = await ownerAccount.getDeployMethod();
        await ownerDeploy.send({ from: NO_FROM, fee: { paymentMethod: sponsoredPaymentMethod } });
        owner = ownerAccount.address;
    }, 300_000);

    beforeEach(async () => {
        randomAccounts = await Promise.all(
            [0, 1].map(() =>
                wallet.createSchnorrAccount(Fr.random(), Fr.random(), GrumpkinScalar.random()),
            ),
        );
        randomAddresses = randomAccounts.map(a => a.address);
    });

    afterAll(async () => {
        if (!skipSandbox) {
            sandboxInstance?.kill('SIGINT');
        }
    });

    it("Creates accounts with fee juice", async () => {
        // balance of each random account is 0 before bridge
        let balances = await Promise.all(randomAddresses.map(a => getFeeJuiceBalance(a, node)));
        balances.forEach(b => expect(b).toBe(0n));

        // bridge funds to unfunded random addresses
        const claimAmount = 1000000000000000000n;
        const approxMaxDeployCost = 10n ** 10n; // Need to manually update this if fees increase significantly
        const claims: L2AmountClaim[] = [];
        // bridge sequentially to avoid l1 txs (nonces) being processed out of order
        for (const address of randomAddresses) {
            claims.push(await l1PortalManager.bridgeTokensPublic(address, claimAmount, true));
        }

        // arbitrary transactions to progress 2 blocks, and have fee juice on Aztec ready to claim
        for (let i = 0; i < 2; i++) {
            await TokenContract.deploy(wallet, owner, tokenName, tokenSymbol, tokenDecimals)
                .send({ from: owner, fee: { paymentMethod: sponsoredPaymentMethod } });
        }

        // claim and pay to deploy random accounts
        for (let i = 0; i < randomAccounts.length; i++) {
            const paymentMethod = new FeeJuicePaymentMethodWithClaim(randomAddresses[i], claims[i]);
            const deployMethod = await randomAccounts[i].getDeployMethod();
            await deployMethod.send({ from: NO_FROM, fee: { paymentMethod } });
        }

        // balance after deploy with claimed fee juice
        balances = await Promise.all(randomAddresses.map(a => getFeeJuiceBalance(a, node)));
        const amountAfterDeploy = claimAmount - approxMaxDeployCost;
        balances.forEach(b => expect(b).toBeGreaterThanOrEqual(amountAfterDeploy));
    }, 600_000);

    it("Deploys first unfunded account from first funded account", async () => {
        // The owner pays, so the new account needs no funds of its own.
        const deployMethod = await randomAccounts[0].getDeployMethod();
        const { receipt } = await deployMethod.send({
            from: owner,
            fee: { paymentMethod: sponsoredPaymentMethod },
        });

        expect(receipt.hasExecutionSucceeded()).toBe(true);

        const metadata = await wallet.getContractMetadata(randomAddresses[0]);
        expect(metadata.instance).toBeTruthy();
    }, 300_000);

    it("Sponsored contract deployment", async () => {
        const salt = Fr.random();

        const { contract, receipt } = await TokenContract.deploy(
            wallet,
            owner,
            tokenName,
            tokenSymbol,
            tokenDecimals,
            { salt, deployer: owner },
        ).send({
            from: owner,
            // without the sponsoredFPC the deployment fails, thus confirming it works
            fee: { paymentMethod: sponsoredPaymentMethod },
        });

        expect(receipt.hasExecutionSucceeded()).toBe(true);

        const metadata = await wallet.getContractMetadata(contract.address);
        expect(metadata.instance).toBeTruthy();
    }, 300_000);
});
