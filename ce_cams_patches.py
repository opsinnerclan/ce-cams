#!/usr/bin/env python3
"""
ce_cams_patches.py - small source changes to an nx_open checkout for the CE Cams client.
Safe to run again: each change is applied once.

  python ce_cams_patches.py PATH_TO_NX_OPEN

What it changes:
  * the client no longer crashes on a damaged audio packet (a frame with other channels than
    its decoder: the resampler read past the frame, in swresample).
  * no "Beta version - This build is for testing purposes only" box at startup. nx_open builds
    are publicationType "local", which the client treats as a beta. The publication type itself
    stays "local", so the client still sends no usage statistics or crash reports to Network Optix.
  * Java for apidoctool: cmake/find_java.cmake looks only for an "openjdk-jre" Conan package; the
    Android build gets "openjdk", so Java was "/bin/java" and configuring failed ("Cannot get
    dependency list from apidoctool"). Falls back to "openjdk".
  * std::ranges::range_adaptor_closure (C++23) for libc++ older than 19 (Android NDK r26d), which
    has it only as std::__range_adaptor_closure. Other standard libraries are left alone.
  * Linux .deb: CE Cams in the app menu. The package names its menu launcher after installerName
    and its (hidden) cecams:// link handler after uriProtocol; ours are both "cecams", so the
    handler overwrote the launcher and the client never appeared in the menu. The launcher is now
    "<installerName>-client.desktop" when the two names are the same.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

PATCHES = [
    (
        "vms/distribution/deb/client/build_distribution.sh",
        """    mv -f "$STAGE/usr/share/applications/icon.desktop" \\
        "$STAGE/usr/share/applications/$INSTALLER_NAME.desktop"
""",
        """    # CE Cams: installerName and uriProtocol are both "cecams"; the URI handler below (hidden,
    # NoDisplay) would overwrite the menu launcher, so give the launcher its own name.
    local launcher="$INSTALLER_NAME"
    if [ "$INSTALLER_NAME" = "$URI_PROTOCOL" ]; then launcher="$INSTALLER_NAME-client"; fi
    mv -f "$STAGE/usr/share/applications/icon.desktop" \\
        "$STAGE/usr/share/applications/$launcher.desktop"
""",
    ),
    (
        "cmake/find_java.cmake",
        """set(Java_JAVA_EXECUTABLE "${CONAN_OPENJDK-JRE_ROOT}/bin/java${CMAKE_EXECUTABLE_SUFFIX}")
""",
        """# CE Cams: the Android build gets the "openjdk" Conan package, not "openjdk-jre".
if(CONAN_OPENJDK-JRE_ROOT)
    set(_nx_java_root "${CONAN_OPENJDK-JRE_ROOT}")
elseif(CONAN_OPENJDK_ROOT)
    set(_nx_java_root "${CONAN_OPENJDK_ROOT}")
else()
    set(_nx_java_root "${PACKAGE_OPENJDK_ROOT}")
endif()
set(Java_JAVA_EXECUTABLE "${_nx_java_root}/bin/java${CMAKE_EXECUTABLE_SUFFIX}")
""",
        "CONAN_OPENJDK_ROOT",  # also patched by hand earlier (2026-11-20)
    ),
    (
        "vms/client/nx_vms_client_desktop/src/ui/workbench/handlers/startup_actions_handler.cpp",
        """    const bool nonPublicVersion =
        nx::build_info::publicationType() != nx::build_info::PublicationType::patch
        && nx::build_info::publicationType() != nx::build_info::PublicationType::release;
""",
        """    // CE Cams: our own builds are publicationType "local" but are not betas.
    const bool nonPublicVersion =
        nx::build_info::publicationType() != nx::build_info::PublicationType::patch
        && nx::build_info::publicationType() != nx::build_info::PublicationType::release
        && nx::build_info::publicationType() != nx::build_info::PublicationType::local;
""",
    ),
    (
        # A damaged audio packet can decode to a frame with other channels, format or rate than
        # the decoder context. The resampler is set up from the context, so it read channel
        # planes the frame doesn't have and the client crashed (swresample, read near NULL).
        # Skip such frames; also grow the output buffer until the frame fits (doubling once
        # wasn't always enough).
        "vms/libs/nx_vms_common/src/decoders/audio/ffmpeg_audio_decoder.cpp",
        """#include <nx/utils/log/log_main.h>
""",
        """#include <nx/utils/log/log_main.h>

#include <algorithm> //< CE Cams: std::max below.
""",
    ),
    (
        "vms/libs/nx_vms_common/src/decoders/audio/ffmpeg_audio_decoder.cpp",
        """        int decodedBytes =
            m_outFrame->nb_samples * QnFfmpegHelper::audioSampleSize(m_audioDecoderCtx);
        if (outbuf_len + decodedBytes > (int)result.capacity())
        {
            result.reserve(result.capacity() * 2);
            outbuf = (quint8*)result.data() + outbuf_len;
        }
""",
        """        // CE Cams: skip frames that don't match the decoder context (see ce_cams_patches.py).
        if (m_outFrame->ch_layout.nb_channels != m_audioDecoderCtx->ch_layout.nb_channels
            || m_outFrame->format != (int) m_audioDecoderCtx->sample_fmt
            || m_outFrame->sample_rate != m_audioDecoderCtx->sample_rate
            || !m_outFrame->data[0])
        {
            NX_WARNING(this, "Skipping an audio frame that doesn't match its decoder "
                "(%1 channel(s), %2 Hz)", m_outFrame->ch_layout.nb_channels,
                m_outFrame->sample_rate);
            continue;
        }

        int decodedBytes =
            m_outFrame->nb_samples * QnFfmpegHelper::audioSampleSize(m_audioDecoderCtx);
        if (outbuf_len + decodedBytes > (int)result.capacity())
        {
            result.reserve(std::max((int) result.capacity() * 2, outbuf_len + decodedBytes));
            outbuf = (quint8*)result.data() + outbuf_len;
        }
""",
    ),
]


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip())
        return 2
    src = Path(sys.argv[1])
    for rel, old, new, *marker in PATCHES:
        path = src / rel
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as e:
            print(f"ce_cams_patches: can't read {path}: {e}", file=sys.stderr)
            return 1
        if new in text or (marker and marker[0] in text):
            print(f"  already patched: {rel}")
            continue
        if text.count(old) != 1:
            print(f"ce_cams_patches: {rel} doesn't look like nx_open 6.1.2; not patched",
                  file=sys.stderr)
            return 1
        path.write_text(text.replace(old, new), encoding="utf-8", newline="")
        print(f"  patched: {rel}")
    return patch_range_adaptor_closure(src)


RANGES_MARKER = "NX_RANGE_ADAPTOR_CLOSURE_COMPAT"
RANGES_SHIM = """// CE Cams: libc++ < 19 (Android NDK r26) only has the internal __range_adaptor_closure.
#include <ranges>
#if defined(_LIBCPP_VERSION) && _LIBCPP_VERSION < 190000 && !defined(NX_RANGE_ADAPTOR_CLOSURE_COMPAT)
#define NX_RANGE_ADAPTOR_CLOSURE_COMPAT
_LIBCPP_BEGIN_NAMESPACE_STD
namespace ranges { template<class T> using range_adaptor_closure = std::__range_adaptor_closure<T>; }
_LIBCPP_END_NAMESPACE_STD
#endif
"""


def patch_range_adaptor_closure(src: Path) -> int:
    """Every nx_open source using std::ranges::range_adaptor_closure gets the shim above."""
    for dir_name in ("libs", "vms"):
        for path in sorted((src / dir_name).rglob("*")):
            if path.suffix not in {".h", ".hpp", ".cpp", ".ipp", ".inl"} or not path.is_file():
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            if "ranges::range_adaptor_closure" not in text:
                continue
            rel = path.relative_to(src).as_posix()
            if RANGES_MARKER in text:
                print(f"  already patched: {rel}")
                continue
            m = re.search(r"^#pragma once.*\n", text, re.M)
            text = (text[:m.end()] + "\n" + RANGES_SHIM + text[m.end():]) if m \
                else RANGES_SHIM + "\n" + text
            path.write_text(text, encoding="utf-8", newline="")
            print(f"  patched: {rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
