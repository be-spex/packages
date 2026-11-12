# be-spex packages

Signed APT repository for the be-spex applications, published at
**https://be-spex.github.io/packages** – setup instructions are on that page.

| Package | Source |
|---|---|
| `marq` | [be-spex/Marq](https://github.com/be-spex/Marq) |
| `xaq` | [be-spex/Xaq](https://github.com/be-spex/Xaq) |
| `maillet` | [be-spex/Maillet](https://github.com/be-spex/Maillet) |
| `hatrack` | [be-spex/HatRack](https://github.com/be-spex/HatRack) (amd64, arm64) |
| `pockettray` | [be-spex/PocketTray](https://github.com/be-spex/PocketTray) |
| `be-spex-archive-keyring` | this repository: signing key and APT source |

## How it works

Nothing is committed here per release. [`publish.yml`](.github/workflows/publish.yml) runs every
30 minutes (and on push or by hand), lists the newest 3 stable releases of each repository in
[`repos.json`](repos.json), and rebuilds only if their `.deb` assets changed
([`scripts/state.sh`](scripts/state.sh)). [`scripts/build.sh`](scripts/build.sh) then downloads the
packages, adds the keyring package, writes the indices with `apt-ftparchive`, signs `Release`
(`InRelease`, `Release.gpg`) and the result is deployed to GitHub Pages.

- **Add an application:** a line in `repos.json` with the package names its releases contain.
  Its release workflow only has to attach the `.deb` files to a GitHub release.
- **Signing key:** RSA 4096, no expiry, fingerprint `52006D90BDB8272ED2037F6036AE9C5B18B03CC0`.
  Public part in [`keys/`](keys/), private part only in the repository secret `APT_SIGNING_KEY`
  (and the maintainer's backup).
- **Build locally:** `GNUPGHOME=<keyring with the secret key> OUT=/tmp/apt scripts/build.sh`
  (needs `gh`, `jq`, `dpkg-deb`, `apt-ftparchive`, `gpg`).
- **Keyring package:** bump `keyring/VERSION` when the key or the source changes.
