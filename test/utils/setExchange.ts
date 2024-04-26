import { Contract } from "ethers";
import { ethers } from "hardhat";
import { TestERC20 } from "../../typechain-types";
import { deploy } from "./deploy";

export async function setup() {
  let exchangeContract: Contract;
  let SpotContract: Contract;
  let ClearingServiceContract: Contract;
  let OrderBookContract: Contract;
  let PerpContract: Contract;
  let AccessContract: Contract;
  let FeeContract: Contract;

  let USDCContract: TestERC20;
  const { USDC, Access, Spot, Perp, OrderBook, ClearingService, Exchange } =
    await deploy();

  AccessContract = Access;
  SpotContract = Spot;
  PerpContract = Perp;
  OrderBookContract = OrderBook;
  ClearingServiceContract = ClearingService;
  exchangeContract = Exchange;
  USDCContract = USDC;

  const setExchange = await AccessContract.setExchange(exchangeContract.target);
  await setExchange.wait();

  const setClearingService = await AccessContract.setClearingService(
    ClearingServiceContract.target,
  );
  await setClearingService.wait();

  const setOrderBook = await AccessContract.setOrderBook(
    OrderBookContract.target,
  );
  await setOrderBook.wait();

  const [senderA, signerA, senderB, signerB] = await ethers.getSigners();
  const txAddUSDC = await exchangeContract.addSupportedToken(
    USDCContract.target,
  );
  await txAddUSDC.wait();

  const amount = 200000;
  const wrapAmount = ethers.parseEther(amount.toString());

  await USDCContract.approve(exchangeContract.target, wrapAmount);
  const txDepositUSDC = await (
    exchangeContract.connect(senderA) as Contract
  ).deposit(USDCContract.target, wrapAmount);
  const receiptTxDepositUSDC = await txDepositUSDC.wait();
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
  await txB.wait();

  return {
    USDC: USDCContract,
    Access: AccessContract,
    ClearingService: ClearingServiceContract,
    Spot: SpotContract,
    Perp: PerpContract,
    OrderBook: OrderBookContract,
    Exchange: exchangeContract,
  };
}
