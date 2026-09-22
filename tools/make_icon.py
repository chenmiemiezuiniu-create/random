#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成六点骰子图标。

环境里没有 Pillow，所以这里用标准库（zlib + struct）手写 PNG，
再按 ICO 容器格式把多个尺寸打包成一个 .ico。超采样做抗锯齿。

用法：
    python tools/make_icon.py [输出路径]

默认输出 windows/runner/resources/app_icon.ico
"""

import os
import struct
import sys
import zlib

# 主题蓝，与应用主色一致
BG = (59, 111, 224)
PIP = (255, 255, 255)

# 两列 × 三行 = 六个点
PIPS = [
    (0.30, 0.235), (0.70, 0.235),
    (0.30, 0.500), (0.70, 0.500),
    (0.30, 0.765), (0.70, 0.765),
]
CORNER_R = 0.21

# 尺寸齐全，Windows 会在不同位置各取所需：
# 16 标题栏/任务栏小图标，32 桌面，48 中等图标，256 大图标/缩略图视图
SIZES = [16, 24, 32, 48, 64, 128, 256]


def _pip_radius(size):
    """小尺寸下把点放大一点，否则 16×16 时点会糊成一团看不见。"""
    return 0.105 if size < 48 else 0.085


def _supersample(size):
    """小图标需要更高的超采样才平滑。"""
    return 8 if size < 48 else 4


def render_rgba(size):
    """渲染成 PNG 需要的扫描行字节（每行前面一个过滤器字节 0）。"""
    ss = _supersample(size)
    big = size * ss
    pip_r = _pip_radius(size) * big
    corner = CORNER_R * big

    # 先把形状光栅化到 big×big 的位图（1 = 覆盖）
    inside = bytearray(big * big)
    pr2 = corner * corner
    for y in range(big):
        fy = y + 0.5
        cy = corner if fy < corner else (big - corner if fy > big - corner else fy)
        dy = fy - cy
        dy2 = dy * dy
        row = y * big
        for x in range(big):
            fx = x + 0.5
            cx = corner if fx < corner else (big - corner if fx > big - corner else fx)
            dx = fx - cx
            if dx * dx + dy2 <= pr2:
                inside[row + x] = 1

    pips = bytearray(big * big)
    r2 = pip_r * pip_r
    for nx, ny in PIPS:
        px, py = nx * big, ny * big
        x0 = max(0, int(px - pip_r) - 1)
        x1 = min(big, int(px + pip_r) + 2)
        y0 = max(0, int(py - pip_r) - 1)
        y1 = min(big, int(py + pip_r) + 2)
        for y in range(y0, y1):
            dy = y + 0.5 - py
            dy2 = dy * dy
            row = y * big
            for x in range(x0, x1):
                dx = x + 0.5 - px
                if dx * dx + dy2 <= r2:
                    pips[row + x] = 1

    # 盒式降采样
    total = ss * ss
    out = bytearray()
    for y in range(size):
        out.append(0)  # PNG 每行的过滤器类型
        for x in range(size):
            covered = 0
            dotted = 0
            for sy in range(ss):
                base = (y * ss + sy) * big + x * ss
                for sx in range(ss):
                    i = base + sx
                    if inside[i]:
                        covered += 1
                        if pips[i]:
                            dotted += 1
            if covered == 0:
                out += b'\x00\x00\x00\x00'
            else:
                alpha = int(round(255 * covered / total))
                t = dotted / covered
                out += bytes((
                    int(round(BG[0] * (1 - t) + PIP[0] * t)),
                    int(round(BG[1] * (1 - t) + PIP[1] * t)),
                    int(round(BG[2] * (1 - t) + PIP[2] * t)),
                    alpha,
                ))
    return bytes(out)


def _png_chunk(tag, data):
    return (struct.pack('>I', len(data)) + tag + data
            + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))


def png_bytes(size, scanlines):
    ihdr = struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0)  # 8bit RGBA
    return (b'\x89PNG\r\n\x1a\n'
            + _png_chunk(b'IHDR', ihdr)
            + _png_chunk(b'IDAT', zlib.compress(scanlines, 9))
            + _png_chunk(b'IEND', b''))


def ico_bytes(images):
    """images: [(size, png_bytes), ...]，按 ICO 容器格式打包。"""
    count = len(images)
    header = struct.pack('<HHH', 0, 1, count)
    offset = 6 + 16 * count
    entries = b''
    payload = b''
    for size, png in images:
        dim = 0 if size >= 256 else size  # 256 在 ICO 里记作 0
        entries += struct.pack('<BBBBHHII', dim, dim, 0, 0, 1, 32, len(png), offset)
        offset += len(png)
        payload += png
    return header + entries + payload


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = (sys.argv[1] if len(sys.argv) > 1
           else os.path.join(root, 'windows', 'runner', 'resources', 'app_icon.ico'))

    images = []
    for size in SIZES:
        images.append((size, png_bytes(size, render_rgba(size))))
        print('  渲染 %3d×%-3d  %6d 字节' % (size, size, len(images[-1][1])))

    data = ico_bytes(images)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'wb') as f:
        f.write(data)
    print('已生成 %s（%d 字节，含 %d 个尺寸）' % (out, len(data), len(SIZES)))


if __name__ == '__main__':
    main()
