import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { TestERC20 } from "../typechain-types";
import { setup } from "./utils/setExchange";

describe("Deposit", function () {
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

  it("Should deploy the contract", async function () {
    expect(SpotContract.address).is.not.null;
  });

  it("Should deposit when token in whitelist", async function () {
    const MAX_UINT =
      115792089237316195423570985008687907853269984665640564039457584007913129639935n;
    const [user] = await ethers.getSigners();

    const token = await ethers.getContractFactory("TestERC20");
    const USDTContract = await token.deploy("USDT", 500000000n); // 500'000,000 USDT tokens
    await USDTContract.waitForDeployment();

    const userBalanceBefore = await (USDTContract as TestERC20).balanceOf(
      user.address,
    );
    expect(userBalanceBefore).to.be.equal(500000000n);

    // Adding USDT as a supported token
    await exchangeContract.addSupportedToken(USDTContract.target);

    //User deposits 0.0005 USDT tokens
    const amountUser = 500n;

    await USDTContract.connect(user).approve(exchangeContract.target, MAX_UINT);

    await (exchangeContract.connect(user) as Contract).deposit(
      USDTContract.target,
      amountUser,
    );

    const userBalanceAfter = await USDTContract.balanceOf(user.address);
    expect(userBalanceAfter).to.be.equal(500000000n - amountUser);
  });
});
