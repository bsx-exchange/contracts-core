// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

string constant NAME = "BSX Mainnet";
string constant VERSION = "1";
uint8 constant STANDARDIZED_TOKEN_DECIMAL = 18;
uint128 constant MAX_WITHDRAWAL_FEE = 1e18; // 1$
uint128 constant MAX_TAKER_SEQUENCER_FEE = 1e18; // 1$
uint16 constant MAX_REBATE_RATE = 10_000; // 100%
uint16 constant MAX_MATCH_FEE_RATE = 200; // 2%
uint16 constant MAX_LIQUIDATION_FEE_RATE = 1000; // 10%
uint16 constant MAX_SWAP_FEE_RATE = 100; // 1%
address constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
address constant WETH9 = 0x4200000000000000000000000000000000000006;
