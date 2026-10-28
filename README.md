# pleaimd (PLEA)

A fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum.

| Item | Value |
|------|-------|
| Solidity contract | `PleaToken` (`src/PleaToken.sol`) |
| Token name (`name()`) | `pleaimd` |
| Token symbol (`symbol()`) | `PLEA` |
| Decimals | 18 |
| Total supply | 1,000,000,000 PLEA = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Minted to | `msg.sender` of the constructor (the launch factory), once, in the constructor |
| Owner / admin | none |
| Compiler | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"`, `cbor_metadata = false` |

## Behaviour

The contract is a self-contained EIP-20 implementation with no library dependencies:

- `transfer`, `transferFrom`, `approve`, `allowance`, `balanceOf`, `totalSupply`, `name`, `symbol`, `decimals`.
- `increaseAllowance` / `decreaseAllowance` as the race-free way to adjust an allowance.
- `burn(uint256)`: a holder may destroy its **own** tokens, which lowers `totalSupply`. There is no `burnFrom` and no privileged burn.
- An allowance of `type(uint256).max` is unlimited and is not decreased by `transferFrom`.
- Transfers and approvals to the zero address revert. All failures revert with a typed error; nothing returns `false`.
- No fee, tax, reflection, cooldown, max-wallet or max-transaction rule: every transfer delivers exactly the amount sent, for every sender, including the factory, the Uniswap v4 PoolManager and the launch's MerkleDistributor.
- No mint function of any kind, no owner, no pause, no blacklist, no freeze, no upgrade path, no `receive`/`fallback` (ether sent to the contract is rejected), no `delegatecall`, `callcode` or `selfdestruct`.

The supply can only ever shrink (through holders burning their own tokens) and can never grow.

## Assumptions

- The whole supply belongs to whoever deploys the contract. In the launch that is `ProjectFactory.launchCustom`, which distributes it: 10% to the launch's MerkleDistributor for the swarm, `economics.poolBps` (70%) to seed the single-sided Uniswap v4 pool paired with IMD, and the rest (20%) to `economics.remainderTo` (`0xee2aaa315cf7ed169f93148d30d24af9318dbb66`). The token has no knowledge of and no special treatment for any of these addresses; it does not need any because transfers are untaxed.
- No address needs to be exempted from anything, so the constructor takes neither `$factory`, `$poolManager` nor `$launchNumber`.
- Being ownerless, the contract has nothing to configure after launch. There is no "After launch" setting.
- There is no value the brief leaves open: name, symbol, decimals and supply are all given, and the token has no fee, rate or price.

## Deployment parameters

These are the launch's, decided by IdentityMD's manifest step after the work is accepted (do not write `launch.json` in this repository):

| Manifest field | Value |
|----------------|-------|
| `token.contract` | `PleaToken` |
| `token.name` | `pleaimd` |
| `token.symbol` | `PLEA` |
| `token.decimals` | `18` |
| `token.constructorArgs` | `[]` |
| `token.totalSupply` | `1000000000000000000000000000` |
| `contracts` | `[]` (no application contracts) |
| Chain | Ethereum, chain id 1 |
| `pool.pairedCurrency` | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| `pool.fee` | `12500` |
| `pool.tickSpacing` | `60` |
| `pool.initialPrice` | `79228162514264337593543950336` (provenance only; the deployer derives the opening price) |
| `economics` | `{"poolBps":7000,"initialMarketCapWei":"2500000000000000000000","remainderTo":"0xee2aaa315cf7ed169f93148d30d24af9318dbb66"}` |

The contract's creation code is `type(PleaToken).creationCode` with nothing appended. The constructor makes no external calls and needs no contract to exist, so it deploys on an empty chain.

## Operational responsibilities

- **Requester**: holds and manages the 20% remainder sent to `economics.remainderTo`. Those tokens are ordinary balances; they can be transferred or burned by that address alone.
- **IdentityMD launch**: deploys the contract through the factory, forwards the swarm's share, seeds the pool at the derived price and forwards the remainder. No step of that is done in this repository.
- **Nobody**: there is no admin key to rotate, no pause to lift, no parameter to tune and no upgrade to apply. If a change to the token's behaviour were ever wanted, it would require a new contract and a migration; this one cannot be changed.
- **Holders**: are responsible for their own approvals. Granting an unlimited allowance to a contract trusts that contract with the whole balance. Prefer `increaseAllowance`/`decreaseAllowance`, or set an allowance to zero before changing it, to avoid the EIP-20 approve race.

## Security notes

Checked against the `eth-security` reference's checklist:

- No external calls, no ether handling, no reentrancy surface.
- Arithmetic is checked except where a prior comparison guarantees no overflow/underflow (`balanceOf[to] += amount` is bounded by `totalSupply`).
- `transferFrom` only moves tokens with the owner's allowance; the deployer has no special path.
- The runtime code contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` (asserted by a test that scans reachable opcodes).
- Tests passing is not an audit. The contract is small and standard, but an independent adversarial review before release remains the launch policy's responsibility.
- Slither and Mythril were not run here (not available on the build machine); `forge build`, `forge test` (with the verifier's fuzz seed) and `forge fmt --check` were.

## Layout

```
foundry.toml        compiler and test configuration (solc 0.8.26, bytecode_hash none)
remappings.txt      forge-std/ => lib/forge-std/src/
src/PleaToken.sol   the token
test/PleaToken.t.sol success, failure and fuzz tests
lib/forge-std/      forge-std v1.9.7, vendored as plain files (no submodule)
```

## Running the checks

```
forge build
forge test
forge fmt --check
```

The fuzz seed used by the verifier is pinned in `foundry.toml` under `[fuzz]`, so local runs explore the same inputs.
