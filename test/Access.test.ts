import { ethers } from "hardhat";
import { expect } from "chai";
import { Contract } from "ethers";
import { TestERC20 } from "../typechain-types";
import { setup } from "./utils/setExchange";

describe("Access", function () {
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
    expect(AccessContract.address).is.not.null;
  });

  it("grantRoleForAccount function should revert when called", async function () {
    const [general, root, user] = await ethers.getSigners();
    let adminRole = await AccessContract.ADMIN_GENERAL_ROLE();

    let hasTradingRole = await AccessContract.hasRole(
      adminRole,
      general.address,
    );
    expect(hasTradingRole).to.be.true;

    await expect(
      (AccessContract.connect(root) as Contract).setExchange(
        "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82",
      ),
    ).to.be.revertedWithCustomError(AccessContract, "NotAdminGeneral");

    await (AccessContract.connect(general) as Contract).setExchange(
      "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82",
    );
    expect(await AccessContract.getExchange()).to.be.equal(
      "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82",
    );
  });
});
