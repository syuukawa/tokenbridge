# Token Bridge Contracts

## Install dependencies
Don't use Node 14 as it has issues with truffle, use node 8, 10 or 12.
Install node https://nodejs.org/es/
Then install dependencies
```
npm install
```

## Install and run ganache
https://www.trufflesuite.com/ganache


## Running test

```
npm run migrate
npm test
npm run lint
npm run coverage
```

## Configure networks

Edit the truffle configuration file

1. mnemonic.key
2. infura.key
3. truffle migrate --network kovan
   自动生成配置文件:federator/config/kovan.json

4. truffle migrate --network elatestnet
   provider: https://rpc.elaeth.io
   network_id: 3


```js
module.exports = {
  // See <http://truffleframework.com/docs/advanced/configuration>
  // to customize your Truffle configuration!met
  networks: {
    development: {
      host: "127.0.0.1",
      port: 8545,
      network_id: "*" // Match any network id
    },
    rskregtest: {
      host: "127.0.0.1",
      port: 4444,
      network_id: "*" // Match any network id
    },
  }
};
```

## ELA Error
1.  invalid opcode 0x1c
    https://testnet.elaeth.io/tx/0x1b1e258b2a80d7d6f3086457ccc4efcd2980f7961b126b459fdbb770be4420f0/internal_transactions




## Deploy contracts

Launch the local network

```
ganache-cli --verbose
```

Deploy using truffle to the desire network
```
truffle migrate --network <network>
```

Examples
```
truffle migrate --network development
truffle migrate --network rskregtest
truffle migrate --network kovan
truffle migrate --network kovan --reset
truffle migrate --network elatestnet --reset
```

This will also generate the json files for that network with the addresses of the deployed contracts that will be called by the federator.







