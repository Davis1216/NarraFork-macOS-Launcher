import math, os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

def create_bg(scale, out_path):
    W, H = 1400 * scale, 800 * scale
    V_W, V_H = 660 * scale, 460 * scale
    cx = 330 * scale

    # 1. Base dark obsidian background with subtle gradient
    bg = Image.new('RGBA', (W, H), (12, 14, 18, 255))
    gdraw = ImageDraw.Draw(bg)
    for y in range(H):
        t = min(1.0, y / (460 * scale))
        r = int(24 * (1 - t) + 12 * t)
        g = int(30 * (1 - t) + 14 * t)
        b = int(40 * (1 - t) + 18 * t)
        gdraw.line([(0, y), (W, y)], fill=(r, g, b, 255))

    # 2. Ambient light glows (centered in viewport)
    glow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_draw.ellipse([cx - 140 * scale, 110 * scale, cx + 140 * scale, 240 * scale], fill=(30, 168, 196, 30))
    glow_draw.ellipse([160 * scale - 90 * scale, 175 * scale - 90 * scale, 160 * scale + 90 * scale, 175 * scale + 90 * scale], fill=(21, 80, 120, 25))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=40 * scale))
    bg = Image.alpha_composite(bg, glow)

    draw = ImageDraw.Draw(bg)

    # 3. Modern Arrow between NarraFork and Applications
    arrow_y = 175 * scale
    ax_start = 250 * scale
    ax_end = 410 * scale

    dot_step = 9 * scale
    for x in range(ax_start, ax_end - 20 * scale, dot_step):
        t = (x - ax_start) / (ax_end - ax_start)
        alpha = int(70 + 180 * t)
        draw.ellipse([x, arrow_y - 2 * scale, x + 4 * scale, arrow_y + 2 * scale], fill=(32, 180, 210, alpha))

    head_tip = ax_end
    head_w = 13 * scale
    head_h = 12 * scale
    pts = [
        (head_tip - head_w, arrow_y - head_h),
        (head_tip, arrow_y),
        (head_tip - head_w, arrow_y + head_h),
        (head_tip - head_w + 5 * scale, arrow_y + head_h),
        (head_tip + 5 * scale, arrow_y),
        (head_tip - head_w + 5 * scale, arrow_y - head_h),
    ]
    draw.polygon(pts, fill=(32, 200, 230, 255))

    # 4. Typography
    font_path = '/System/Library/Fonts/STHeiti Medium.ttc'
    font_title = ImageFont.truetype(font_path, 16 * scale)
    font_sub = ImageFont.truetype(font_path, 10 * scale)
    font_card = ImageFont.truetype(font_path, 9 * scale)

    title = '拖拽 NarraFork 到 Applications 文件夹'
    sub = '原生 macOS 客户端 • 独立安全沙箱 • 开箱即用'

    bbox_t = draw.textbbox((0, 0), title, font=font_title)
    draw.text((cx - (bbox_t[2] - bbox_t[0]) // 2, 40 * scale), title, fill=(240, 246, 252, 255), font=font_title)

    bbox_s = draw.textbbox((0, 0), sub, font=font_sub)
    draw.text((cx - (bbox_s[2] - bbox_s[0]) // 2, 67 * scale), sub, fill=(139, 148, 158, 255), font=font_sub)

    # 5. Contrast Frosted Pills for Icon Labels (彻底解决 macOS 访达强制黑字看不清的问题)
    # (center_x, center_y, width, height) in points
    # NarraFork label: 160, 246, width ~70, pill 100x22
    # Applications label: 500, 246, width ~82, pill 118x22
    # 安装使用必读.txt label: 330, 381.5, width ~138, pill 160x22
    pills = [
        (int(160 * scale), int(246 * scale), int(100 * scale), int(22 * scale)),
        (int(500 * scale), int(246 * scale), int(118 * scale), int(22 * scale)),
        (int(330 * scale), int(381.5 * scale), int(160 * scale), int(22 * scale)),
    ]

    # Subtle drop shadow behind each pill
    shadow_layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shadow_layer)
    for px, py, pw, ph in pills:
        x0 = px - pw // 2
        y0 = py - ph // 2 + 1 * scale
        sdraw.rounded_rectangle([x0, y0, x0 + pw, y0 + ph], radius=ph // 2, fill=(0, 0, 0, 100))
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(radius=3 * scale))
    bg = Image.alpha_composite(bg, shadow_layer)

    # High-contrast frosted glass pill (Apple Chip design)
    pill_layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    pdraw = ImageDraw.Draw(pill_layer)
    for px, py, pw, ph in pills:
        x0 = px - pw // 2
        y0 = py - ph // 2
        # Frosted titanium light surface with bright edge
        pdraw.rounded_rectangle(
            [x0, y0, x0 + pw, y0 + ph],
            radius=ph // 2,
            fill=(242, 246, 250, 238),
            outline=(255, 255, 255, 190),
            width=max(1, int(1 * scale))
        )

    bg = Image.alpha_composite(bg, pill_layer)
    draw = ImageDraw.Draw(bg)

    # 6. Bottom Capsule Card
    card_layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    cdraw = ImageDraw.Draw(card_layer)

    card_w = 490 * scale
    card_h = 26 * scale
    cx0 = cx - card_w // 2
    cy0 = 406 * scale
    cx1 = cx0 + card_w
    cy1 = cy0 + card_h

    cdraw.rounded_rectangle([cx0, cy0, cx1, cy1], radius=13 * scale, fill=(255, 255, 255, 14), outline=(255, 255, 255, 38), width=1 * scale)
    bg = Image.alpha_composite(bg, card_layer)
    draw = ImageDraw.Draw(bg)

    hint_text = '首次打开若提示「无法验证开发者」：请在「应用程序」中右键点击 App 选择「打开」'
    bbox_h = draw.textbbox((0, 0), hint_text, font=font_card)

    badge_x = cx0 + 18 * scale
    badge_y = cy0 + card_h // 2
    r_badge = 5.5 * scale
    draw.ellipse([badge_x - r_badge, badge_y - r_badge, badge_x + r_badge, badge_y + r_badge], fill=(32, 180, 210, 255))
    draw.text((badge_x - 2 * scale, badge_y - 6 * scale), 'i', fill=(16, 20, 26, 255), font=font_card)

    draw.text((badge_x + 11 * scale, cy0 + (card_h - (bbox_h[3] - bbox_h[1])) // 2 - 1 * scale), hint_text, fill=(215, 222, 230, 255), font=font_card)

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    bg.save(out_path)
    print(f'Generated: {out_path} ({W}x{H})')

if __name__ == '__main__':
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    assets_dir = os.path.join(base_dir, 'assets')
    create_bg(1, os.path.join(assets_dir, 'dmg_background.png'))
    create_bg(2, os.path.join(assets_dir, 'dmg_background@2x.png'))
