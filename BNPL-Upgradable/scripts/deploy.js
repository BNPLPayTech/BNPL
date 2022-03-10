async function main() {
    const BankingNode = await ethers.getContractFactory("BankingNode")
    console.log("Deploying BankingNode, ProxyAdmin, and then Proxy...")
    const proxy = await upgrades.deployProxy(BankingNode, [], {initializer: 'initialize'})
    console.log("Proxy of BankingNode deployed to:", proxy.address)
}

main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error)
        process.exit(1)
    })