# BSX Exchange contracts

[![CI](https://github.com/bsx-exchange/contracts-core/actions/workflows/ci.yml/badge.svg)](https://github.com/bsx-exchange/contracts-core/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/bsx-exchange/contracts-core/graph/badge.svg?token=ACNT7WX68X)](https://codecov.io/gh/bsx-exchange/contracts-core)
[![npm version](https://img.shields.io/npm/v/@bsx-exchange/client/latest.svg)](https://www.npmjs.com/package/@bsx-exchange/client/v/latest)

This repository contains the core smart contracts for BSX Exchange.

## Setup

Requirements:

- Node 18
- Bun ([Installation](https://bun.sh/docs/installation))
- Foundry ([Installation](https://getfoundry.sh))

```bash
$ git clone git@github.com:bsx-exchange/contracts-core.git
$ cd contracts-core
$ bun install
```

## Development

### Linting and Formatting

```bash
$ bun run lint
```

### Testing

Run all tests

```bash
$ bun run test
```

Check contract coverage

```bash
$ bun run test:coverage
```

## Deployments

| Contracts                                    | Base Mainnet                                 |
| -------------------------------------------- | -------------------------------------------- |
| [Exchange](./src/Exchange.sol)               | `0x26A54955a5fb9472D3eDFeAc9B8E4c0ab5779eD3` |
| [ClearingService](./src/ClearingService.sol) | `0x4a7f51E543b9DD6b259bcFD2FA2a3602eBd5679E` |
| [Orderbook](./src/OrderBook.sol)             | `0xE8A973AA7600c1Dba1e7936B95f67A14e6257137` |
| [SpotEngine](./src/Spot.sol)                 | `0x519086cd28A7A38C9701C0c914588DB4040FFCaE` |
| [PerpEngine](./src/Perp.sol)                 | `0xE2EB30975B8d063B38FDd77892F65138Bc802Bc7` |
| [Access](./src/access/Access.sol)            | `0x6c3Bb56d77E4225EEcE45Cde491f4A1a1649B034` |

## License

The primary license for BSX Exchange contracts is the MIT License, see [`LICENSE`](./LICENSE). However, there are
exceptions:

- Many files in `test/` remain unlicensed (as indicated in their SPDX headers).
