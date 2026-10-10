# QuoPull art and brand: all rights reserved

Copyright (c) 2026 QuoPull contributors. All rights reserved.

The code in this repository is released under the MIT license (see `LICENSE`). The MIT license does **not**
cover the art and brand assets listed below. No license is granted to copy, modify, distribute, sell, mint,
or make derivative works from them, except as needed to view the QuoPull website or to build and run this
repository unchanged.

## What is reserved

- **Everything under `web/art/`**, including:
  - `web/art/final-*.svg`, the Art Pass tier artwork shown on the website;
  - `web/art/onchain/*`, the artwork data that `script/DeployPassArt.s.sol` stores onchain and that
    `src/nft/PassArtRenderer.sol` returns from `tokenURI`;
  - `web/art/onchain-preview/*`, rendered previews of that artwork written by the tests.
- **The QuoPull logo and wordmark**, wherever they appear, including the inline SVG mark in the HTML pages
  under `web/`.
- **The social and app images**: `web/og.png`, `web/og-srclaim.png` and `web/apple-touch-icon.png`.

## What this means in practice

- You may clone, build and test the repository as is. The tests and the art deploy script read the files in
  `web/art/`, so they stay in the repository.
- You may read and reuse the code (including `PassArtRenderer.sol`) under MIT, but if you deploy your own
  version, replace the artwork, the logo, the wordmark and the social images with your own.
- Owning a QuoPull Art Pass does not change the terms above for the artwork as a whole.

For permission requests, open an issue in this repository.
