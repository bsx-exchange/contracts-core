import { ethers, run, upgrades } from "hardhat";
import { EthersAdapter } from "@safe-global/protocol-kit";
import SafeApiKit from "@safe-global/api-kit";
import Safe from "@safe-global/protocol-kit";
import {
  MetaTransactionData,
  OperationType,
} from "@safe-global/safe-core-sdk-types";
import path from "path";
import fs from "fs";
import { pascalCaseToSnakeCase } from "./utils/helper";

const MULTI_SIG_ADDRESS = process.env.MULTI_SIG_ADDRESS!;
const provider = new ethers.JsonRpcProvider(process.env.RPC_URL!);
const signer = new ethers.Wallet(
  process.env.GNOSIS_SIGNER_PRIVATE_KEY!,
  provider,
);

async function checkAndUpgrade(
  contract: string,
  proxy: string,
  bytecode: string,
) {
  const abiCoder = new ethers.AbiCoder();
  const currentImpl = await upgrades.erc1967.getImplementationAddress(proxy);
  const currentImplCode = await provider.getCode(currentImpl);
  const currentImplCodeWithoutMetadata = currentImplCode.slice(0, -106);
  const bytecodeWithoutMetadata = bytecode.slice(0, -106);

  if (currentImplCodeWithoutMetadata !== bytecodeWithoutMetadata) {
    console.log(`${contract} contract needs to be upgraded`);
    console.log(`Upgrading ${contract} contract`);
    const Contract = await ethers.getContractFactory(contract, signer);
    const newImplAddr = await upgrades.prepareUpgrade(proxy, Contract);
    console.log(`Deployed ${contract} implementation: ${newImplAddr}`);
    await run("verify:verify", {
      address: newImplAddr,
    });

    const ethAdapter = new EthersAdapter({
      ethers,
      signerOrProvider: signer,
    });
    const { chainId } = await provider.getNetwork();
    const apiKit = new SafeApiKit({
      chainId,
    });
    const protocolKit = await Safe.create({
      ethAdapter,
      safeAddress: MULTI_SIG_ADDRESS,
    });
    const proxyAdmin = await upgrades.erc1967.getAdminAddress(proxy);
    const upgradeAndCallSelector = ethers
      .keccak256(ethers.toUtf8Bytes("upgradeAndCall(address,address,bytes)"))
      .slice(0, 10);
    const upgradeAndCallCalldata = abiCoder.encode(
      ["address", "address", "bytes"],
      [proxy, newImplAddr, "0x"],
    );

    const safeTransactionData: MetaTransactionData = {
      to: proxyAdmin,
      value: "0",
      data: upgradeAndCallSelector + upgradeAndCallCalldata.slice(2),
      operation: OperationType.Call,
    };
    const safeTransaction = await protocolKit.createTransaction({
      transactions: [safeTransactionData],
    });
    const senderAddress = await signer.getAddress();
    const safeTxHash = await protocolKit.getTransactionHash(safeTransaction);
    const signature = await protocolKit.signHash(safeTxHash);

    // Propose transaction to the service
    await apiKit.proposeTransaction({
      safeAddress: await protocolKit.getAddress(),
      safeTransactionData: safeTransaction.data,
      safeTxHash,
      senderAddress,
      senderSignature: signature.data,
    });
    console.log(`Proposed upgrade for ${contract} contract`);
  } else {
    console.log(`${contract} contract is up to date`);
  }
}

async function main() {
  const contracts = [
    "Exchange",
    "ClearingService",
    "OrderBook",
    "Perp",
    "Spot",
  ];
  for (const contract of contracts) {
    const envName = `${pascalCaseToSnakeCase(contract).toUpperCase()}_PROXY`;
    if (process.env[`DISABLE_UPGRADE_${envName}`] === "true") {
      console.log(`\nSkipped ${contract} contract upgrade`);
      continue;
    }

    const proxy = process.env[envName];
    if (!proxy) {
      throw new Error(`Please set ${envName} environment variable`);
    }

    const artifact = fs.readFileSync(
      path.resolve(
        __dirname,
        `../artifacts/contracts/exchange/${contract}.sol/${contract}.json`,
      ),
    );
    const { deployedBytecode } = JSON.parse(artifact.toString());
    console.log(`\nChecking ${contract} contract`);
    await checkAndUpgrade(contract, proxy, deployedBytecode);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
