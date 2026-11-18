#!/usr/bin/env python3
"""Vision OCR spike — compare Vision framework vs Tesseract on sample images."""

import subprocess
import time
import json
from pathlib import Path

VISION_BIN = Path("/tmp/vision_ocr")
HAS_TESSERACT = False
try:
    import pytesseract
    from PIL import Image
    HAS_TESSERACT = True
except ImportError:
    pass


def create_test_image(text, width=800, height=200, font_size=36, noise=0.0):
    """Create a test image with given text using PIL."""
    try:
        from PIL import ImageDraw, ImageFont
    except ImportError:
        return None
    img = Image.new("RGB", (width, height), "white")
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", font_size)
    except (IOError, OSError):
        font = ImageFont.load_default()
    draw.text((50, 50), text, fill="black", font=font)
    if noise > 0:
        import random
        pixels = img.load()
        w, h = img.size
        for _ in range(int(noise * w * h)):
            x, y = random.randint(0, w - 1), random.randint(0, h - 1)
            r, g, b = pixels[x, y]
            nv = random.randint(-40, 40)
            pixels[x, y] = (max(0, min(255, r + nv)), max(0, min(255, g + nv)), max(0, min(255, b + nv)))
    path = Path(tempfile.mkdtemp()) / "test_image.png"
    img.save(str(path), "PNG")
    return path


def ocr_vision(image_path):
    """OCR using compiled Vision tool."""
    start = time.perf_counter()
    try:
        result = subprocess.run(
            [str(VISION_BIN), str(image_path)],
            capture_output=True, text=True, timeout=30
        )
        latency = (time.perf_counter() - start) * 1000
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip(), latency
        return f"ERROR: {result.stderr.strip()}", latency
    except subprocess.TimeoutExpired:
        return "TIMEOUT", time.perf_counter() * 1000


def ocr_tesseract(image_path, lang="eng"):
    """OCR using Tesseract via pytesseract."""
    if not HAS_TESSERACT:
        return "Tesseract not available", float("inf")
    start = time.perf_counter()
    try:
        img = Image.open(str(image_path))
        text = pytesseract.image_to_string(img, lang=lang)
        latency = (time.perf_counter() - start) * 1000
        return text.strip(), latency
    except Exception as e:
        return f"ERROR: {e}", (time.perf_counter() - start) * 1000


def char_accuracy(got, expected):
    if not got or not expected:
        return 0.0
    matches = sum(1 for a, b in zip(got, expected) if a == b)
    return matches / max(len(got), len(expected))


def main():
    import tempfile

    # Pre-create test images
    test_dir = Path("/tmp/vision-ocr-spike")
    test_dir.mkdir(exist_ok=True)

    from PIL import ImageDraw, ImageFont

    # Test 1: Clean short text
    img = Image.new("RGB", (800, 200), "white")
    draw = ImageDraw.Draw(img)
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 36)
    draw.text((50, 50), "Re: Meeting tomorrow at 3pm", fill="black", font=font)
    img.save(str(test_dir / "clean.png"))

    # Test 2: Noisy image
    img2 = Image.new("RGB", (800, 200), "white")
    draw2 = ImageDraw.Draw(img2)
    draw2.text((50, 50), "Re: Meeting tomorrow at 3pm", fill="black", font=font)
    import random
    pixels = img2.load()
    for _ in range(int(0.05 * 800 * 200)):
        x, y = random.randint(0, 799), random.randint(0, 199)
        r, g, b = pixels[x, y]
        nv = random.randint(-40, 40)
        pixels[x, y] = (max(0, min(255, r + nv)), max(0, min(255, g + nv)), max(0, min(255, b + nv)))
    img2.save(str(test_dir / "noisy.png"))

    # Test 3: Page with many lines
    lines = [f"This is line {i+1} of sample text for OCR testing." for i in range(20)]
    img3 = Image.new("RGB", (800, 1200), "white")
    draw3 = ImageDraw.Draw(img3)
    y = 50
    for line in lines:
        draw3.text((50, y), line, fill="black", font=ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 20))
        y += 35
    img3.save(str(test_dir / "page.png"))

    expected = {
        "clean": "Re: Meeting tomorrow at 3pm",
        "noisy": "Re: Meeting tomorrow at 3pm",
        "page": "\n".join(lines),
    }

    results = []

    for name in ["clean", "noisy", "page"]:
        path = test_dir / f"{name}.png"
        print(f"--- {name} ---")

        # Vision
        v_text, v_latency = ocr_vision(path)
        v_acc = char_accuracy(v_text, expected[name]) if not v_text.startswith("ERROR") else 0
        print(f"  Vision:     {v_latency:7.0f}ms  accuracy={v_acc:.2%}  \"{v_text[:80]}\"")
        results.append({"test": name, "engine": "vision", "latency_ms": v_latency, "accuracy": v_acc, "text": v_text})

        # Tesseract
        if HAS_TESSERACT:
            t_text, t_latency = ocr_tesseract(path)
            t_acc = char_accuracy(t_text, expected[name]) if not t_text.startswith("ERROR") else 0
            print(f"  Tesseract:  {t_latency:7.0f}ms  accuracy={t_acc:.2%}  \"{t_text[:80]}\"")
            results.append({"test": name, "engine": "tesseract", "latency_ms": t_latency, "accuracy": t_acc, "text": t_text})

        print()

    # Summary
    print("=== Summary ===")
    for r in results:
        acc_str = f"{r['accuracy']:.2%}" if r.get('accuracy') is not None else "N/A"
        print(f"  {r['engine']:12s} | {r['test']:10s} | {r['latency_ms']:8.0f}ms | acc={acc_str}")

    # Write results
    out = test_dir / "results.json"
    out.write_text(json.dumps(results, indent=2))
    print(f"\nResults: {out}")


if __name__ == "__main__":
    main()
