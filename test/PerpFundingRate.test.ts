import { ethers, upgrades } from "hardhat";

import { expect } from "chai";
import { TestERC20 } from "../typechain-types";

import { Contract } from "ethers";
import { deploy } from "./utils/deploy";
import {
  CoverLossByInsuranceFund,
  MAKER_TRADING_FEE,
  OrderSide,
  TAKER_SEQUENCER_FEE,
  TAKER_TRADING_FEE,
  TransactionType,
  UpdateFundingRate,
  createOrder,
  createSigningKey,
  createSigningWallet,
  encodeOrder,
  randomBigNum,
} from "./utils/helper";

describe("Perp", function () {
  let exchangeContract: Contract;
  let SpotContract: Contract;
  let ClearingServiceContract: Contract;
  let OrderBookContract: Contract;
  let PerpContract: Contract;
  let AccessContract: Contract;

  let USDCContract: TestERC20;

  this.beforeAll(async function () {
    const { USDC, Access, Spot, Perp, OrderBook, ClearingService, Exchange } =
      await deploy();

    AccessContract = Access;
    SpotContract = Spot;
    PerpContract = Perp;
    OrderBookContract = OrderBook;
    ClearingServiceContract = ClearingService;
    exchangeContract = Exchange;
    USDCContract = USDC;

    const setExchange = await AccessContract.setExchange(
      exchangeContract.target,
    );
    await setExchange.wait();

    const setClearingService = await AccessContract.setClearingService(
      ClearingServiceContract.target,
    );
    await setClearingService.wait();

    const setOrderBook = await AccessContract.setOrderBook(
      OrderBookContract.target,
    );
    await setOrderBook.wait();
  });

  it("Should add quote USDC token", async function () {
    const tx = await exchangeContract.addSupportedToken(USDCContract.target);
    await tx.wait();
    const isSupported = await exchangeContract.isSupportedToken(
      USDCContract.target,
    );
    expect(isSupported).to.be.true;
  });

  it("Should deposit USDC to the Exchange", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();

    //deposit USDC to senderA
    const amount = 2000000;
    const wrapAmount = ethers.parseEther(amount.toString());
    await USDCContract.approve(exchangeContract.target, wrapAmount);
    const tx = await (exchangeContract.connect(senderA) as Contract).deposit(
      USDCContract.target,
      wrapAmount,
    );
    const receipt = await tx.wait();
    const balanceUSDC = await exchangeContract.balanceOf(
      senderA.address,
      USDCContract.target,
    );
    expect(balanceUSDC).to.be.equal(wrapAmount);

    //deposit USDC to senderB
    const amountB = 2000;
    const wrapAmountB = ethers.parseEther(amountB.toString());

    await USDCContract.connect(senderB).approve(
      exchangeContract.target,
      wrapAmountB,
    );
    const txB = await (exchangeContract.connect(senderB) as Contract).deposit(
      USDCContract.target,
      wrapAmountB,
    );
    const receiptB = await txB.wait();
    const balanceUSDCB = await exchangeContract.balanceOf(
      senderB.address,
      USDCContract.target,
    );
    expect(balanceUSDCB).to.be.equal(wrapAmountB);
  });

  it("Should verify signature to add link signer", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    //add link signer for senderA
    const contractAddress = await exchangeContract.getAddress();
    const message =
      "Please sign in with your wallet to access bsx.exchange. You are signing in on 2023-11-15 06:45:16 (GMT). This message is exclusively signed with bsx.exchange for security.";
    const nonce = Date.now();
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

  it("Should match the perp order", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const exchangeContractAddress = await exchangeContract.getAddress();
    const productIndex = 1;
    const makerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "1235678910000000000",
      "100000000000000000000",
      randomBigNum(),
      productIndex,
      OrderSide.SELL,
    );
    const takerOrder = createOrder(
      exchangeContractAddress,
      senderB.address,
      "7000000000000000",
      "100000000000000000000",
      randomBigNum(),
      productIndex,
      OrderSide.BUY,
    );

    const makerSignature = await signerA.signTypedData(
      makerOrder.domain,
      makerOrder.typedData,
      makerOrder.order,
    );

    const takerSignature = await signerB.signTypedData(
      takerOrder.domain,
      takerOrder.typedData,
      takerOrder.order,
    );
    const transactionIdCounter =
      await exchangeContract.executedTransactionCounter();
    const txInfo = ethers.solidityPacked(
      ["uint8", "uint32"],
      [TransactionType.MATCH_ORDERS, transactionIdCounter],
    );
    const matchFee = "0";
    const sequencerFee = "0";
    const makerOrderEncoded = encodeOrder(
      makerOrder.order,
      signerA.address,
      makerSignature,
      false,
      MAKER_TRADING_FEE.toString(),
    );
    const takerOrderEncoded = encodeOrder(
      takerOrder.order,
      signerB.address,
      takerSignature,
      false,
      TAKER_TRADING_FEE.toString(),
    );
    const sequencerFeeEncoded = ethers.solidityPacked(
      ["uint128"],
      [TAKER_SEQUENCER_FEE],
    );
    const finalData = ethers.solidityPacked(
      ["bytes", "bytes", "bytes", "bytes"],
      [txInfo, makerOrderEncoded, takerOrderEncoded, sequencerFeeEncoded],
    );
    const result = await exchangeContract.processBatch([finalData]);
    const receipt = await result.wait();
    // console.log(await PerpContract.getBalance(senderA.address, productIndex));
  });

  it("Should close position", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const exchangeContractAddress = await exchangeContract.getAddress();
    const productIndex = 1;
    const makerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "1235678910000000000",
      "100000000000000000000",
      randomBigNum(),
      productIndex,
      OrderSide.BUY,
    );
    const takerOrder = createOrder(
      exchangeContractAddress,
      senderB.address,
      "7000000000000000",
      "100000000000000000000",
      randomBigNum(),
      productIndex,
      OrderSide.SELL,
    );

    const makerSignature = await signerA.signTypedData(
      makerOrder.domain,
      makerOrder.typedData,
      makerOrder.order,
    );
    const takerSignature = await signerB.signTypedData(
      takerOrder.domain,
      takerOrder.typedData,
      takerOrder.order,
    );

    const transactionIdCounter =
      await exchangeContract.executedTransactionCounter();
    const txInfo = ethers.solidityPacked(
      ["uint8", "uint32"],
      [TransactionType.MATCH_ORDERS, transactionIdCounter],
    );
    const matchFee = "0";
    const sequencerFee = "0";
    const makerOrderEncoded = encodeOrder(
      makerOrder.order,
      signerA.address,
      makerSignature,
      false,
      MAKER_TRADING_FEE.toString(),
    );
    const takerOrderEncoded = encodeOrder(
      takerOrder.order,
      signerB.address,
      takerSignature,
      false,
      TAKER_TRADING_FEE.toString(),
    );
    const sequencerFeeEncoded = ethers.solidityPacked(
      ["uint128"],
      [TAKER_SEQUENCER_FEE],
    );
    const finalData = ethers.solidityPacked(
      ["bytes", "bytes", "bytes", "bytes"],
      [txInfo, makerOrderEncoded, takerOrderEncoded, sequencerFeeEncoded],
    );
    const tx = await exchangeContract.processBatch([finalData]);
    const balance = await PerpContract.getBalance(
      senderA.address,
      productIndex,
    );
    // console.log(balance);
    expect(balance[0]).to.be.equal(0);
  });

  it("Should deposit insurance fund", async () => {
    const amount = 100000;
    const wrapAmount = ethers.parseEther(amount.toString());
    const USDCAddress = await USDCContract.getAddress();
    await USDCContract.approve(exchangeContract.target, wrapAmount);
    const tx = await exchangeContract.depositInsuranceFund(
      USDCAddress,
      wrapAmount,
    );
    const insuranceBalance = await exchangeContract.getBalanceInsuranceFund();
    expect(insuranceBalance).to.be.equal(wrapAmount);
  });

  it("Should update funding rate", async function () {
    const productIndex = 1;
    const priceDiff = BigInt(5 * 1e18);
    const updateFundingRate: UpdateFundingRate = {
      productIndex: productIndex,
      priceDiff: priceDiff,
      timestamp: BigInt(1636950000000),
    };
    const updateFundingRateEncodedType =
      "tuple(uint8 productIndex, int256 priceDiff, uint256 timestamp) updateFundingRate";

    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      [updateFundingRateEncodedType],
      [updateFundingRate],
    );
    const transactionIdCounter =
      await exchangeContract.executedTransactionCounter();
    const transactionIdHex = ethers.solidityPacked(
      ["uint32"],
      [transactionIdCounter],
    );
    const final_data =
      TransactionType.UPDATE_FUNDING_RATE +
      transactionIdHex.slice(2) +
      data.slice(2);
    const fundingRateBefore = await PerpContract.getFundingRate(productIndex);
    const arrayFundingRateBefore = Array.from(fundingRateBefore)[0];
    const tx = await exchangeContract.processBatch([final_data]);
    const fundingRateAfter = await PerpContract.getFundingRate(productIndex);
    const arrayFundingRateAfter = Array.from(fundingRateAfter)[0];
    expect(arrayFundingRateAfter).to.be.equal(
      BigInt(arrayFundingRateBefore as number) + priceDiff,
    );
  });

  it("Should create match order for liquidation", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const exchangeContractAddress = await exchangeContract.getAddress();
    const productIndex = 1;
    const makerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "10000000000000000000",
      "1900000000000000000000",
      randomBigNum(),
      productIndex,
      OrderSide.SELL,
    );
    const takerOrder = createOrder(
      exchangeContractAddress,
      senderB.address,
      "15000000000000000000",
      "1000000000000000000000",
      randomBigNum(),
      productIndex,
      OrderSide.BUY,
    );

    const makerSignature = await signerA.signTypedData(
      makerOrder.domain,
      makerOrder.typedData,
      makerOrder.order,
    );
    const takerSignature = await signerB.signTypedData(
      takerOrder.domain,
      takerOrder.typedData,
      takerOrder.order,
    );
    const transactionIdCounter =
      await exchangeContract.executedTransactionCounter();
    const txInfo = ethers.solidityPacked(
      ["uint8", "uint32"],
      [TransactionType.MATCH_ORDERS, transactionIdCounter],
    );
    const matchFee = "0";
    const sequencerFee = "0";
    const makerOrderEncoded = encodeOrder(
      makerOrder.order,
      signerA.address,
      makerSignature,
      false,
      MAKER_TRADING_FEE.toString(),
    );
    const takerOrderEncoded = encodeOrder(
      takerOrder.order,
      signerB.address,
      takerSignature,
      false,
      TAKER_TRADING_FEE.toString(),
    );
    const sequencerFeeEncoded = ethers.solidityPacked(
      ["uint128"],
      [TAKER_TRADING_FEE],
    );
    const finalData = ethers.solidityPacked(
      ["bytes", "bytes", "bytes", "bytes"],
      [txInfo, makerOrderEncoded, takerOrderEncoded, sequencerFeeEncoded],
    );
    const tx = await exchangeContract.processBatch([finalData]);
  });

  it("Should match liquidation order", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const exchangeContractAddress = await exchangeContract.getAddress();
    const productIndex = 1;
    const makerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "10000000000000000000",
      "1000000000000000000000",
      randomBigNum(),
      productIndex,
      OrderSide.BUY,
    );
    const takerOrder = createOrder(
      exchangeContractAddress,
      senderB.address,
      "10000000000000000000",
      "1000000000000000000000",
      randomBigNum(),
      productIndex,
      OrderSide.SELL,
    );

    const makerSignature = await signerA.signTypedData(
      makerOrder.domain,
      makerOrder.typedData,
      makerOrder.order,
    );
    const transactionIdCounter =
      await exchangeContract.executedTransactionCounter();
    const txInfo = ethers.solidityPacked(
      ["uint8", "uint32"],
      [TransactionType.LIQUIDATE_ACCOUNT, transactionIdCounter],
    );
    //write 20 byte zero
    const zeroSigner = ethers.solidityPacked(["uint160"], [0]);

    //write 65 byte zero
    const zeroSignature = ethers.zeroPadValue(ethers.toBeHex(0), 65);
    const matchFee = "0";
    const sequencerFee = "0";
    const makerOrderEncoded = encodeOrder(
      makerOrder.order,
      signerA.address,
      makerSignature,
      false,
      MAKER_TRADING_FEE.toString(),
    );
    const takerOrderEncoded = encodeOrder(
      takerOrder.order,
      zeroSigner,
      zeroSignature,
      true,
      TAKER_TRADING_FEE.toString(),
    );
    const sequencerFeeEncoded = ethers.solidityPacked(
      ["uint128"],
      [TAKER_TRADING_FEE],
    );
    const finalData = ethers.solidityPacked(
      ["bytes", "bytes", "bytes", "bytes"],
      [txInfo, makerOrderEncoded, takerOrderEncoded, sequencerFeeEncoded],
    );

    const tx = await exchangeContract.processBatch([finalData]);
    const perpBalanceA = await PerpContract.getBalance(
      senderA.address,
      productIndex,
    );
    const perpBalanceB = await PerpContract.getBalance(
      senderB.address,
      productIndex,
    );
    expect(perpBalanceB[0]).to.be.equal(0);
  });

  it("Cover loss for user", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const amount = 5000;
    const wrapAmount = ethers.parseEther(amount.toString());
    const user: CoverLossByInsuranceFund = {
      account: senderB.address,
      amount: wrapAmount,
      token: USDCContract.target as string,
    };

    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      [`tuple(address account, address token, uint256 amount)`],
      [
        {
          account: user.account,
          amount: user.amount,
          token: user.token,
        },
      ],
    );
    const spotBalanceBefore = await exchangeContract.balanceOf(
      senderB.address,
      USDCContract.target,
    );
    const transactionIdCounter =
      await exchangeContract.executedTransactionCounter();
    const transactionIdHex = ethers.solidityPacked(
      ["uint32"],
      [transactionIdCounter],
    );
    const final_data =
      TransactionType.COVER_LOST + transactionIdHex.slice(2) + data.slice(2);
    const tx = await exchangeContract.processBatch([final_data]);
    const spotBalanceAfter = await exchangeContract.balanceOf(
      senderB.address,
      USDCContract.target,
    );
    expect(spotBalanceAfter).to.be.equal(
      spotBalanceBefore + BigInt(wrapAmount),
    );
  });

  it("Should assert open interest", async function () {
    const setOpenInterest = {
      pairs: [
        {
          productIndex: 1,
          openInterest: 10000,
        },
      ],
    };

    const openInterestEncodedType = `tuple(tuple(uint8 productIndex, int256 openInterest)[] pairs) setOpenInterest`;
    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      [openInterestEncodedType],
      [setOpenInterest],
    );
    const transactionIdCounter =
      await exchangeContract.executedTransactionCounter();
    const transactionIdHex = ethers.solidityPacked(
      ["uint32"],
      [transactionIdCounter],
    );
    const final_data =
      TransactionType.ASSERT_OPEN_INTEREST +
      transactionIdHex.slice(2) +
      data.slice(2);
    const tx = await exchangeContract.processBatch([final_data]);
  });
  it("Should revert due to assert negative open interest", async function () {
    const setOpenInterest = {
      pairs: [
        {
          productIndex: 1,
          openInterest: -10000n,
        },
      ],
    };

    const openInterestEncodedType = `tuple(tuple(uint8 productIndex, int256 openInterest)[] pairs) setOpenInterest`;
    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      [openInterestEncodedType],
      [setOpenInterest],
    );
    const transactionIdCounter =
      await exchangeContract.executedTransactionCounter();
    const transactionIdHex = ethers.solidityPacked(
      ["uint32"],
      [transactionIdCounter],
    );
    const final_data =
      TransactionType.ASSERT_OPEN_INTEREST +
      transactionIdHex.slice(2) +
      data.slice(2);
    await expect(
      exchangeContract.processBatch([final_data]),
    ).to.be.revertedWith("IOI");
  });

  it("Should revert due to invalid update funding rate call", async function () {
    await expect(PerpContract.updateFundingRate(1, 100)).to.be.revertedWith(
      "NS",
    );
  });

  it("Should claim fee", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const totalFee = await OrderBookContract.getTradingFees();
    const repicient = "0x31EFEB2915A647ac82cbb0908AE138327e625a47";
    const balance = await USDCContract.balanceOf(senderA.address);
    const tx = await exchangeContract.claimTradingFees();
    const balanceAfter = await USDCContract.balanceOf(repicient);
    expect(balanceAfter.toString()).to.be.equal(totalFee.toString());
  });

  it("Should call assert Open Interest failed", async () => {
    const data = [
      {
        productIndex: 1,
        openInterest: 10000,
      },
    ];
    await expect(PerpContract.assertOpenInterest(data)).to.be.revertedWith(
      "NS",
    );
  });
  it("Should failed to deploy with zero address", async function () {
    const Perp = await ethers.getContractFactory("Perp");
    await expect(
      upgrades.deployProxy(Perp, [ethers.ZeroAddress], {
        initializer: "initialize",
      }),
    ).to.be.revertedWith("IA");
  });
});
