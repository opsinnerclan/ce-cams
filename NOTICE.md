# Third-party notices

The CE Cams client is built from the following components, each under its own license.

## nx_open (Nx Meta / Nx Witness open-source client)

- Copyright © Network Optix.
- Licensed under the **Mozilla Public License 2.0** (see `LICENSE`).
- Source: https://github.com/networkoptix/nx_open, release tag `vms/6.1.2/release_42921_all`.
- The modifications CE Cams makes to these files are in this repository
  (`ce_cams_patches.py`, `ce_cams_branding.py`, `ce_cams_patch_fork.py`). Under the MPL, the
  source of each modified file is available here and upstream.

"Nx", "Nx Witness", "Nx Meta" and "Network Optix" are trademarks of Network Optix. CE Cams is an
independent fork and is not affiliated with, endorsed by, or supported by Network Optix.

## Qt

- The client links the Qt framework, used under the **GNU Lesser General Public License (LGPL)
  v3**. Qt is dynamically linked; its source and license are available from https://www.qt.io/
  and https://code.qt.io/.

## FFmpeg

- The client uses FFmpeg libraries under the **GNU LGPL v2.1 or later**. Source and license:
  https://ffmpeg.org/.

## WinSW (Windows service wrapper, server installer only)

- The Windows server installer (in the separate private repo) uses WinSW under the **MIT
  License**: https://github.com/winsw/winsw. Listed here for completeness; WinSW is not part of
  the client.

---

If you distribute the CE Cams client, you must pass along these notices and make the
corresponding source available as each license requires. For the MPL-licensed `nx_open` files,
this repository together with the upstream release tag above is that source.
