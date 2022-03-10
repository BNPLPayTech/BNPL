async function main() {
  const BankingNodeV2 = await ethers.getContractFactory("BankingNodeV2") // the name of the next contract in the future will be BankingNodeV2
  let bankingnodeV2 = await upgrades.upgradeProxy("-", BankingNodeV2)
  console.log("the upgrade is done!", bankingnodeV2.address)
}

main()
  .then(() => process.exit(0))
  .catch(error => {
      console.error(error)
      process.exit(1)
  })
