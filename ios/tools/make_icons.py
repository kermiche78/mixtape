"""Fabrique les icônes au choix de Mixtape pendant la compilation (aucune image à envoyer).

Crée un dossier AppIcon-<Nom>.appiconset par icône dans Assets.xcassets et écrit la liste
des noms dans ios/build/alternate-icons.txt pour xcodebuild.
Une image posée dans ios/icons/ (perso.png, perso.jpg…) devient l'icône « La tienne ».
"""
import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Mixtape" / "Assets.xcassets"
OUT_LIST = ROOT / "build" / "alternate-icons.txt"
S = 1024


def gradient(c1, c2):
    img = Image.new("RGB", (S, S))
    px = img.load()
    for y in range(S):
        for x in range(S):
            t = (x + y) / (2 * S - 2)
            px[x, y] = tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))
    return img


def flat(c):
    return Image.new("RGB", (S, S), c)


def cassette(img, body, window, accent, reel, foot, holes):
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((172, 300, 852, 724), radius=56, fill=body)
    d.rounded_rectangle((232, 372, 792, 600), radius=36, fill=window)
    d.rounded_rectangle((300, 394, 724, 430), radius=18, fill=accent)
    for cx in (380, 644):
        d.ellipse((cx - 74, 412, cx + 74, 560), fill=reel)
        d.ellipse((cx - 40, 446, cx + 40, 526), fill=window)
        for k in range(6):
            a = math.pi / 3 * k + math.pi / 6
            x, y = cx + 52 * math.cos(a), 486 + 52 * math.sin(a)
            d.ellipse((x - 9, y - 9, x + 9, y + 9), fill=accent)
    d.rectangle((380, 552, 644, 566), fill=accent)
    d.polygon([(372, 648), (652, 648), (694, 724), (330, 724)], fill=foot)
    for cx in (430, 594):
        d.ellipse((cx - 15, 671, cx + 15, 701), fill=holes)
    return img


def vinyl(img, disc, groove, label, hole):
    d = ImageDraw.Draw(img)
    c, r = S // 2, 330
    d.ellipse((c - r, c - r, c + r, c + r), fill=disc)
    for rr in range(r - 40, 140, -34):
        d.ellipse((c - rr, c - rr, c + rr, c + rr), outline=groove, width=4)
    d.ellipse((c - 120, c - 120, c + 120, c + 120), fill=label)
    d.ellipse((c - 18, c - 18, c + 18, c + 18), fill=hole)
    d.arc((c - r + 30, c - r + 30, c + r - 30, c + r - 30), 200, 250, fill=(255, 255, 255), width=10)
    return img


def headphones(img, color, pad):
    d = ImageDraw.Draw(img)
    d.arc((232, 212, 792, 772), 180, 360, fill=color, width=64)
    d.rectangle((232, 490, 296, 600), fill=color)
    d.rectangle((728, 490, 792, 600), fill=color)
    d.rounded_rectangle((196, 520, 352, 780), radius=60, fill=pad)
    d.rounded_rectangle((672, 520, 828, 780), radius=60, fill=pad)
    return img


def microphone(img, head, mesh, stand):
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((372, 170, 652, 590), radius=140, fill=head)
    for y in range(230, 560, 46):
        d.line((402, y, 622, y), fill=mesh, width=10)
    d.arc((302, 330, 722, 700), 0, 180, fill=stand, width=36)
    d.rectangle((494, 690, 530, 820), fill=stand)
    d.rounded_rectangle((372, 806, 652, 850), radius=22, fill=stand)
    return img


PINK, PURPLE, NIGHT = (255, 74, 90), (124, 50, 245), (40, 26, 72)

ICONS = {
    "Noir": lambda: cassette(flat((12, 12, 14)), (34, 34, 38), (12, 12, 14), PINK, (240, 240, 240), (60, 60, 66), PINK),
    "Blanc": lambda: cassette(flat((244, 243, 248)), (255, 255, 255), NIGHT, PINK, (255, 255, 255), (228, 224, 240), PURPLE),
    "Vinyle": lambda: vinyl(gradient((83, 74, 183), (40, 26, 120)), (18, 18, 22), (44, 44, 52), PINK, (83, 74, 183)),
    "Casque": lambda: headphones(gradient((29, 158, 117), (8, 80, 65)), (255, 255, 255), (16, 40, 34)),
    "Studio": lambda: microphone(gradient((60, 60, 66), (18, 18, 22)), (230, 230, 236), (120, 120, 130), PINK),
    "Neon": lambda: cassette(gradient((10, 10, 30), (40, 10, 60)), (25, 20, 50), (8, 8, 20), (0, 240, 200), (255, 70, 200), (45, 35, 80), (0, 240, 200)),
}


def write_preview(name, image):
    """Petite image de l'icône, affichée dans les Réglages de l'app."""
    folder = ASSETS / f"IconPreview-{name}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").resize((180, 180), Image.LANCZOS).save(folder / "preview.png")
    (folder / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "preview.png", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2))


def write_set(name, image):
    write_preview(name, image)
    folder = ASSETS / f"AppIcon-{name}.appiconset"
    folder.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(folder / "icon-1024.png")
    (folder / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2))


def main():
    write_preview("Classique", Image.open(ASSETS / "AppIcon.appiconset" / "icon-1024.png"))
    names = []
    for name, make in ICONS.items():
        write_set(name, make())
        names.append(f"AppIcon-{name}")
    custom = next((p for p in sorted((ROOT / "icons").glob("perso.*"))
                   if p.suffix.lower() in (".png", ".jpg", ".jpeg", ".webp")), None) if (ROOT / "icons").exists() else None
    if custom:
        img = ImageOps.exif_transpose(Image.open(custom)).convert("RGB")
        side = min(img.size)
        img = img.crop(((img.width - side) // 2, (img.height - side) // 2,
                        (img.width + side) // 2, (img.height + side) // 2)).resize((S, S), Image.LANCZOS)
        write_set("Perso", img)
        names.append("AppIcon-Perso")
    OUT_LIST.parent.mkdir(parents=True, exist_ok=True)
    OUT_LIST.write_text(" ".join(names))
    print("Icônes :", " ".join(names))


if __name__ == "__main__":
    sys.exit(main())
