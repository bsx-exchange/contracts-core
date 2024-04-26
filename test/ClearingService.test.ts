import { ethers, upgrades } from "hardhat";
import { expect } from "chai";
import { Contract } from "ethers";
import { ERC20 } from "../typechain-types";
import { deploy } from "./utils/deploy";

describe("ClearingService", function () {
  let ClearingServiceContract: Contract;
  let AccessContract: Contract;
  let USDCContract: ERC20;

  this.beforeAll(async function () {
    const { USDC, Access, ClearingService } = await deploy();
    AccessContract = Access;
    ClearingServiceContract = ClearingService;
    USDCContract = USDC;
  });

  it("Should failed to deploy with zero address", async function () {
    const ClearingService = await ethers.getContractFactory("ClearingService");
    await expect(
      upgrades.deployProxy(ClearingService, [ethers.ZeroAddress], {
        initializer: "initialize",
      }),
    ).to.be.revertedWith("IA");
  });
});
