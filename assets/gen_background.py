#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成默认背景图（当用户没有提供 background.jpg 时使用）
在 assets/ 目录下生成一张渐变蓝天背景
需要: pip install pillow  或  sudo apt install python3-pil
"""

from pathlib import Path

def generate_background():
    try:
        from PIL import Image, ImageDraw, ImageFilter
        import random, math

        W, H = 1280, 720
        img = Image.new("RGB", (W, H))
        draw = ImageDraw.Draw(img)

        # 渐变：深蓝 → 浅蓝 → 橙粉（仿夕阳天空）
        for y in range(H):
            t = y / H
            if t < 0.5:
                # 深蓝 → 浅蓝
                r = int(40  + (135 - 40)  * (t / 0.5))
                g = int(80  + (180 - 80)  * (t / 0.5))
                b = int(160 + (210 - 160) * (t / 0.5))
            else:
                # 浅蓝 → 橙粉
                tt = (t - 0.5) / 0.5
                r = int(135 + (220 - 135) * tt)
                g = int(180 + (160 - 180) * tt)
                b = int(210 + (140 - 210) * tt)
            draw.line([(0, y), (W, y)], fill=(r, g, b))

        # 添加云朵（简单白色椭圆）
        for _ in range(6):
            cx = random.randint(100, W - 100)
            cy = random.randint(80, H // 2)
            for i in range(3):
                ox = random.randint(-60, 60)
                oy = random.randint(-20, 20)
                rw = random.randint(60, 120)
                rh = random.randint(25, 50)
                draw.ellipse(
                    [cx + ox - rw, cy + oy - rh, cx + ox + rw, cy + oy + rh],
                    fill=(255, 255, 255, 180)
                )

        img = img.filter(ImageFilter.GaussianBlur(radius=1))

        out = Path(__file__).parent / "background.jpg"
        img.save(out, "JPEG", quality=90)
        print(f"✅ 背景图已生成: {out}")
        return True

    except ImportError:
        print("⚠ 未安装 Pillow，跳过背景图生成")
        print("  可执行: sudo apt install python3-pil")
        return False


if __name__ == "__main__":
    generate_background()
