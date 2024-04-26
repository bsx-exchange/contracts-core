import { expect } from "chai";
import { Contract } from "ethers";
import { ethers, upgrades } from "hardhat";
import { TestERC20 } from "../typechain-types";
import {
  MAKER_TRADING_FEE,
  OrderSide,
  TAKER_SEQUENCER_FEE,
  TAKER_TRADING_FEE,
  TransactionType,
  createOrder,
  createSigningKey,
  createSigningWallet,
  encodeOrder,
  randomBigNum,
} from "./utils/helper";
import { setup } from "./utils/setExchange";

describe("Orderbook", function () {
  let exchangeContract: Contract;
  let SpotContract: Contract;
  let ClearingServiceContract: Contract;
  let OrderBookContract: Contract;
  let PerpContract: Contract;
  let AccessContract: Contract;
  let FeeContract: Contract;

  let USDCContract: TestERC20;
  // let WETHContract: TestERC20;

  this.beforeAll(async function () {
    const {
      USDC,
      // WETH,
      Access,
      Spot,
      Perp,
      OrderBook,
      ClearingService,
      Exchange,
    } = await setup();

    AccessContract = Access;
    SpotContract = Spot;
    PerpContract = Perp;
    OrderBookContract = OrderBook;
    ClearingServiceContract = ClearingService;
    exchangeContract = Exchange;
    USDCContract = USDC;
  });

  it("Should deploy the contract", async function () {
    expect(SpotContract.address).is.not.null;
  });
  it("Should deploy with zero address of clearing service ", async function () {
    const OrderBook = await ethers.getContractFactory("OrderBook");
    await expect(
      upgrades.deployProxy(
        OrderBook,
        [
          ethers.ZeroAddress,
          SpotContract.target,
          PerpContract.target,
          AccessContract.target,
          USDCContract.target,
        ],
        {
          initializer: "initialize",
        },
      ),
    ).to.be.revertedWith("IA");
  });
  it("Should deploy with zero address of Spot service ", async function () {
    const OrderBook = await ethers.getContractFactory("OrderBook");
    await expect(
      upgrades.deployProxy(
        OrderBook,
        [
          ClearingServiceContract.target,
          ethers.ZeroAddress,
          PerpContract.target,
          AccessContract.target,
          USDCContract.target,
        ],
        {
          initializer: "initialize",
        },
      ),
    ).to.be.revertedWith("IA");
  });
  it("Should deploy with zero address of Perp service ", async function () {
    const OrderBook = await ethers.getContractFactory("OrderBook");
    await expect(
      upgrades.deployProxy(
        OrderBook,
        [
          ClearingServiceContract.target,
          SpotContract.target,
          ethers.ZeroAddress,
          AccessContract.target,
          USDCContract.target,
        ],
        {
          initializer: "initialize",
        },
      ),
    ).to.be.revertedWith("IA");
  });
  it("Should deploy with zero address of Access service ", async function () {
    const OrderBook = await ethers.getContractFactory("OrderBook");
    await expect(
      upgrades.deployProxy(
        OrderBook,
        [
          ClearingServiceContract.target,
          SpotContract.target,
          PerpContract.target,
          ethers.ZeroAddress,
          USDCContract.target,
        ],
        {
          initializer: "initialize",
        },
      ),
    ).to.be.revertedWith("IA");
  });
  it("Should deploy with zero address of collateral ", async function () {
    const OrderBook = await ethers.getContractFactory("OrderBook");
    await expect(
      upgrades.deployProxy(
        OrderBook,
        [
          ClearingServiceContract.target,
          SpotContract.target,
          PerpContract.target,
          AccessContract.target,
          ethers.ZeroAddress,
        ],
        {
          initializer: "initialize",
        },
      ),
    ).to.be.revertedWith("IA");
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
          nonce: nonceB,
          message: message,
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

  it("Should call liquidation match orders success SELL ETH", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const exchangeContractAddress = await exchangeContract.getAddress();
    const productIndex = 1;
    const makerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "120000000000000000000",
      "500000000000000000000",
      randomBigNum(),
      productIndex,
      OrderSide.SELL,
    );
    const takerOrder = createOrder(
      exchangeContractAddress,
      senderB.address,
      "150000000000000000000",
      "100000000000000000000",
      randomBigNum(),
      productIndex,
      OrderSide.BUY,
    );
    const takerSignature = await signerB.signTypedData(
      takerOrder.domain,
      takerOrder.typedData,
      takerOrder.order,
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
      [TAKER_SEQUENCER_FEE],
    );
    const finalData = ethers.solidityPacked(
      ["bytes", "bytes", "bytes", "bytes"],
      [txInfo, makerOrderEncoded, takerOrderEncoded, sequencerFeeEncoded],
    );

    await exchangeContract.processBatch([finalData]);
  });

  it("Should call liquidation match orders success", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const exchangeContractAddress = await exchangeContract.getAddress();
    const productIndex = 1;
    const makerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "200000000000000000000",
      "500000000000000000000",
      randomBigNum(),
      productIndex,
      OrderSide.BUY,
    );
    const takerOrder = createOrder(
      exchangeContractAddress,
      senderB.address,
      "150000000000000000000",
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
      [TAKER_SEQUENCER_FEE],
    );
    const finalData = ethers.solidityPacked(
      ["bytes", "bytes", "bytes", "bytes"],
      [txInfo, makerOrderEncoded, takerOrderEncoded, sequencerFeeEncoded],
    );
    await exchangeContract.processBatch([finalData]);
  });

  it("Should return isMatched true", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const exchangeContractAddress = await exchangeContract.getAddress();
    const productIndex = 1;
    const nonceA = randomBigNum();
    const nonceB = randomBigNum();
    const makerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "200000000000000000000",
      "500000000000000000000",
      nonceA,
      productIndex,
      OrderSide.BUY,
    );
    const takerOrder = createOrder(
      exchangeContractAddress,
      senderB.address,
      "150000000000000000000",
      "100000000000000000000",
      nonceB,
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
    await exchangeContract.processBatch([finalData]);

    const isMatched = await OrderBookContract.isMatched(
      senderA.address,
      nonceA,
      senderB.address,
      nonceB,
    );
    expect(isMatched).to.be.equal(true);
  });

  it("Should failed due to nonce used", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const exchangeContractAddress = await exchangeContract.getAddress();
    const productIndex = 1;
    const nonceA = "12345";
    const nonceB = "123467";
    const makerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "200000000000000000000",
      "500000000000000000000",
      nonceA,
      productIndex,
      OrderSide.BUY,
    );
    const takerOrder = createOrder(
      exchangeContractAddress,
      senderB.address,
      "150000000000000000000",
      "100000000000000000000",
      nonceB,
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
    await exchangeContract.processBatch([finalData]);

    const anotherTxInfo = ethers.solidityPacked(
      ["uint8", "uint32"],
      [TransactionType.MATCH_ORDERS, transactionIdCounter + 1n],
    );
    const anotherFinalData = ethers.solidityPacked(
      ["bytes", "bytes", "bytes", "bytes"],
      [
        anotherTxInfo,
        makerOrderEncoded,
        takerOrderEncoded,
        sequencerFeeEncoded,
      ],
    );
    await expect(
      exchangeContract.processBatch([anotherFinalData]),
    ).to.be.revertedWith("NU");
  });

  it("Should failed due to not liquidation order", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const exchangeContractAddress = await exchangeContract.getAddress();
    const productIndex = 1;
    const nonceA = randomBigNum();
    const nonceB = randomBigNum();
    const makerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "200000000000000000000",
      "500000000000000000000",
      nonceA,
      productIndex,
      OrderSide.BUY,
    );
    const takerOrder = createOrder(
      exchangeContractAddress,
      senderB.address,
      "150000000000000000000",
      "100000000000000000000",
      nonceB,
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
      [TransactionType.LIQUIDATE_ACCOUNT, transactionIdCounter],
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
    await expect(exchangeContract.processBatch([finalData])).to.be.revertedWith(
      "NLO",
    );
  });

  it("Should failed due to invalid product id in match liquidation order", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const exchangeContractAddress = await exchangeContract.getAddress();
    const productIndex = 1;
    const makerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "200000000000000000000",
      "500000000000000000000",
      randomBigNum(),
      productIndex,
      OrderSide.BUY,
    );
    const takerOrder = createOrder(
      exchangeContractAddress,
      senderB.address,
      "150000000000000000000",
      "100000000000000000000",
      randomBigNum(),
      2, //wrong product index
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
      [TAKER_SEQUENCER_FEE],
    );
    const finalData = ethers.solidityPacked(
      ["bytes", "bytes", "bytes", "bytes"],
      [txInfo, makerOrderEncoded, takerOrderEncoded, sequencerFeeEncoded],
    );
    await expect(exchangeContract.processBatch([finalData])).to.be.revertedWith(
      "IP",
    );
  });

  it("Should failed due to invalid product id in match orders", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const exchangeContractAddress = await exchangeContract.getAddress();
    const productIndex = 1;
    const nonceA = randomBigNum();
    const nonceB = randomBigNum();
    const makerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "200000000000000000000",
      "500000000000000000000",
      nonceA,
      productIndex,
      OrderSide.BUY,
    );
    const takerOrder = createOrder(
      exchangeContractAddress,
      senderB.address,
      "150000000000000000000",
      "100000000000000000000",
      nonceB,
      2, //wrong product index
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
    await expect(exchangeContract.processBatch([finalData])).to.be.revertedWith(
      "IP",
    );
  });

  it("Should failed due to 2 liquidation orders", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const exchangeContractAddress = await exchangeContract.getAddress();
    const productIndex = 1;
    const makerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "200000000000000000000",
      "500000000000000000000",
      randomBigNum(),
      productIndex,
      OrderSide.BUY,
    );
    const takerOrder = createOrder(
      exchangeContractAddress,
      senderB.address,
      "150000000000000000000",
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

    const makerOrderEncoded = encodeOrder(
      makerOrder.order,
      signerA.address,
      makerSignature,
      true,
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
      [TAKER_SEQUENCER_FEE],
    );
    const finalData = ethers.solidityPacked(
      ["bytes", "bytes", "bytes", "bytes"],
      [txInfo, makerOrderEncoded, takerOrderEncoded, sequencerFeeEncoded],
    );
    await expect(exchangeContract.processBatch([finalData])).to.be.revertedWith(
      "ROLO",
    );
  });

  it("Should failed due to invalid match side", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const exchangeContractAddress = await exchangeContract.getAddress();
    const productIndex = 1;
    const makerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "120000000000000000000",
      "500000000000000000000",
      randomBigNum(),
      productIndex,
      OrderSide.SELL,
    );
    const takerOrder = createOrder(
      exchangeContractAddress,
      senderB.address,
      "150000000000000000000",
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
      [TAKER_SEQUENCER_FEE],
    );
    const finalData = ethers.solidityPacked(
      ["bytes", "bytes", "bytes", "bytes"],
      [txInfo, makerOrderEncoded, takerOrderEncoded, sequencerFeeEncoded],
    );

    await expect(exchangeContract.processBatch([finalData])).to.be.revertedWith(
      "IMS",
    );
  });

  it("Should failed due to duplicate address", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const exchangeContractAddress = await exchangeContract.getAddress();
    const productIndex = 1;
    const makerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "120000000000000000000",
      "500000000000000000000",
      randomBigNum(),
      productIndex,
      OrderSide.BUY,
    );
    const takerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "150000000000000000000",
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
      [TAKER_SEQUENCER_FEE],
    );
    const finalData = ethers.solidityPacked(
      ["bytes", "bytes", "bytes", "bytes"],
      [txInfo, makerOrderEncoded, takerOrderEncoded, sequencerFeeEncoded],
    );

    await expect(exchangeContract.processBatch([finalData])).to.be.revertedWith(
      "DA",
    );
  });

  it("Should failed due to duplicate address", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const exchangeContractAddress = await exchangeContract.getAddress();
    const productIndex = 1;
    const makerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "120000000000000000000",
      "500000000000000000000",
      randomBigNum(),
      productIndex,
      OrderSide.BUY,
    );
    const takerOrder = createOrder(
      exchangeContractAddress,
      senderB.address,
      "150000000000000000000",
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
      [BigInt(5e18).toString()],
    );
    const finalData = ethers.solidityPacked(
      ["bytes", "bytes", "bytes", "bytes"],
      [txInfo, makerOrderEncoded, takerOrderEncoded, sequencerFeeEncoded],
    );

    await expect(exchangeContract.processBatch([finalData])).to.be.revertedWith(
      "ISF",
    );
  });
  it("Should failed due to duplicate address", async function () {
    const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
    const exchangeContractAddress = await exchangeContract.getAddress();
    const productIndex = 1;
    const makerOrder = createOrder(
      exchangeContractAddress,
      senderA.address,
      "120000000000000000000",
      "500000000000000000000",
      randomBigNum(),
      productIndex,
      OrderSide.BUY,
    );
    const takerOrder = createOrder(
      exchangeContractAddress,
      senderB.address,
      "150000000000000000000",
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
      BigInt(5000e18).toString(),
    );
    const sequencerFeeEncoded = ethers.solidityPacked(
      ["uint128"],
      [TAKER_SEQUENCER_FEE],
    );
    const finalData = ethers.solidityPacked(
      ["bytes", "bytes", "bytes", "bytes"],
      [txInfo, makerOrderEncoded, takerOrderEncoded, sequencerFeeEncoded],
    );

    await expect(exchangeContract.processBatch([finalData])).to.be.revertedWith(
      "IF",
    );
  });
});
