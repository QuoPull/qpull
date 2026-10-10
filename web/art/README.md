# web/art

The files in this folder are QuoPull artwork. They are **all rights reserved** and are **not** covered by the
repository's MIT license. See [`ART-LICENSE.md`](../../ART-LICENSE.md) at the repository root.

| Path | What it is | Used by |
|---|---|---|
| `final-*.svg` | Art Pass tier artwork (Common, Uncommon, Rare, Super Rare) | `web/index.html` |
| `onchain/*` | Artwork data stored onchain for the Art Pass | `script/DeployPassArt.s.sol`, `test/PassArtRenderer.t.sol`, `test/DeployPassArt.t.sol` |
| `onchain-preview/*` | Previews rendered from the onchain art | written by `test/PassArtRenderer.t.sol` when `WRITE_PREVIEW=true` |
