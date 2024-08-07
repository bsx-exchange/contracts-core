// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

string constant NAME = "BSX Testnet";
string constant VERSION = "1";
uint8 constant STANDARDIZED_TOKEN_DECIMAL = 18;
uint128 constant MAX_WITHDRAWAL_FEE = 1e18; // 1$
uint128 constant MAX_TAKER_SEQUENCER_FEE = 1e18; // 1$
int128 constant MAX_MATCH_FEES = 2 * 10 ** 16; // 2%
uint128 constant MIN_WITHDRAW_AMOUNT = 2e18; // 2$
uint16 constant MAX_REBATE_RATE = 10_000; // 100%
uint16 constant MAX_LIQUIDATION_FEE_RATE = 1000; // 10%
