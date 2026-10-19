<img src="brand/hushfund-logo.svg" alt="Hushfund" width="64" />

# hushfund-contracts

**Hushfund — Your money, hushed.**

Ethereum Mainnet USDC vault contracts, Noir circuits, verifiers and protocol tests.

## Contents

- `contracts/src/`: vault, Merkle tree, interfaces, yield adapters and verifiers.
- `circuits/` and `circuits_borrow/`: Noir sources and public compiled artifacts.
- `contracts/test/`: local unit/property tests and opt-in real-proof tests.
- `contracts/script/Deploy.s.sol`: manual deployment tooling; never called by CI.
- `config/` and `deployments/`: public Mainnet configuration and addresses.
- `contracts/lib/`: required vendored upstream source with license notices.

## Local tests

Install Foundry from https://getfoundry.sh using its official instructions.
No RPC, key, Mainnet transaction or funded wallet is required for default tests.

```sh
cd contracts
forge build
forge test
```

For optional real-proof tests, install Node.js 22.18+ and run from repo root:

```sh
npm ci
npm run test:proofs
```

The proof helper preserves the existing dependency lockfile. Default CI checks
Solidity tests only and does not claim to run real-proof tests.

The artifacts use Noir `1.0.0-beta.18`, Noir JS `1.0.0-beta.18`,
Barretenberg JS `3.0.0-nightly.20260102`, and Poseidon Noir `v0.1.1`.
The exact compiler/prover combination and public inputs must match the supplied
verifiers. Do not regenerate or replace verifiers independently of circuit review.

## Public Mainnet deployment

See `deployments/mainnet.json`. Explorer links and denomination-to-vault mapping
are in `DEPLOYMENTS.md`. These are public addresses, not signing authority.
Source export does not prove that a new compilation is byte-for-byte identical
to deployed bytecode; independently verify compiler settings and explorer code.

Deployment uses `contracts/script/Deploy.s.sol` with sibling configuration.
Owner and fee-recipient fields are deliberately blank in the deployment template;
set and review your own addresses privately before invoking any script.
No automatic deployment command or production signing key is provided.


## Scope and safety

Ethereum Mainnet (chain ID 1) only. Supported fixed deposits: 10, 50, 100 and
1,000 USDC; arbitrary/custom amounts are not supported. Yield is variable.
Gas sponsorship depends on service availability and limits. Zero-knowledge
proofs do not eliminate public timing, amount, network or recipient metadata.
No claim of guaranteed anonymity, guaranteed returns or independent security
certification is made.

This is a source distribution, not a production environment or permission to
spend funds. Local tests may use mocks; those are fixtures, not deployed
protocols. Never use production keys or real user notes in tests.

## Contributing and security

Read [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md),
[OPERATIONS.md](OPERATIONS.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
Hushfund-authored code is MIT licensed unless a file states otherwise.
Existing third-party copyright and license notices remain authoritative.
Hushfund names, logos and domains identify the original project; the code
license does not grant endorsement or trademark rights. Forks must identify
themselves and must not impersonate the official service.


## Official links

- Website: https://hushfund.eth.limo
- Application: https://hushfund.app
- App documentation: https://hushfund.app/docs
- Mechanism: https://hushfund.eth.limo/mechanism.html
- Privacy limits: https://hushfund.eth.limo/privacy.html
- Risks: https://hushfund.eth.limo/risks.html
- X: https://x.com/Hushfund_
- GitHub: https://github.com/hushfund
- Contact: hello@husfund.app

## Repository family

- [hushfund-contracts](https://github.com/hushfund/hushfund-contracts) — Ethereum Mainnet USDC vault contracts, Noir circuits, verifiers and protocol tests.
- [hushfund-app](https://github.com/hushfund/hushfund-app) — Hushfund web app for private USDC notes, yield, withdrawals, borrowing and repayment.
- [hushfund-backend](https://github.com/hushfund/hushfund-backend) — Hushfund API and gas-sponsoring relayer with persistent transaction state and Openfort integration.
- [hushfund-landing](https://github.com/hushfund/hushfund-landing) — Hushfund marketing website and mechanism, privacy and risk pages for ENS/IPFS hosting.

