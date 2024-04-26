import { ethers } from "hardhat";
import { expect } from "chai";

describe("Math", function () {
  let MathContract: any;
  this.beforeAll(async function () {
    const MathTest = await ethers.getContractFactory("MathHelperTest");

    const mathTest = await MathTest.deploy();
    await mathTest.waitForDeployment();
    MathContract = mathTest;
  });

  it("Should deployed correctly", async function () {
    expect(MathContract).to.not.be.undefined;
  });

  it("Should add two numbers", async function () {
    const result = await MathContract.add(1, 2);
    expect(result).to.equal(3);
  });

  it("Should max two numbers", async function () {
    const result = await MathContract.max(-300, -500);
    expect(result).to.equal(-300);
  });

  it("Should min two numbers", async function () {
    const result = await MathContract.min(300, 500);
    expect(result).to.equal(300);
  });

  it("Should subtract two numbers", async function () {
    const result = await MathContract.sub(3, 2);
    expect(result).to.equal(1);
  });

  it("Should multiply two numbers", async function () {
    const result = await MathContract.mul(1, 2);
    expect(result).to.equal(2);
  });

  it("Should divide two numbers", async function () {
    const result = await MathContract.div(1, 2);
    expect(result).to.equal(0);
  });
});
