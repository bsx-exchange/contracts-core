import { HardhatUserConfig, task } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomiclabs/hardhat-solhint";
import "@openzeppelin/hardhat-upgrades";
import "hardhat-gas-reporter";
import "solidity-coverage";
import "hardhat-contract-sizer";
import dotenv from "dotenv";
dotenv.config();

const config: HardhatUserConfig = {
  gasReporter: {
    currency: "USD",
    gasPrice: 21,
    token: "ETH",
    enabled: process.env.REPORT_GAS == "true" ? true : false,
  },
  solidity: {
    compilers: [
      {
        version: "0.8.23",
        settings: {
          optimizer: {
            enabled: true,
            runs: 10,
          },
        },
      },
    ],
  },
  networks: {
    base_mainnet: {
      url: process.env.RPC_URL || "https://mainnet.base.org",
      chainId: 8453,
    },
  },
  etherscan: {
    apiKey: {
      base_mainnet: process.env.BASE_SCAN_API_KEY!,
    },
    customChains: [
      {
        network: "base_mainnet",
        chainId: 8453,
        urls: {
          apiURL: "https://api.basescan.org/api",
          browserURL: "https://basescan.org",
        },
      },
    ],
  },
};

export default config;
