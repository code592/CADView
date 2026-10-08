"""Generate a deterministic stress file, NOT a downloaded/real drawing.

Only the output under artifacts/ is generated; no production assets change.
Usage: python3 scripts/generate_performance_dxf.py [entity_count]
"""
from pathlib import Path
import sys

count = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000_000
if not 1 <= count <= 5_000_000:
    raise SystemExit("entity_count must be between 1 and 5,000,000")
target = Path(__file__).resolve().parent.parent / "artifacts/qa/performance" / f"synthetic-{count}.dxf"
target.parent.mkdir(parents=True, exist_ok=True)
with target.open("w", encoding="ascii", newline="\n") as output:
    output.write("0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1015\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n")
    for index in range(count):
        x, y = (index % 1000) * 10, (index // 1000) * 10
        output.write(f"0\nLINE\n5\n{index + 256:X}\n100\nAcDbEntity\n8\n0\n100\nAcDbLine\n10\n{x}.0\n20\n{y}.0\n30\n0.0\n11\n{x + 4}.0\n21\n{y}.0\n31\n0.0\n")
    output.write("0\nENDSEC\n0\nEOF\n")
print(f"{target}: {target.stat().st_size:,} bytes; {count:,} LINE entities")
