// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

string constant NAME = "BSX Mainnet";
string constant VERSION = "1";
uint8 constant STANDARDIZED_TOKEN_DECIMAL = 18;
uint128 constant MAX_WITHDRAWAL_FEE = 1e18; // 1$
uint128 constant MAX_TAKER_SEQUENCER_FEE = 1e18; // 1$
int128 constant MAX_MATCH_FEES = 2 * 10 ** 16; // 0.02%
address constant CLAIM_FEE_RECIPIENT = 0x31EFEB2915A647ac82cbb0908AE138327e625a47;
uint128 constant MIN_WITHDRAW_AMOUNT = 2e18; // 2$
