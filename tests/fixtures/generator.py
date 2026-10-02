"""
Daylight Drop Test Fixture Generator
Generates deterministic test payloads, binary files, mock screenshots, and edge-case text inputs.
"""

import os
import struct
import zlib
import hashlib
import uuid
from typing import Dict, Any, Tuple


def generate_png_bytes(width: int = 100, height: int = 100, grayscale_level: int = 255) -> bytes:
    """Generate minimal valid 8-bit grayscale PNG bytes."""
    header = b'\x89PNG\r\n\x1a\n'
    # IHDR chunk: width, height, bit depth (8), color type (0=grayscale), compression (0), filter (0), interlace (0)
    ihdr_data = struct.pack('>IIBBBBB', width, height, 8, 0, 0, 0, 0)
    ihdr_crc = struct.pack('>I', zlib.crc32(b'IHDR' + ihdr_data))
    ihdr_chunk = struct.pack('>I', len(ihdr_data)) + b'IHDR' + ihdr_data + ihdr_crc

    # IDAT chunk: raw image data (height rows, each starting with filter byte 0x00)
    raw_scanlines = bytearray()
    for _ in range(height):
        raw_scanlines.append(0)  # filter type None
        raw_scanlines.extend([grayscale_level] * width)
    
    compressed_data = zlib.compress(bytes(raw_scanlines))
    idat_crc = struct.pack('>I', zlib.crc32(b'IDAT' + compressed_data))
    idat_chunk = struct.pack('>I', len(compressed_data)) + b'IDAT' + compressed_data + idat_crc

    # IEND chunk
    iend_data = b''
    iend_crc = struct.pack('>I', zlib.crc32(b'IEND' + iend_data))
    iend_chunk = struct.pack('>I', len(iend_data)) + b'IEND' + iend_data + iend_crc

    return header + ihdr_chunk + idat_chunk + iend_chunk


def generate_pdf_bytes(title: str = "Test Note", text: str = "Daylight Drop Test Document") -> bytes:
    """Generate minimal valid PDF binary bytes."""
    content = f"""%PDF-1.4
1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj
4 0 obj << /Length {len(text) + 40} >> stream
BT
/F1 14 Tf
72 712 Td
({text}) Tj
ET
endstream endobj
5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj
xref
0 6
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
0000000244 00000 n 
0000000350 00000 n 
trailer << /Size 6 /Root 1 0 R >>
startxref
427
%%EOF
"""
    return content.encode('utf-8')


def generate_payload(size_bytes: int, fill_byte: int = 0xAA) -> bytes:
    """Generate arbitrary byte payload for boundary/throughput testing."""
    return bytes([fill_byte]) * size_bytes


def sha256_hex(data: bytes) -> str:
    """Calculate hex SHA-256 digest of bytes."""
    return hashlib.sha256(data).hexdigest()


SAMPLE_PROMPTS = {
    "short": "Explain the Zero-EPD architecture on Daylight DC1.",
    "multiline": """Review the following Swift code for Carbon hotkey registration:
func registerGlobalHotkey() {
    var hotKeyID = EventHotKeyID(signature: 0x444C4450, id: 1)
    RegisterEventHotKey(kVK_ANSI_D, UInt32(cmdKey | shiftKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
}
Does this require macOS Accessibility permissions?""",
    "code": """def calculate_contrast(l1, l2):
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)""",
    "unicode_emojis": "Daylight Drop ☀️📲💻 Sync screenshot ⚡️ LivePaper 🌿",
    "rtl_arabic": "مزامنة الشاشة الفورية عبر ضوء النهار",
    "rtl_hebrew": "סנכרון תמונות מסך מיידי של דיילייט",
    "special_chars": "<test>&\"'/%$#@!*()[]{}|\\^~`\r\n\t",
    "null_and_control": "Daylight\x00Drop\x01Test\x1b[31mColor\x1b[0m",
}
