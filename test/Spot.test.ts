import { expect } from "chai";
import { Contract } from "ethers";
import { ethers, upgrades } from "hardhat";
import { ERC20 } from "../typechain-types";
import { deploy } from "./utils/deploy";

describe("Spot", function () {
  let SpotContract: Contract;
  let AccessContract: Contract;
  let USDCContract: ERC20;

  this.beforeAll(async function () {
    const { USDC, Access, Spot } = await deploy();
    AccessContract = Access;
    SpotContract = Spot;
    USDCContract = USDC;
    const [owner] = await ethers.getSigners();
    await AccessContract.setExchange(owner.address);
  });

  it("Should deploy the contract", async function () {
    expect(SpotContract.address).is.not.null;
  });

  it("Should modify account", async function () {
    const token1 = await ethers.getContractFactory("TestERC20");
    const testToken1 = await token1.deploy("token1", 1000000);
    await testToken1.waitForDeployment();
    const account = ethers.Wallet.createRandom();
    const amount = 1000n;
    const accountDeltas = {
      token: USDCContract.target,
      account: account.address,
      amount: amount,
    };
    const tx = await SpotContract.modifyAccount([accountDeltas]);
    await tx.wait();
    const accountInfo = await SpotContract.getBalance(
      USDCContract.target,
      account.address,
    );
    expect(accountInfo).to.equal(amount);
  });

  it("Should add two modifications", async function () {
    const token1 = await ethers.getContractFactory("TestERC20");
    const testToken1 = await token1.deploy("token1", 1000000);
    await testToken1.waitForDeployment();
    const account = ethers.Wallet.createRandom();
    const amount1 = 1000n;

    const token2 = await ethers.getContractFactory("TestERC20");
    const testToken2 = await token2.deploy("token2", 1000000);
    await testToken2.waitForDeployment();
    const amount2 = 5500n;

    const accountDeltas = {
      token: testToken1.target,
      account: account.address,
      amount: amount1,
    };

    const anotherAccountDeltas = {
      token: testToken2.target,
      account: account.address,
      amount: amount2,
    };

    const tx = await SpotContract.modifyAccount([
      accountDeltas,
      anotherAccountDeltas,
    ]);
    await tx.wait();

    const account1 = await SpotContract.getBalance(
      testToken1.target,
      account.address,
    );
    const account2 = await SpotContract.getBalance(
      testToken2.target,
      account.address,
    );
    expect(account1).to.equal(amount1);
    expect(account2).to.equal(amount2);
  });

  it("Should substract modifications", async function () {
    const token1 = await ethers.getContractFactory("TestERC20");
    const testToken1 = await token1.deploy("token1", 1000000);
    await testToken1.waitForDeployment();
    const account = ethers.Wallet.createRandom();
    const amount1 = -1000n;
    const depositAmount = 10000n;

    const depositDeltas = {
      token: USDCContract.target,
      account: account.address,
      amount: depositAmount,
    };
    const deposit = await SpotContract.modifyAccount([depositDeltas]);
    await deposit.wait();

    const accountDeltas = {
      token: USDCContract.target,
      account: account.address,
      amount: amount1,
    };

    const tx = await SpotContract.modifyAccount([accountDeltas]);
    await tx.wait();

    const account1 = await SpotContract.getBalance(
      USDCContract.target,
      account.address,
    );
    expect(account1).to.equal(depositAmount + amount1);
  });

  it("Should failed to deploy with zero address", async function () {
    const Spot = await ethers.getContractFactory("Spot");
    await expect(
      upgrades.deployProxy(Spot, [ethers.ZeroAddress], {
        initializer: "initialize",
      }),
    ).to.be.revertedWith("IA");
  });
});
