# CE Cams client - build tooling

This repository holds the **open-source build tooling** for the **CE Cams** desktop and mobile
client. CE Cams is a fork of Network Optix's open-source
[nx_open](https://github.com/networkoptix/nx_open) (the Nx Meta / Nx Witness desktop client),
which is licensed under the **Mozilla Public License 2.0**. It is published here to make the
source of the modified files available, as the MPL requires.

**CE Cams is not a Network Optix product.** "Nx", "Nx Witness", "Nx Meta" and "Network Optix"
are trademarks of Network Optix and are used here only to describe what this fork is based on.

## Just want to use CE Cams?

If you're here to **run** CE Cams rather than build it, you don't need any of this. Download the
server installer from the [Releases](../../releases) page and follow
**[docs/getting-started.md](docs/getting-started.md)** - install the server, add your cameras, and
(optionally) connect to the cloud for remote access without opening ports. The rest of this repo
is the client's source, published for license compliance.

## What's here

This repo contains only the scripts that turn an upstream `nx_open` checkout into the CE Cams
client - the modifications themselves, plus how to build them:

| File | What it does |
|------|--------------|
| `build_ce_cams.sh` | builds the Linux client (`.deb`) and the Android app, end to end |
| `build_ce_cams.bat` / `ce_cams_build.ps1` | builds the Windows client (installer) |
| `ce_cams_patches.py` | the source changes applied to `nx_open` (audio-packet crash fix, beta-box removal, Android build fixes) |
| `ce_cams_branding.py` | turns an upstream customization package into a "CE Cams" one (names, ids, artwork, cloud host) |
| `ce_cams_patch_fork.py` | swaps in your own license public key in place of Network Optix's |
| `ce_cams_fetch_sources.py` | gets the dependency source archives from the projects' public download sites |
| `ce_cams_bundle_libs.sh` | bundles a couple of libraries newer Ubuntu releases dropped |

The upstream source itself is **not** vendored here; the build scripts fetch the public
`nx_open` release tag `vms/6.1.2/release_42921_all` from Network Optix's GitHub and apply the
changes above. That keeps this repo small and makes exactly which upstream version is used
explicit.

## The CE Cams server and cloud are not here

This is the **client** only. The CE Cams server and cloud (the parts written from scratch, not
derived from `nx_open`) are kept in a separate, private repository. The client talks to them but
does not include any of their code. To build a client you supply your own **license public key**
(from your server or cloud) with `--public-key` / `-PublicKey`, or let the script download it
from your cloud with `--cloud-host` / `-CloudHost`.

## Building

See the comment block at the top of each build script for the full options.

**Linux client + Android app** (Ubuntu 20.04/22.04/24.04, ~80 GB disk, ~16 GB RAM; the first
build downloads several GB and takes hours):

```
./build_ce_cams.sh --public-key license_public.pem --cloud-host cloud.example.com
./build_ce_cams.sh --android   --public-key license_public.pem --cloud-host cloud.example.com
```

**Windows client** (Windows 10/11; needs the build dependencies Nx documents):

```
build_ce_cams.bat -PublicKey license_public.pem -CloudHost cloud.example.com
```

## Licensing and attribution

- The files derived from `nx_open` are under the **Mozilla Public License 2.0** - see `LICENSE`.
- Third-party components the client bundles (Qt, FFmpeg and others) keep their own licenses; see
  `NOTICE.md`.
- Each MPL source file carries the standard notice:

  > This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a
  > copy of the MPL was not distributed with this file, You can obtain one at
  > https://mozilla.org/MPL/2.0/.
