# Contributing

Thanks for taking a look. QuoPull is live on mainnet and its core contracts are immutable, so most changes to
`src/` cannot reach the deployed protocol. Contributions are most useful as tests, tooling, documentation and
reports of anything that looks wrong.

## Before you start

- **Security issues:** please do not open a public issue. Use GitHub's private vulnerability reporting on this
  repository.
- **Bigger changes:** open an issue first to talk it through.

## Working locally

```bash
./.github/install-deps.sh                  # pinned forge-std, OpenZeppelin 5.1.0 and Uniswap v4-core v4.0.0
forge build                                # via_ir is on, so a cold build is slow
forge test --no-match-path 'test/fork/*'   # the full local suite
```

The tests in `test/fork/` read Robinhood Chain mainnet and need an RPC (`RH_RPC_URL`). They never send anything.

## Pull requests

- Keep each pull request to one change, with a test that fails before it and passes after it.
- Run the full local suite and say in the description that it passes.
- Explain the reason for the change, not only what it does.
- Match the surrounding code's style and comment density.

## Writing style for docs and the site

- No em dashes or en dashes: use a comma, a colon or a full stop.
- "onchain" is one word. "Drand" is capitalised in prose (code and URLs stay lowercase).
- The team's share is always written "team + operations".

## License

By contributing you agree that your contribution is released under the [MIT license](LICENSE). The art, logo and
social images are not open source; see [ART-LICENSE.md](ART-LICENSE.md).
