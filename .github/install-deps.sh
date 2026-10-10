#!/usr/bin/env bash
# Fetch the Solidity dependencies this repo builds against.
#
# WHY THIS EXISTS. `lib/` is gitignored and there is no `.gitmodules`: these were installed with a
# forge version that writes plain directories rather than submodules. So `actions/checkout` with
# `submodules: recursive` fetched NOTHING, and every CI build died at
# "Source lib/forge-std/src/Script.sol not found" before compiling a single line. This script
# fetches them explicitly instead.
#
# Pinned to exact commits, not tags or branches, so CI compiles what was developed and tested
# against rather than whatever the default branch happens to be that morning.
#
# RECURSIVE ON PURPOSE. v4-core and openzeppelin-contracts carry their own `lib/` trees
# (v4-core needs solmate, forge-std and openzeppelin) and forge's auto-remapping resolves imports
# into them. A non-recursive clone compiles until the first `solmate/...` import and then does not.
set -euo pipefail

# IDEMPOTENT, because the runner may be self-hosted and keep its workspace between jobs. A plain
# `git clone` into an existing directory fails, so an already-correct checkout is reused and anything
# else is removed and refetched. On a hosted runner the directory is never there and this is a clone.
fetch() { # url dir sha
  if [ -d "$2/.git" ] && [ "$(git -C "$2" rev-parse HEAD 2>/dev/null)" = "$3" ]; then
    echo "  $2 @ $(git -C "$2" rev-parse --short HEAD) (reused)"
    return
  fi
  rm -rf "$2"
  git clone --quiet --filter=blob:none "$1" "$2"
  git -C "$2" checkout --quiet "$3"
  git -C "$2" submodule update --init --recursive --quiet
  echo "  $2 @ $(git -C "$2" rev-parse --short HEAD)"
}

mkdir -p lib
echo "installing pinned dependencies:"
fetch https://github.com/foundry-rs/forge-std            lib/forge-std              da5b326fb2d7f69e87c3ea95f3fcc3ab49a38549
fetch https://github.com/OpenZeppelin/openzeppelin-contracts lib/openzeppelin-contracts 69c8def5f222ff96f2b5beff05dfba996368aa79
fetch https://github.com/Uniswap/v4-core                 lib/v4-core                e50237c43811bd9b526eff40f26772152a42daba
