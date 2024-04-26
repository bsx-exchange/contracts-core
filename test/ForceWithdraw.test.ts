import { ethers } from "hardhat";

import { expect } from "chai";
import { Contract } from "ethers";
import { TestERC20 } from "../typechain-types";
import {
  TransactionType,
  WITHDRAWAL_SEQUENCER_FEE,
  createSigningKey,
  createSigningWallet,
  createWithdrawSignature,
  getWrapAmount,
} from "./utils/helper";
import { setup } from "./utils/setExchange";

describe("Force Withdraw", function () {
  let exchangeContract: Contract;
  let SpotContract: Contract;
  let ClearingServiceContract: Contract;
  let OrderBookContract: Contract;
  let PerpContract: Contract;
  let AccessContract: Contract;

  let USDCContract: TestERC20;

  this.beforeAll(async function () {
    const { USDC, Access, Spot, Perp, OrderBook, ClearingService, Exchange } =
      await setup();

    AccessContract = Access;
    SpotContract = Spot;
    PerpContract = Perp;
    OrderBookContract = OrderBook;
    ClearingServiceContract = ClearingService;
    exchangeContract = Exchange;
    USDCContract = USDC;
  });

  it("Should verify signature to add link signer", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    //add link signer for senderA
    const contractAddress = await exchangeContract.getAddress();
    const nonce = Date.now();
    const message =
      "Please sign in with your wallet to access bsx.exchange. You are signing in on 2023-11-15 06:45:16 (GMT). This message is exclusively signed with bsx.exchange for security.";
    const { domain, typedData, signingWallet } = createSigningWallet(
      contractAddress,
      signerA.address,
      message,
      nonce,
    );
    const walletSignature = await senderA.signTypedData(
      domain,
      typedData,
      signingWallet,
    );

    const {
      domain: domainSigningKey,
      typedData: typedDataSigingKey,
      signingKey,
    } = createSigningKey(contractAddress, senderA.address);
    const signerSignature = await signerA.signTypedData(
      domainSigningKey,
      typedDataSigingKey,
      signingKey,
    );

    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      [
        "tuple(address sender, address signer, string message, uint64 nonce, bytes walletSignature, bytes signerSignature)",
      ],
      [
        {
          sender: senderA.address,
          signer: signerA.address,
          message: message,
          nonce: nonce,
          walletSignature: walletSignature,
          signerSignature: signerSignature,
        },
      ],
    );

    const transactionIdCounter =
      await exchangeContract.executedTransactionCounter();
    const transactionIdHex = ethers.solidityPacked(
      ["uint32"],
      [transactionIdCounter],
    );
    const final_data =
      TransactionType.ADD_SIGNING_WALLET +
      transactionIdHex.slice(2) +
      data.slice(2);
    const result = await exchangeContract.processBatch([final_data]);
    const isLinked = await exchangeContract.isSigningWallet(senderA, signerA);
    expect(isLinked).to.be.equal(true);
    // add link signer for senderB

    const nonceB = Date.now();
    const {
      domain: domainB,
      typedData: typedDataB,
      signingWallet: signingWalletB,
    } = createSigningWallet(contractAddress, signerB.address, message, nonceB);
    const walletSignatureB = await senderB.signTypedData(
      domainB,
      typedDataB,
      signingWalletB,
    );

    const {
      domain: domainSigningKeyB,
      typedData: typedDataSigingKeyB,
      signingKey: signingKeyB,
    } = createSigningKey(contractAddress, senderB.address);
    const signerSignatureB = await signerB.signTypedData(
      domainSigningKeyB,
      typedDataSigingKeyB,
      signingKeyB,
    );

    const dataB = ethers.AbiCoder.defaultAbiCoder().encode(
      [
        "tuple(address sender, address signer, string message, uint64 nonce, bytes walletSignature, bytes signerSignature)",
      ],
      [
        {
          sender: senderB.address,
          signer: signerB.address,
          message: message,
          nonce: nonceB,
          walletSignature: walletSignatureB,
          signerSignature: signerSignatureB,
        },
      ],
    );

    const transactionIdCounterB =
      await exchangeContract.executedTransactionCounter();
    const transactionIdHexB = ethers.solidityPacked(
      ["uint32"],
      [transactionIdCounterB],
    );
    const final_dataB =
      TransactionType.ADD_SIGNING_WALLET +
      transactionIdHexB.slice(2) +
      dataB.slice(2);

    const resultB = await exchangeContract.processBatch([final_dataB]);
    const isLinkedB = await exchangeContract.isSigningWallet(senderB, signerB);

    expect(isLinkedB).to.be.equal(true);
  });

  it("Should prepare two phase withdraw failed", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const amount = 1000n;
    const wrapAmount = ethers.parseEther(amount.toString());
    const senderBNonce = Date.now();
    const contractAddress = await exchangeContract.getAddress();
    const { domain, typedData, withdrawSignature } = createWithdrawSignature(
      contractAddress,
      signerB.address,
      USDCContract.target as string,
      wrapAmount,
      senderBNonce,
    );
    const signature = await signerB.signTypedData(
      domain,
      typedData,
      withdrawSignature,
    );

    await expect(
      (exchangeContract.connect(senderB) as Contract).prepareForceWithdraw(
        USDCContract.target,
        wrapAmount,
        senderB,
        senderBNonce,
        signature,
        WITHDRAWAL_SEQUENCER_FEE,
      ),
    ).to.be.revertedWith("NE");
  });

  it("Should check force withdraw failed", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    await expect(
      (exchangeContract.connect(signerB) as Contract).checkForceWithdraw(
        1n,
        true,
      ),
    ).to.be.revertedWith("NAG");

    await expect(
      exchangeContract.checkForceWithdraw(1n, true),
    ).to.be.revertedWith("NE");
  });

  it("Should set two phase withdraw to enable", async function () {
    const [owner, someOne] = await ethers.getSigners();
    await exchangeContract.setTwoPhaseWithdraw(true);
    expect(await exchangeContract.isTwoPhaseWithdrawEnabled()).to.be.true;
    await expect(
      (exchangeContract.connect(someOne) as Contract).setTwoPhaseWithdraw(
        false,
      ),
    ).to.be.revertedWith("NAG");
  });
  it("Should set approve two phase withdraw", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const amount = 1000;
    const sequencerFee = 1;
    const receiverAmount = await getWrapAmount(
      USDCContract,
      (amount - sequencerFee).toString(),
    );
    const wrapAmount = ethers.parseEther(amount.toString());
    const senderBNonce = Date.now();
    const contractAddress = await exchangeContract.getAddress();
    const time = 3;
    const tx = await exchangeContract.updateForceWithdrawalTime(time);
    await tx.wait();

    const { domain, typedData, withdrawSignature } = createWithdrawSignature(
      contractAddress,
      senderB.address,
      USDCContract.target as string,
      wrapAmount,
      senderBNonce,
    );
    const signature = await senderB.signTypedData(
      domain,
      typedData,
      withdrawSignature,
    );

    const requestIdCounter =
      await exchangeContract.withdrawalRequestIDCounter();
    const requestId = await (
      exchangeContract.connect(senderB) as Contract
    ).prepareForceWithdraw(
      USDCContract.target,
      wrapAmount,
      senderB,
      senderBNonce,
      signature,
      WITHDRAWAL_SEQUENCER_FEE,
    );

    await new Promise((resolve) => setTimeout(resolve, 5000));
    const approve = await exchangeContract.checkForceWithdraw(
      requestIdCounter + 1n,
      true,
    );
    await approve.wait();

    const balanceBefore = await USDCContract.balanceOf(senderB.address);
    const commit = await (
      exchangeContract.connect(senderB) as Contract
    ).commitForceWithdraw(requestIdCounter + 1n);
    await commit.wait();
    const balanceAfter = await USDCContract.balanceOf(senderB.address);
    expect(balanceBefore + receiverAmount).to.equal(balanceAfter);
  });
  it("Should prepare two phase withdraw invalid amount", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const amount = 0n;
    const wrapAmount = ethers.parseEther(amount.toString());
    const senderBNonce = Date.now();
    const contractAddress = await exchangeContract.getAddress();
    const { domain, typedData, withdrawSignature } = createWithdrawSignature(
      contractAddress,
      senderB.address,
      USDCContract.target as string,
      wrapAmount,
      senderBNonce,
    );
    const signature = await senderB.signTypedData(
      domain,
      typedData,
      withdrawSignature,
    );

    await expect(
      (exchangeContract.connect(senderB) as Contract).prepareForceWithdraw(
        USDCContract.target,
        wrapAmount,
        senderB,
        senderBNonce,
        signature,
        WITHDRAWAL_SEQUENCER_FEE,
      ),
    ).to.be.revertedWith("IA");

    const amount2 = 999999999999999n;
    const wrapAmount2 = ethers.parseEther(amount2.toString());
    const senderBNonce2 = Date.now();
    const {
      domain: domain2,
      typedData: typedData2,
      withdrawSignature: withdrawSignature2,
    } = createWithdrawSignature(
      contractAddress,
      senderB.address,
      USDCContract.target as string,
      wrapAmount2,
      senderBNonce2,
    );
    const signature2 = await senderB.signTypedData(
      domain2,
      typedData2,
      withdrawSignature2,
    );

    await expect(
      (exchangeContract.connect(senderB) as Contract).prepareForceWithdraw(
        USDCContract.target,
        wrapAmount2,
        senderB,
        senderBNonce2,
        signature2,
        WITHDRAWAL_SEQUENCER_FEE,
      ),
    ).to.be.revertedWith("IB");
  });

  it("Should prepare two phase withdraw", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const amount = 1000;
    const sequencerFee = 1;
    const receiverAmount = await getWrapAmount(
      USDCContract,
      (amount - sequencerFee).toString(),
    );
    const wrapAmount = ethers.parseEther(amount.toString());
    const senderBNonce = Date.now();
    const contractAddress = await exchangeContract.getAddress();
    const { domain, typedData, withdrawSignature } = createWithdrawSignature(
      contractAddress,
      senderB.address,
      USDCContract.target as string,
      wrapAmount,
      senderBNonce,
    );
    const signature = await senderB.signTypedData(
      domain,
      typedData,
      withdrawSignature,
    );

    const requestIdCounter =
      await exchangeContract.withdrawalRequestIDCounter();
    const requestId = await (
      exchangeContract.connect(senderB) as Contract
    ).prepareForceWithdraw(
      USDCContract.target,
      wrapAmount,
      senderB,
      senderBNonce,
      signature,
      WITHDRAWAL_SEQUENCER_FEE,
    );
    const data = await exchangeContract.withdrawalInfo(requestIdCounter + 1n);
    expect(data[0]).to.equal(USDCContract.target);
    expect(data[1]).to.equal(senderB.address);
    expect(data[2]).to.equal(receiverAmount);
  });
});
