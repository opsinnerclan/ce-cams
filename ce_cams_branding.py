#!/usr/bin/env python3
"""
ce_cams_branding.py - turns a VMS Customization Package into a "CE Cams" one.

  python ce_cams_branding.py metavms_package.zip ce_cams_customization.zip
         [--name "CE Cams"] [--id cecams] [--company CE] [--support-email you@example.com]
         [--cloud-host cloud.example.com] [--cloud-name "CE Cams Cloud"]

What changes:
  * description.json: product/company names, ids (customization id = --id), install names, URI
    protocol; Nx's trial key, release list and auto-updates are cleared so the client never pulls
    Nx builds or Nx trial licenses. With --cloud-host the client uses your CE Cams Cloud
    (cloudHost, cloudName) instead of Nx's: no desktop_client.ini needed.
  * every desktop/installer/server/mobile image: replaced with generated CE Cams artwork at the
    same size. The mobile app gets its own id (com.<id>.mobile) and accepts only <id> servers.
  * license.html: replaced with a placeholder EULA for you to edit.
Everything else (UI skin, fonts) is copied unchanged.

The id must match nx_stub_server's "customization" setting (build_ce_cams.bat sets it).
Needs Pillow (pip install pillow).
"""

from __future__ import annotations

import argparse
import io
import json
import sys
import zipfile

from PIL import Image, ImageDraw, ImageFont

ACCENT_TOP = (0, 168, 170)        # teal
ACCENT_BOTTOM = (16, 74, 140)     # deep blue
DARK = (18, 24, 32)
WHITE = (255, 255, 255)


TRIAL_KEY = "CECA-MSTR-IALK-EY26"   # keep in sync with nx_stub_server.py


def font(size: int, bold: bool = True) -> ImageFont.ImageFont:
    names = (["segoeuib.ttf", "arialbd.ttf", "DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf"]
             if bold else ["segoeui.ttf", "arial.ttf", "DejaVuSans.ttf"])
    for name in names:
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def gradient(size: tuple[int, int], top=ACCENT_TOP, bottom=ACCENT_BOTTOM) -> Image.Image:
    w, h = size
    img = Image.new("RGB", (1, max(h, 1)))
    for y in range(max(h, 1)):
        t = y / max(h - 1, 1)
        img.putpixel((0, y), tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img.resize((w, h)).convert("RGBA")


def draw_lens(d: ImageDraw.ImageDraw, cx: float, cy: float, r: float) -> None:
    """A camera lens: white ring, dark iris, small highlight."""
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=WHITE)
    r2 = r * 0.72
    d.ellipse([cx - r2, cy - r2, cx + r2, cy + r2], fill=DARK)
    r3 = r * 0.38
    d.ellipse([cx - r3, cy - r3, cx + r3, cy + r3], fill=ACCENT_BOTTOM)
    hr = r * 0.16
    hx, hy = cx - r * 0.28, cy - r * 0.28
    d.ellipse([hx - hr, hy - hr, hx + hr, hy + hr], fill=(220, 245, 245))


def app_icon(px: int) -> Image.Image:
    """Rounded square app icon. Large sizes show 'CE' under the lens."""
    scale = 4                                   # draw big, downsample for smooth edges
    s = px * scale
    base = gradient((s, s))
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, s - 1, s - 1], radius=int(s * 0.22), fill=255)
    icon = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    icon.paste(base, (0, 0), mask)
    d = ImageDraw.Draw(icon)
    if px >= 64:
        draw_lens(d, s * 0.5, s * 0.40, s * 0.24)
        f = font(int(s * 0.20))
        text = "CE"
        tw = d.textlength(text, font=f)
        d.text(((s - tw) / 2, s * 0.68), text, font=f, fill=WHITE)
    else:
        draw_lens(d, s * 0.5, s * 0.5, s * 0.32)
    return icon.resize((px, px), Image.LANCZOS)


def wordmark(size: tuple[int, int], name: str, dark_text: bool = False) -> Image.Image:
    """Wide logo: icon + product name, transparent background."""
    w, h = size
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    icon = app_icon(max(int(h * 0.9), 8))
    img.paste(icon, (int(h * 0.05), int(h * 0.05)), icon)
    d = ImageDraw.Draw(img)
    x = int(h * 1.1)
    room = w - x - max(int(h * 0.1), 2)
    size = max(int(h * 0.5), 8)
    while size > 8 and d.textlength(name, font=font(size)) > room:
        size -= 1                                # shrink until the name fits
    f = font(size)
    top, bottom = d.textbbox((0, 0), name, font=f)[1::2]
    d.text((x, (h - (bottom - top)) / 2 - top), name, font=f, fill=DARK if dark_text else WHITE)
    return img


def background(size: tuple[int, int], name: str, with_text: bool) -> Image.Image:
    w, h = size
    img = gradient((w, h), top=(14, 30, 44), bottom=DARK)
    d = ImageDraw.Draw(img)
    # Faint large lens as a watermark.
    r = min(w, h) * 0.28
    cx, cy = w * 0.5, h * 0.45
    for k, alpha in ((1.0, 18), (0.72, 26), (0.38, 34)):
        rr = r * k
        overlay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        ImageDraw.Draw(overlay).ellipse([cx - rr, cy - rr, cx + rr, cy + rr],
                                        outline=ACCENT_TOP + (alpha * 4,), width=max(int(r * 0.02), 1))
        img = Image.alpha_composite(img, overlay)
    if with_text:
        d = ImageDraw.Draw(img)
        f = font(max(int(h * 0.09), 10))
        tw = d.textlength(name, font=f)
        d.text(((w - tw) / 2, h * 0.78), name, font=f, fill=WHITE)
    return img


def render_like(original: bytes, entry: str, name: str) -> bytes:
    """New artwork with the same size and format as the original entry."""
    lower = entry.lower()
    with Image.open(io.BytesIO(original)) as src:
        w, h = src.size
        fmt = (src.format or "").upper()
    if lower.endswith(".ico"):
        sizes = (16, 24, 32, 48, 64, 128, 256)     # Windows picks the right one per context
        out = io.BytesIO()
        app_icon(256).save(out, format="ICO", sizes=[(s, s) for s in sizes])
        return out.getvalue()
    if lower.endswith(".icns"):
        out = io.BytesIO()
        app_icon(512).save(out, format="ICNS")
        return out.getvalue()
    if "launcher_bg" in lower:                  # Android adaptive icon: background layer
        img = gradient((w, h)).convert("RGBA")
    elif "launcher_fg" in lower:                # foreground: the lens in the middle 2/3 (the
        img = Image.new("RGBA", (w, h), (0, 0, 0, 0))  # rest may be cropped by the launcher)
        draw_lens(ImageDraw.Draw(img), w / 2, h / 2, w * 0.22)
    elif lower.startswith("mobile/ios/icon_"):  # iOS draws its own rounded corners; no alpha
        img = gradient((w, h))
        draw_lens(ImageDraw.Draw(img), w / 2, h / 2, w * 0.3)
        img = img.convert("RGB")
    elif "background" in lower:
        img = background((w, h), name, with_text="installer" in lower)
    elif w >= h * 1.8:                          # wide logos: email, web admin
        img = wordmark((w, h), name, dark_text="email" in lower)
    else:
        img = app_icon(min(w, h))
        if (w, h) != img.size:
            canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
            canvas.paste(img, ((w - img.width) // 2, (h - img.height) // 2), img)
            img = canvas
    out = io.BytesIO()
    if fmt in ("JPEG", "JPG"):
        img.convert("RGB").save(out, format="JPEG", quality=92)
    else:
        img.save(out, format="PNG")
    return out.getvalue()


def set_path(data: dict, dotted: str, value, only_if_present: bool = False) -> None:
    keys = dotted.split(".")
    node = data
    for k in keys[:-1]:
        if k not in node or not isinstance(node[k], dict):
            if only_if_present:
                return
            node[k] = {}
        node = node[k]
    if only_if_present and keys[-1] not in node:
        return
    node[keys[-1]] = value


def rebrand_description(raw: bytes, args) -> bytes:
    desc = json.loads(raw.decode("utf-8-sig"))
    for path, value in (("id", args.id), ("vmsId", args.name), ("vmsName", args.name),
                        ("companyName", args.company), ("companyId", args.id),
                        ("installerName", args.id), ("brand", args.id),
                        ("uriProtocol", args.id), ("advanced.customClientDisplayName", args.name)):
        set_path(desc, path, value)
    # The client only enables its "Activate" button for keys as long as the trial key, so it must
    # be a real 16-character key. This one is CE Cams' own (nx_stub_server.py TRIAL_KEY).
    set_path(desc, "desktop.trialLicenseKey", TRIAL_KEY)
    # Never point at Nx's update feed.
    for path, value in (("desktop.releaseListUrl", ""),
                        ("desktop.clientAutoUpdates", False),
                        ("desktop.offlineUpdateGeneratorUrl", "")):
        set_path(desc, path, value, only_if_present=True)
    # The mobile app (build_ce_cams.sh --android): its own app id, so it installs beside Nx's
    # app, and it accepts only CE Cams servers.
    package = f"com.{args.id}.mobile"
    for path, value in (("mobile.displayName", args.name),
                        ("mobile.android.packageName", package),
                        ("mobile.android.compatibilityPackage", package),
                        ("mobile.ios.bundleIdentifier", package),
                        ("mobile.ios.bundleName", args.name[:15]),
                        ("mobile.ios.groupIdentifier", f"group.{package}"),
                        ("mobile.ios.compatibilityPackage", package),
                        ("mobile.compatibleCustomizations", args.id),
                        ("mobile.compatibleUriProtocols", args.id)):
        set_path(desc, path, value)
    if args.cloud_host:
        # Read at build time (cmake/cloud_host.cmake -> nx::branding::cloudHost()): the client's
        # cloud login page, cloud_modules.xml (mediator, relay) and account API all live there.
        set_path(desc, "cloudHost", args.cloud_host)
        set_path(desc, "cloudName", args.cloud_name)
    if args.support_email:
        set_path(desc, "contact.supportAddress", args.support_email)
        set_path(desc, "contact.licensingAddress", args.support_email)
    if args.company_url:
        set_path(desc, "contact.companyUrl", args.company_url)
    return (json.dumps(desc, indent=4, ensure_ascii=False) + "\n").encode("utf-8")


EULA = """<!DOCTYPE html><html><head><meta charset="utf-8"><title>{name} License</title></head>
<body style="font-family:sans-serif"><h2>{name} End-User License Agreement</h2>
<p>Placeholder. Replace this text with your own terms before giving {name} to anyone.</p>
<p>{name} includes software from the Network Optix Meta Platform open-source components,
licensed under the Mozilla Public License 2.0 (https://mozilla.org/MPL/2.0/). The source code of
those components, including any modifications, is available on request.</p></body></html>
"""


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("input", help="customization package zip to start from (e.g. the default)")
    p.add_argument("output", help="where to write the CE Cams package")
    p.add_argument("--name", default="CE Cams")
    p.add_argument("--id", default="cecams", help="customization id (lowercase, no spaces)")
    p.add_argument("--company", default="CE")
    p.add_argument("--support-email", default="")
    p.add_argument("--company-url", default="")
    p.add_argument("--cloud-host", default="",
                   help="your CE Cams Cloud's host name, e.g. cloud.example.com (no https://)")
    p.add_argument("--cloud-name", default="CE Cams Cloud",
                   help="what the client calls the cloud (with --cloud-host)")
    p.add_argument("--preview", help="also save the app icon as a PNG here")
    args = p.parse_args()
    args.cloud_host = args.cloud_host.strip().removeprefix("https://").removeprefix(
        "http://").strip("/")
    if args.cloud_host and ("/" in args.cloud_host or " " in args.cloud_host):
        print("--cloud-host is just the host name, e.g. cloud.example.com")
        return 1
    if not args.id.isascii() or not args.id.replace("_", "").isalnum() or args.id.lower() != args.id:
        print("--id must be lowercase letters/digits, e.g. cecams")
        return 1

    replaced, copied = [], 0
    with zipfile.ZipFile(args.input) as zin, \
            zipfile.ZipFile(args.output, "w", zipfile.ZIP_DEFLATED) as zout:
        names = zin.namelist()
        if "description.json" not in names:
            print(f"{args.input} has no description.json; is it a customization package?")
            return 1
        for entry in names:
            if entry.endswith("/"):
                continue
            data = zin.read(entry)
            lower = entry.lower()
            if entry == "description.json":
                data = rebrand_description(data, args)
                replaced.append(entry)
            elif entry == "license.html":
                data = EULA.format(name=args.name).encode("utf-8")
                replaced.append(entry)
            elif lower.endswith((".png", ".ico", ".icns", ".jpg", ".jpeg")) \
                    and not lower.startswith("custom_cloud/") and "skin" not in lower:
                try:
                    data = render_like(data, entry, args.name)
                    replaced.append(entry)
                except Exception as e:      # unreadable image: keep the original
                    print(f"  kept {entry} ({e})")
                    copied += 1
            else:
                copied += 1
            zout.writestr(entry, data)
    if args.preview:
        app_icon(256).save(args.preview)
    print(f"Wrote {args.output}: {len(replaced)} file(s) rebranded, {copied} copied unchanged")
    for entry in replaced:
        print(f"  {entry}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
