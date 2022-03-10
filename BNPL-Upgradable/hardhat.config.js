require("@nomiclabs/hardhat-waffle")
require("@nomiclabs/hardhat-ethers")
require('@openzeppelin/hardhat-upgrades')
require("@nomiclabs/hardhat-etherscan")

// This is a sample Hardhat task. To learn how to create your own go to
// https://hardhat.org/guides/create-task.html
task("accounts", "Prints the list of accounts", async () => {
  const accounts = await ethers.getSigners()

  for (const account of accounts) {
    console.log(account.address)
  }
})

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
//const MAINNET_RPC_URL = process.env.MAINNET_RPC_URL || process.env.ALCHEMY_MAINNET_RPC_URL || "https://eth-mainnet.alchemyapi.io/v2/your-api-key"
const RINKEBY_RPC_URL = process.env.RINKEBY_RPC_URL || "https://rinkeby.infura.io/v3/"
//const KOVAN_RPC_URL = process.env.KOVAN_RPC_URL || "https://eth-kovan.alchemyapi.io/v2/your-api-key"
//const MNEMONIC = process.env.MNEMONIC || "your mnemonic"
//const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY || "Your etherscan API key"
// optional
const PRIVATE_KEY = process.env.PRIVATE_KEY || ""
module.exports = {
  defaultNetwork: "rinkeby",
  networks: {
    hardhat: {
    },
    local: {
      url: 'http://127.0.0.1:8545/'
    },
    rinkeby: {
      url: RINKEBY_RPC_URL,
      // accounts: [PRIVATE_KEY],
      accounts: {
        mnemonic: "",
      },
      saveDeployments: true,
    },
  },
  solidity: "0.8.2",
}
