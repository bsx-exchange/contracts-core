import { expect } from "chai";
import { Contract } from "ethers";
import { ethers, upgrades } from "hardhat";
import { TestERC20 } from "../typechain-types";
import { deploy } from "./utils/deploy";
import {
  CoverLossByInsuranceFund,
  DepositInsuranceFund,
  MAKER_TRADING_FEE,
  OrderSide,
  TAKER_SEQUENCER_FEE,
  TAKER_TRADING_FEE,
  TransactionType,
  UpdateFundingRate,
  createOrder,
  createSigningKey,
  createSigningWallet,
  createWithdrawSignature,
  encodeOrder,
  getWrapAmount,
  randomBigNum,
} from "./utils/helper";

describe("Exchange New Flow", function () {
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

  it("Should deploy the Exchange", async function () {
    expect(exchangeContract.target).to.be.properAddress;
  });

  it("Should deploy with zero address of access contract ", async function () {
    const Exchange = await ethers.getContractFactory("Exchange");
    await expect(
      upgrades.deployProxy(
        Exchange,
        [
          ethers.ZeroAddress,
          ClearingServiceContract.target,
          SpotContract.target,
          PerpContract.target,
          OrderBookContract.target,
        ],
        {
          initializer: "initialize",
        },
      ),
    ).to.be.revertedWith("IA");
  });

  it("Should deploy with zero address of clearing service contract", async function () {
    const Exchange = await ethers.getContractFactory("Exchange");
    await expect(
      upgrades.deployProxy(
        Exchange,
        [
          AccessContract.target,
          ethers.ZeroAddress,
          SpotContract.target,
          PerpContract.target,
          OrderBookContract.target,
        ],
        {
          initializer: "initialize",
        },
      ),
    ).to.be.revertedWith("IA");
  });

  it("Should deploy with zero address of Spot contract", async function () {
    const Exchange = await ethers.getContractFactory("Exchange");
    await expect(
      upgrades.deployProxy(
        Exchange,
        [
          AccessContract.target,
          ClearingServiceContract.target,
          ethers.ZeroAddress,
          PerpContract.target,
          OrderBookContract.target,
        ],
        {
          initializer: "initialize",
        },
      ),
    ).to.be.revertedWith("IA");
  });

  it("Should deploy with zero address of Perp contract", async function () {
    const Exchange = await ethers.getContractFactory("Exchange");
    await expect(
      upgrades.deployProxy(
        Exchange,
        [
          AccessContract.target,
          ClearingServiceContract.target,
          SpotContract.target,
          ethers.ZeroAddress,
          OrderBookContract.target,
        ],
        {
          initializer: "initialize",
        },
      ),
    ).to.be.revertedWith("IA");
  });

  it("Should deploy with zero address of Orderbook contract", async function () {
    const Exchange = await ethers.getContractFactory("Exchange");
    await expect(
      upgrades.deployProxy(
        Exchange,
        [
          AccessContract.target,
          ClearingServiceContract.target,
          SpotContract.target,
          PerpContract.target,
          ethers.ZeroAddress,
        ],
        {
          initializer: "initialize",
        },
      ),
    ).to.be.revertedWith("IA");
  });

  it("Should add quote USDC token", async function () {
    const tx = await exchangeContract.addSupportedToken(USDCContract.target);
    await tx.wait();
    const isSupported = await exchangeContract.isSupportedToken(
      USDCContract.target,
    );
    expect(isSupported).to.be.true;
  });

  it("Should remove supported token", async function () {
    const token = await ethers.getContractFactory("TestERC20");
    const testToken = await token.deploy("token", 1000000);
    await testToken.waitForDeployment();
    const tx = await exchangeContract.addSupportedToken(testToken.target);
    await tx.wait();

    const isSupported = await exchangeContract.isSupportedToken(
      testToken.target,
    );

    const tx2 = await exchangeContract.removeSupportedToken(testToken.target);
    await tx2.wait();

    const isSupported2 = await exchangeContract.isSupportedToken(
      testToken.target,
    );
    expect(isSupported).to.be.true;
    expect(isSupported2).to.be.false;
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

  it("Should failed due to invalid signing nonce", async function () {
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
    const nonceSecond = nonce; //used nonce
    const {
      domain: domainSecond,
      typedData: typedDataSecond,
      signingWallet: signingWalletSecond,
    } = createSigningWallet(
      contractAddress,
      signerA.address,
      message,
      nonceSecond,
    );
    const walletSignatureSecond = await senderB.signTypedData(
      domainSecond,
      typedDataSecond,
      signingWalletSecond,
    );

    const {
      domain: domainSigningKeySecond,
      typedData: typedDataSigingKeySecond,
      signingKey: signingKeySecond,
    } = createSigningKey(contractAddress, senderA.address);

    const signerSignatureSecond = await signerA.signTypedData(
      domainSigningKeySecond,
      typedDataSigingKeySecond,
      signingKeySecond,
    );

    const dataB = ethers.AbiCoder.defaultAbiCoder().encode(
      [
        "tuple(address sender, address signer, string message, uint64 nonce, bytes walletSignature, bytes signerSignature)",
      ],
      [
        {
          sender: senderA.address,
          signer: signerA.address,
          message: message,
          nonce: nonceSecond,
          walletSignature: walletSignatureSecond,
          signerSignature: signerSignatureSecond,
        },
      ],
    );

    const transactionIdCounterSecond =
      await exchangeContract.executedTransactionCounter();
    const transactionIdHexSecond = ethers.solidityPacked(
      ["uint32"],
      [transactionIdCounterSecond],
    );
    const final_data_second =
      TransactionType.ADD_SIGNING_WALLET +
      transactionIdHexSecond.slice(2) +
      dataB.slice(2);

    await expect(
      exchangeContract.processBatch([final_data_second]),
    ).to.be.revertedWith("ISN");
  });

  it("Should deposit USDC to the Exchange", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();

    //deposit USDC to senderA
    const amount = 1000;
    const wrapAmount = ethers.parseEther(amount.toString());
    await USDCContract.approve(exchangeContract.target, wrapAmount);
    const usdcBalanceBefore = await USDCContract.balanceOf(senderA.address);
    const tx = await (exchangeContract.connect(senderA) as Contract).deposit(
      USDCContract.target,
      wrapAmount,
    );
    const receipt = await tx.wait();
    const balance = await exchangeContract.balanceOf(
      senderA.address,
      USDCContract.target,
    );
    const usdcBalanceAfter = await USDCContract.balanceOf(senderA.address);
    expect(balance).to.be.equal(wrapAmount);
    expect(usdcBalanceAfter).to.be.equal(
      usdcBalanceBefore -
        ethers.parseUnits(amount.toString(), await USDCContract.decimals()),
    );

    const amountB = 200000;
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

  it("Should deposit token failed due to wrong parameters", async function () {
    const token = await ethers.getContractFactory("TestERC20");
    const testToken = await token.deploy("invalid token", 1000000);
    await testToken.waitForDeployment();

    const amount = 1000;
    await testToken.approve(exchangeContract.target, amount);

    await expect(
      exchangeContract.deposit(testToken.target, 1000),
    ).to.be.revertedWith("TNS");
  });

  it("Should add/remove supported token failed due to not admin", async function () {
    const [maker, taker, maker2, taker2, user] = await ethers.getSigners();
    const token = await ethers.getContractFactory("TestERC20");
    const testToken = await token.deploy("token", 1000000);
    await testToken.waitForDeployment();
    await expect(
      (exchangeContract.connect(taker2) as Contract).addSupportedToken(
        testToken.target,
      ),
    ).to.be.revertedWith("NAG");
    await expect(
      (exchangeContract.connect(taker2) as Contract).removeSupportedToken(
        USDCContract.target,
      ),
    ).to.be.revertedWith("NAG");
  });

  //test vulnerable
  it("Should deposit failed using clearing service contract", async function () {
    const [maker, taker, maker2, taker2, user] = await ethers.getSigners();
    const amount = 50000;
    await USDCContract.approve(exchangeContract.target, amount);
    await expect(
      ClearingServiceContract.deposit(
        user,
        amount,
        USDCContract.target,
        SpotContract.target,
      ),
    ).to.be.revertedWith("NS");
  });

  it("Should emergency withdraw ether by admin", async () => {
    const [maker, taker] = await ethers.getSigners();
    //transfer ether to exchange contract
    await taker.sendTransaction({
      to: exchangeContract.target,
      value: 100000,
    });

    const contractEtherBalance = await ethers.provider.getBalance(
      exchangeContract.target,
    );
    await expect(
      (exchangeContract.connect(taker) as Contract).emergencyWithdrawEther(
        1000,
      ),
    ).to.be.revertedWith("NAG");

    const result = await exchangeContract.emergencyWithdrawEther(5000);
    expect(
      await ethers.provider.getBalance(exchangeContract.target),
    ).to.be.equal(contractEtherBalance - 5000n);
  });

  it("Should emergency withdraw token by admin", async () => {
    const [maker, taker] = await ethers.getSigners();
    const tokenAddress = await USDCContract.getAddress();
    await USDCContract.mint(1000, taker.address);
    await USDCContract.connect(taker).transfer(exchangeContract.target, 100);
    const contractTokenBalance = await USDCContract.balanceOf(
      exchangeContract.target,
    );
    await expect(
      (exchangeContract.connect(taker) as Contract).emergencyWithdrawToken(
        tokenAddress,
        100,
      ),
    ).to.be.revertedWith("NAG");
    const result = await exchangeContract.emergencyWithdrawToken(
      tokenAddress,
      50,
    );
    expect(await USDCContract.balanceOf(exchangeContract.target)).to.be.equal(
      contractTokenBalance - 50n,
    );
  });

  it("Should withdraw USDC token from Exchange", async () => {
    const [sender, signer] = await ethers.getSigners();
    const amount = 123.4;
    const sequencerFeeAmount = 1e18;
    const wrapAmount = ethers.parseEther(amount.toString());
    const receiverAmount = amount - sequencerFeeAmount / 1e18;
    const contractAddress = await exchangeContract.getAddress();
    const tokenAddress = await USDCContract.getAddress();
    const usdcBalanceBefore = await USDCContract.balanceOf(sender.address);
    const userANonce = Date.now();
    const { domain, typedData, withdrawSignature } = createWithdrawSignature(
      contractAddress,
      sender.address,
      tokenAddress,
      wrapAmount,
      userANonce,
    );
    const signature = await sender.signTypedData(
      domain,
      typedData,
      withdrawSignature,
    );
    const sequencerFee = "1000000000000000000";
    const balanceBefore = await exchangeContract.balanceOf(
      sender.address,
      tokenAddress,
    );

    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      [
        `tuple(address sender, address token, uint128 amount, uint64 nonce, bytes signature, uint128 sequencerFee)`,
      ],
      [
        {
          sender: sender.address,
          token: tokenAddress,
          amount: wrapAmount,
          nonce: userANonce,
          signature: signature,
          sequencerFee: sequencerFee,
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
      TransactionType.WITHDRAW + transactionIdHex.slice(2) + data.slice(2);
    const tx = await exchangeContract.processBatch([final_data]);
    const usdcBalanceAfter = await USDCContract.balanceOf(sender.address);
    const balanceAfter = await exchangeContract.balanceOf(
      sender.address,
      tokenAddress,
    );
    expect(usdcBalanceAfter).to.be.equal(
      usdcBalanceBefore +
        (await getWrapAmount(USDCContract, receiverAmount.toString())),
    );
    expect(balanceAfter).to.be.equal(balanceBefore - wrapAmount);
  });

  it("Should withdraw failed due to invalid withdraw nonce", async () => {
    const [sender, signer] = await ethers.getSigners();
    const amount = 123.4;
    const sequencerFeeAmount = 1e18;
    const wrapAmount = ethers.parseEther(amount.toString());
    const receiverAmount = amount - sequencerFeeAmount / 1e18;
    const contractAddress = await exchangeContract.getAddress();
    const tokenAddress = await USDCContract.getAddress();
    const usdcBalanceBefore = await USDCContract.balanceOf(sender.address);
    const userANonce = Date.now();
    const { domain, typedData, withdrawSignature } = createWithdrawSignature(
      contractAddress,
      sender.address,
      tokenAddress,
      wrapAmount,
      userANonce,
    );
    const signature = await sender.signTypedData(
      domain,
      typedData,
      withdrawSignature,
    );
    const sequencerFee = "1000000000000000000";
    const balanceBefore = await exchangeContract.balanceOf(
      sender.address,
      tokenAddress,
    );

    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      [
        `tuple(address sender, address token, uint128 amount, uint64 nonce, bytes signature, uint128 sequencerFee)`,
      ],
      [
        {
          sender: sender.address,
          token: tokenAddress,
          amount: wrapAmount,
          nonce: userANonce,
          signature: signature,
          sequencerFee: sequencerFee,
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
      TransactionType.WITHDRAW + transactionIdHex.slice(2) + data.slice(2);
    const tx = await exchangeContract.processBatch([final_data]);

    const transactionIdHexSecond = ethers.solidityPacked(
      ["uint32"],
      [transactionIdCounter + 1n],
    );
    const final_data_second =
      TransactionType.WITHDRAW +
      transactionIdHexSecond.slice(2) +
      data.slice(2);
    await expect(
      exchangeContract.processBatch([final_data_second]),
    ).to.be.revertedWith("IWN");
  });

  it("Should make trade with taker", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const exchangeContractAddress = await exchangeContract.getAddress();
    const productIndex = 1;
    const makerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "1235678910000000000",
      "220000000000000000000",
      randomBigNum(),
      1,
      OrderSide.SELL,
    );
    const takerOrder = createOrder(
      exchangeContractAddress,
      senderB.address,
      "12356789100000000000",
      "2235140000000000000000",
      randomBigNum(),
      1,
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
    const makerFee = 0;
    const takerFee = 0;
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
    const takerSequencerFee = ethers.solidityPacked(
      ["uint128"],
      [TAKER_SEQUENCER_FEE],
    );
    const finalData = ethers.solidityPacked(
      ["bytes", "bytes", "bytes", "bytes"],
      [txInfo, makerOrderEncoded, takerOrderEncoded, takerSequencerFee],
    );
    await expect(
      (exchangeContract.connect(senderB) as Contract).processBatch([finalData]),
    ).to.be.revertedWith("NAG");
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

  it("Should make trade with maker", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const exchangeContractAddress = await exchangeContract.getAddress();
    const productIndex = 1;
    const makerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "1335678910000000000",
      "2235260000000000000000",
      randomBigNum(),
      productIndex,
      OrderSide.BUY,
    );
    const takerOrder = createOrder(
      exchangeContractAddress,
      senderB.address,
      "1435678910000000000",
      "2235140000000000000000",
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
    await expect(
      (exchangeContract.connect(senderB) as Contract).processBatch([finalData]),
    ).to.be.revertedWith("NAG");
  });

  it("Should deposit insurance fund", async () => {
    const [senderA] = await ethers.getSigners();
    const amount = 100000;
    const USDCAddress = await USDCContract.getAddress();
    await USDCContract.approve(exchangeContract.target, amount);
    const tx = await exchangeContract.depositInsuranceFund(USDCAddress, amount);
    const insuranceBalance = await exchangeContract.getBalanceInsuranceFund();
    expect(insuranceBalance).to.be.equal(amount);
  });

  it("Should withdraw insurance fund", async () => {
    const amount = 1000n;
    const insuranceBalanceBefore =
      await exchangeContract.getBalanceInsuranceFund();

    const tx = await exchangeContract.withdrawInsuranceFund(
      USDCContract.target,
      amount,
    );
    const insuranceBalance = await exchangeContract.getBalanceInsuranceFund();
    expect(insuranceBalance).to.be.equal(insuranceBalanceBefore - amount);
  });

  it("Should failed due to withdraw insurance fund with 0", async () => {
    await expect(
      exchangeContract.withdrawInsuranceFund(USDCContract.target, 0),
    ).to.be.revertedWith("IA");
  });

  it("Should failed due to withdraw insurance fund execced amount", async () => {
    await expect(
      exchangeContract.withdrawInsuranceFund(USDCContract.target, 99999999999n),
    ).to.be.revertedWith("IB");
  });

  it("Should revert when invalid operation type", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();

    const user: CoverLossByInsuranceFund = {
      account: senderA.address,
      amount: 1000n,
      token: USDCContract.target as string,
    };

    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      [`tuple(address account, uint256 amount, address token)`],
      [
        {
          account: user.account,
          amount: user.amount,
          token: user.token,
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
      TransactionType.INVALID_TRANSACTION +
      transactionIdHex.slice(2) +
      data.slice(2);

    await expect(
      exchangeContract.processBatch([final_data]),
    ).to.be.revertedWith("IOT");
  });

  it("Should revert due to invalid spot call", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const accountDeltas = {
      token: USDCContract.target,
      account: senderB.address,
      amount: 100n,
    };
    await expect(
      SpotContract.modifyAccount([accountDeltas]),
    ).to.be.revertedWith("NS");
  });

  it("Should revert due to invalid perp call", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const accountDeltas = {
      productIndex: 1,
      account: senderB.address,
      amount: 100n,
      quoteAmount: 0,
    };
    await expect(
      PerpContract.modifyAccount([accountDeltas]),
    ).to.be.revertedWith("NS");
  });

  it("Should revert due to invalid clearing service call", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    await expect(
      (
        ClearingServiceContract.connect(signerB) as Contract
      ).withdrawInsuranceFundEmergency(1000n),
    ).to.be.revertedWith("NS");
  });

  it("Should failed due to deposit insurance fund with 0", async () => {
    await expect(
      exchangeContract.depositInsuranceFund(USDCContract.target, 0),
    ).to.be.revertedWith("IA");
  });

  it("Should failed due to not deposit insurance fund from exchange", async () => {
    const amount = 10000;
    await expect(
      ClearingServiceContract.depositInsuranceFund(amount),
    ).to.be.revertedWith("NS");
  });

  it("Should failed due to not cover loss from exchange", async () => {
    const [senderA] = await ethers.getSigners();
    const amount = 10000n;
    await expect(
      ClearingServiceContract.insuranceCoverLost(
        senderA.address,
        amount,
        SpotContract.target,
        USDCContract.target,
      ),
    ).to.be.revertedWith("NS");
  });

  it("Should revert due to invalid clearing call", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const amount = 1000n;
    await expect(
      ClearingServiceContract.withdraw(
        signerA.address,
        amount,
        USDCContract.target,
        SpotContract.target,
      ),
    ).to.be.revertedWith("NS");
  });

  it("Should failed due to set total balance not from exchange", async () => {
    const amount = 1000n;
    await expect(
      SpotContract.setTotalBalance(USDCContract.target, amount, true),
    ).to.be.revertedWith("NS");
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

  it("Should claim fee failed", async () => {
    await expect(OrderBookContract.claimTradingFees()).to.be.revertedWith("NS");
  });

  it("Should update fee receiver", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const newFeeReceiver = senderB.address;
    const tx = await exchangeContract.updateFeeRecipientAddress(newFeeReceiver);
    const feeReceiver = await exchangeContract.feeRecipientAddress();
    await expect(
      (exchangeContract.connect(signerB) as Contract).updateFeeRecipientAddress(
        newFeeReceiver,
      ),
    ).to.be.revertedWith("NAG");
    expect(feeReceiver).to.be.equal(newFeeReceiver);
  });

  it("Should update force withdrawal time", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const time = 10 * 60;
    const tx = await exchangeContract.updateForceWithdrawalTime(time);
    const newTime = await exchangeContract.forceWithdrawalGracePeriodSecond();
    await expect(
      (exchangeContract.connect(signerB) as Contract).updateForceWithdrawalTime(
        time,
      ),
    ).to.be.revertedWith("NAG");
    expect(newTime).to.be.equal(time);
  });

  it("Should invalid transaction id", async () => {
    const amount = 100000;
    const USDCAddress = await USDCContract.getAddress();
    const depositInsuranceFund: DepositInsuranceFund = {
      token: USDCAddress,
      amount: BigInt(amount),
    };
    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      [`tuple(address token, uint256 amount)`],
      [
        {
          token: depositInsuranceFund.token,
          amount: depositInsuranceFund.amount,
        },
      ],
    );
    const transactionIdCounter =
      await exchangeContract.executedTransactionCounter();
    const transactionIdHex = ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint256"],
      [transactionIdCounter - 1n],
    );
    const final_data =
      TransactionType.DEPOSIT_INSURANCE_FUND +
      transactionIdHex.slice(2) +
      data.slice(2);

    await expect(
      exchangeContract.processBatch([final_data]),
    ).to.be.revertedWith("IT");
  });

  it("Withdraw failed due to invalid signature", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const amount = 100;
    const wrapAmount = ethers.parseEther(amount.toString());
    const tokenAddress = await USDCContract.getAddress();
    const contractAddress = await exchangeContract.getAddress();
    const userANonce = Date.now();
    const { domain, typedData, withdrawSignature } = createWithdrawSignature(
      contractAddress,
      senderA.address,
      tokenAddress,
      wrapAmount,
      userANonce,
    );
    //make signature invalid with sender B
    const signature = await senderB.signTypedData(
      domain,
      typedData,
      withdrawSignature,
    );
    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      [
        `tuple(address sender, address token, uint128 amount, uint64 nonce, bytes signature)`,
      ],
      [
        {
          sender: senderA.address,
          token: tokenAddress,
          amount: wrapAmount,
          nonce: userANonce,
          signature: signature,
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
      TransactionType.WITHDRAW + transactionIdHex.slice(2) + data.slice(2);
    await expect(
      exchangeContract.processBatch([final_data]),
    ).to.be.revertedWith("IS");
  });

  it("Should update fee receiver failed due to zero address", async () => {
    await expect(
      exchangeContract.updateFeeRecipientAddress(ethers.ZeroAddress),
    ).to.be.revertedWith("IA");
  });
  it("Should get trading fees", async () => {
    const totalFee = await OrderBookContract.getTradingFees();
    const fee = await exchangeContract.getTradingFees();
    expect(fee).to.be.equal(totalFee);
  });

  it("Should get sequencer fee", async () => {
    const sequencerFee = await exchangeContract.getSequencerFees();
    expect(sequencerFee).not.to.be.equal(0);
  });

  it("Should claim sequencer fees", async () => {
    const tx = await exchangeContract.claimSequencerFees();
    expect(await exchangeContract.getSequencerFees()).to.be.equal(0);
  });
  it("Should get supported token list", async () => {
    const tokenList = await exchangeContract.getSupportedTokenList();
    expect(tokenList.length).not.to.be.equal(0);
  });

  it("Should set pause process batch", async () => {
    const tx = await exchangeContract.setPauseBatchProcess(true);
    const isPaused = await exchangeContract.pauseBatchProcess();
    expect(isPaused).to.be.true;
  });

  it("Should set can deposit", async () => {
    const tx = await exchangeContract.setCanDeposit(false);
    const canDeposit = await exchangeContract.canDeposit();
    expect(canDeposit).to.be.false;
  });

  it("Should set unregister signer", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const tx = await exchangeContract.unregisterSigningWallet(
      senderA.address,
      signerA.address,
    );
    const isLinked = await exchangeContract.isSigningWallet(senderA, signerA);
    expect(isLinked).to.be.false;
  });

  it("Should set unregister signer failed due to not admin", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    await expect(
      (exchangeContract.connect(senderB) as Contract).unregisterSigningWallet(
        senderA.address,
        signerA.address,
      ),
    ).to.be.revertedWith("NAG");
  });

  it("Should failed to deposit token that not supported", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const token = await ethers.getContractFactory("TestERC20");
    const testToken = await token.deploy("token", 1000000);
    await testToken.waitForDeployment();
    const amount = 1000;
    await testToken.approve(exchangeContract.target, amount);
    await expect(
      exchangeContract.deposit(testToken.target, 1000),
    ).to.be.revertedWith("TNS");
  });

  it("Should deposit failed when disable deposit", async () => {
    //set disable deposit
    const disable = await exchangeContract.setCanDeposit(false);

    const amount = 1000;
    await USDCContract.approve(exchangeContract.target, amount);
    const tx = await exchangeContract.setCanDeposit(false);
    await expect(
      exchangeContract.deposit(USDCContract.target, 1000),
    ).to.be.revertedWith("NE");

    //enable deposit
    const tx2 = await exchangeContract.setCanDeposit(true);
  });

  it("Should deposit failed with amount 0", async () => {
    const amount = 0;
    await USDCContract.approve(exchangeContract.target, amount);
    await expect(
      exchangeContract.deposit(USDCContract.target, 0),
    ).to.be.revertedWith("IA");
  });

  it("Should revert due to pause process batch", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const amount = 1000;
    await USDCContract.approve(exchangeContract.target, amount);
    const pause = await exchangeContract.setPauseBatchProcess(true);

    expect(await exchangeContract.pauseBatchProcess()).to.be.true;

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
    await expect(
      exchangeContract.processBatch([final_data]),
    ).to.be.revertedWith("PBP");

    //enable pause process batch
    const tx2 = await exchangeContract.setPauseBatchProcess(false);
  });

  it("Should revert due to disable withdraw", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const amount = 100;
    const wrapAmount = ethers.parseEther(amount.toString());
    const tokenAddress = await USDCContract.getAddress();
    const contractAddress = await exchangeContract.getAddress();
    const userANonce = Date.now();
    const { domain, typedData, withdrawSignature } = createWithdrawSignature(
      contractAddress,
      senderA.address,
      tokenAddress,
      wrapAmount,
      userANonce,
    );
    const signature = await senderA.signTypedData(
      domain,
      typedData,
      withdrawSignature,
    );
    const sequencerFee = "1000000000000000000";
    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      [
        `tuple(address sender, address token, uint128 amount, uint64 nonce, bytes signature, uint128 sequencerFee)`,
      ],
      [
        {
          sender: senderA.address,
          token: tokenAddress,
          amount: wrapAmount,
          nonce: userANonce,
          signature: signature,
          sequencerFee: sequencerFee,
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
      TransactionType.WITHDRAW + transactionIdHex.slice(2) + data.slice(2);
    const disable = await exchangeContract.setCanWithdraw(false);
    await expect(
      exchangeContract.processBatch([final_data]),
    ).to.be.revertedWith("NE");

    //enable withdraw
    const tx2 = await exchangeContract.setCanWithdraw(true);
  });

  it("Should revert withdraw due to invalid sequencer fee", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const amount = 100;
    const wrapAmount = ethers.parseEther(amount.toString());
    const tokenAddress = await USDCContract.getAddress();
    const contractAddress = await exchangeContract.getAddress();
    const userANonce = Date.now();
    const { domain, typedData, withdrawSignature } = createWithdrawSignature(
      contractAddress,
      senderA.address,
      tokenAddress,
      wrapAmount,
      userANonce,
    );
    const signature = await senderA.signTypedData(
      domain,
      typedData,
      withdrawSignature,
    );
    const sequencerFee = "2000000000000000000";
    const data = ethers.AbiCoder.defaultAbiCoder().encode(
      [
        `tuple(address sender, address token, uint128 amount, uint64 nonce, bytes signature, uint128 sequencerFee)`,
      ],
      [
        {
          sender: senderA.address,
          token: tokenAddress,
          amount: wrapAmount,
          nonce: userANonce,
          signature: signature,
          sequencerFee: sequencerFee,
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
      TransactionType.WITHDRAW + transactionIdHex.slice(2) + data.slice(2);
    await expect(
      exchangeContract.processBatch([final_data]),
    ).to.be.revertedWith("ISF");
  });

  it("Should revert withdraw ether due to invalid amount", async () => {
    await expect(exchangeContract.emergencyWithdrawEther(0)).to.be.revertedWith(
      "IA",
    );
  });
  it("Should revert withdraw ether due to invalid amount", async () => {
    await expect(
      exchangeContract.emergencyWithdrawEther(100000000000),
    ).to.be.revertedWith("IB");
  });
  it("Should revert claim sequencer fees due to not admin", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    await expect(
      (exchangeContract.connect(senderB) as Contract).claimSequencerFees(),
    ).to.be.revertedWith("NAG");
  });
  it("Should revert claim trading fees due to not admin", async () => {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    await expect(
      (exchangeContract.connect(senderB) as Contract).claimTradingFees(),
    ).to.be.revertedWith("NAG");
  });
});
