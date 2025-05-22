// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

import {IUniversalSigValidator} from "../interfaces/external/IUniversalSigValidator.sol";
import {IBsxOracle} from "contracts/misc/interfaces/IBsxOracle.sol";

string constant NAME = "BSX Mainnet";
string constant VERSION = "1";
uint256 constant PRICE_SCALE = 1e18;
uint8 constant STANDARDIZED_TOKEN_DECIMAL = 18;
uint256 constant ZERO_NONCE = 0;
address constant ZERO_ADDRESS = address(0);
uint128 constant MAX_WITHDRAWAL_FEE = 1e18; // 1$
uint128 constant MAX_TAKER_SEQUENCER_FEE_IN_USD = 1e18; // 1$
uint16 constant MAX_REBATE_RATE = 10_000; // 100%
uint16 constant MAX_TRADING_FEE_RATE = 200; // 2%
uint16 constant MAX_LIQUIDATION_FEE_RATE = 1000; // 10%
uint16 constant MAX_SWAP_FEE_RATE = 100; // 1%
address constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
address constant WETH9 = 0x4200000000000000000000000000000000000006;
address constant BSX_TOKEN = 0xD47F3E45B23b7594F5d5e1CcFde63237c60BE49e;
address constant USDC_TOKEN = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
address constant SPARK_USDC_VAULT = 0x7BfA7C4f149E7415b73bdeDfe609237e29CBF34A;
IUniversalSigValidator constant UNIVERSAL_SIG_VALIDATOR =
    IUniversalSigValidator(0x3F72193B6687707bfaA5119a3910eb4e27108bE8);
IBsxOracle constant BSX_ORACLE = IBsxOracle(0x8243c1F9e796530efA17A429Ac4F9d213853cAB5);
