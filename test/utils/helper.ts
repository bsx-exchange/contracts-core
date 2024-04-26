import { ethers } from "hardhat";
import { TestERC20 } from "../../typechain-types/contracts/mocks/TestERC20";

export interface SigningWallet {
  key: string;
  message: string;
  nonce: number;
}

export interface SigningKey {
  account: string;
}

export interface WithdrawSignature {
  sender: string;
  token: string;
  amount: bigint;
  nonce: number;
}

export interface Order {
  sender: string;
  size: string;
  price: string;
  nonce: string;
  productIndex: number;
  orderSide: number;
}

export interface SignedOrder {
  order: Order;
  signature: string;
  signer: string;
  isLiquidation: boolean;
}

export interface MatchOrders {
  maker: SignedOrder;
  taker: SignedOrder;
  productAddress: string;
  quoteAddress: string;
}

export interface DepositInsuranceFund {
  token: string;
  amount: BigInt;
}

export interface UpdateFundingRate {
  productIndex: number;
  priceDiff: BigInt;
  timestamp: BigInt;
}

export interface TokenPricePair {
  productIndex: string;
  price: number;
}

export interface SettleAccount {
  quoteToken: string;
  account: string;
  pairs: TokenPricePair[];
}

export interface CoverLossByInsuranceFund {
  account: string;
  amount: BigInt;
  token: string;
}

export interface UpdateFeeRate {
  feeType: number;
  makerFeeRate: BigInt;
  takerFeeRate: BigInt;
}

export enum OrderSide {
  BUY,
  SELL,
}

export enum TransactionType {
  LIQUIDATE_ACCOUNT = "0x00",
  MATCH_ORDERS = "0x01",
  DEPOSIT_INSURANCE_FUND = "0x02",
  UPDATE_FUNDING_RATE = "0x03",
  ASSERT_OPEN_INTEREST = "0x04",
  COVER_LOST = "0x05",
  UPDATE_FEE_RATE = "0x06",
  LIQUIDATION_FEE_RATE = "0x07",
  CLAIM_FEE = "0x08",
  WITHDRAW_INSURANCE_FUND = "0x09",
  SET_MARKET_MAKER = "0x0a",
  UPDATE_SEQUENCER_FEE = "0x0b",
  ADD_SIGNING_WALLET = "0x0c",
  CLAIM_SEQUENCER_FEES = "0x0d",
  CLAIM_SEQUENCER_FEE = "0x0d",
  WITHDRAW = "0x0e",
  INVALID_TRANSACTION = "0x0f",
}

export const USDC_PRODUCT_ID = 0;

export function createOrder(
  contract: string,
  sender: string,
  size: string,
  price: string,
  nonce: string,
  productIndex: number,
  orderSide: number,
) {
  const order: Order = {
    sender,
    size,
    price,
    nonce,
    productIndex,
    orderSide,
  };
  const domain = {
    name: "BSX Mainnet",
    version: "1",
    chainId: 31337,
    verifyingContract: contract,
  };

  const typedData = {
    Order: [
      { name: "sender", type: "address" },
      { name: "size", type: "uint128" },
      { name: "price", type: "uint128" },
      { name: "nonce", type: "uint64" },
      { name: "productIndex", type: "uint8" },
      { name: "orderSide", type: "uint8" },
    ],
  };
  return {
    order,
    domain,
    typedData,
  };
}
export function createSigningKey(contract: string, account: string) {
  const signingKey: SigningKey = {
    account,
  };

  const domain = {
    name: "BSX Mainnet",
    version: "1",
    chainId: 31337,
    verifyingContract: contract,
  };

  const typedData = {
    SignKey: [{ name: "account", type: "address" }],
  };

  return {
    domain,
    typedData,
    signingKey,
  };
}

export function createSigningWallet(
  contract: string,
  signer: string,
  message: string,
  nonce: number,
) {
  const signingWallet: SigningWallet = {
    key: signer,
    message,
    nonce,
  };

  const domain = {
    name: "BSX Mainnet",
    // salt: ethers.zeroPadValue(ethers.toBeHex(31337), 32),
    version: "1",
    chainId: 31337,
    verifyingContract: contract,
  };

  const typedData = {
    Register: [
      { name: "key", type: "address" },
      { name: "message", type: "string" },
      { name: "nonce", type: "uint64" },
    ],
  };

  return {
    domain,
    typedData,
    signingWallet,
  };
}
export const getTimeAfterSecond = (second: number) => {
  return Math.floor(Date.now() / 1000) + second;
};

export function createWithdrawSignature(
  contract: string,
  sender: string,
  token: string,
  amount: bigint,
  nonce: number,
) {
  const withdrawSignature: WithdrawSignature = {
    sender,
    token,
    amount,
    nonce,
  };

  const domain = {
    name: "BSX Mainnet",
    // salt: ethers.zeroPadValue(ethers.toBeHex(31337), 32),
    version: "1",
    chainId: 31337,
    verifyingContract: contract,
  };

  const typedData = {
    Withdraw: [
      { name: "sender", type: "address" },
      { name: "token", type: "address" },
      { name: "amount", type: "uint128" },
      { name: "nonce", type: "uint64" },
    ],
  };

  return {
    domain,
    typedData,
    withdrawSignature,
  };
}
export function encodeOrder(
  order: Order,
  signer: string,
  signature: string,
  isLiquidation: boolean,
  matchFee: string,
) {
  const encodedOrder = ethers.solidityPacked(
    [
      "address",
      "int128",
      "int128",
      "uint64",
      "uint8",
      "uint8",
      "bytes",
      "address",
      "bool",
      "uint128",
    ],
    [
      order.sender,
      order.size,
      order.price,
      order.nonce,
      order.productIndex,
      order.orderSide,
      signature,
      signer,
      isLiquidation,
      matchFee,
    ],
  );
  return encodedOrder;
}
export async function getWrapAmount(contract: TestERC20, amount: string) {
  return ethers.parseUnits(amount, await contract.decimals());
}

export const randomBigNum = (byteLength: number = 5) => {
  const randomBytes = ethers.randomBytes(byteLength);
  const randomNumber = BigInt(
    `0x${Array.from(randomBytes, (byte) =>
      byte.toString(16).padStart(2, "0"),
    ).join("")}`,
  );
  return randomNumber.toString();
};

export const TAKER_SEQUENCER_FEE = BigInt(0.4 * 1e18);
export const MAKER_TRADING_FEE = BigInt(0.0002 * 1e18);
export const TAKER_TRADING_FEE = BigInt(0.0005 * 1e18);
export const WITHDRAWAL_SEQUENCER_FEE = BigInt(1e18);
