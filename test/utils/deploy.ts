import { ethers, upgrades } from "hardhat";

export async function deploy() {
  const [senderA, _signerA, senderB, _signerB] = await ethers.getSigners();
  const USDC = await ethers.getContractFactory("TestERC20", senderA);
  const testUSDC = await USDC.deploy(
    "USDC",
    ethers.parseEther("50000000000000000000000000000"),
  );
  await testUSDC.waitForDeployment();
  await testUSDC.transfer(
    senderB.address,
    ethers.parseEther("500000000000000000"),
  );
  const [general] = await ethers.getSigners();
  const Access = await ethers.getContractFactory("Access");
  const access = await upgrades.deployProxy(Access, [general.address], {
    initializer: "initialize",
  });
  await access.waitForDeployment();

  //deploy clearing house contract
  const ClearingService = await ethers.getContractFactory("ClearingService");
  const clearingService = await upgrades.deployProxy(
    ClearingService,
    [access.target],
    { initializer: "initialize" },
  );
  await clearingService.waitForDeployment();

  //deploy spot engine
  const Spot = await ethers.getContractFactory("Spot");
  const spot = await upgrades.deployProxy(Spot, [access.target], {
    initializer: "initialize",
  });
  await spot.waitForDeployment();

  //deploy perpetual engine
  const Perp = await ethers.getContractFactory("Perp");
  const perp = await upgrades.deployProxy(Perp, [access.target], {
    initializer: "initialize",
  });
  await perp.waitForDeployment();

  //deploy orderbook
  const OrderBook = await ethers.getContractFactory("OrderBook");
  const orderBook = await upgrades.deployProxy(
    OrderBook,
    [
      clearingService.target,
      spot.target,
      perp.target,
      access.target,
      testUSDC.target,
    ],
    { initializer: "initialize" },
  );
  await orderBook.waitForDeployment();

  const Exchange = await ethers.getContractFactory("Exchange");
  const exchange = await upgrades.deployProxy(
    Exchange,
    [
      access.target,
      clearingService.target,
      spot.target,
      perp.target,
      orderBook.target,
    ],
    { initializer: "initialize" },
  );
  await exchange.waitForDeployment();

  return {
    USDC: testUSDC,
    Access: access,
    ClearingService: clearingService,
    Spot: spot,
    Perp: perp,
    OrderBook: orderBook,
    Exchange: exchange,
  };
}
