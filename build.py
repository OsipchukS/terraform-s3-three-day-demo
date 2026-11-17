"""Build a reproducible Lambda ZIP using only the Python standard library."""
from pathlib import Path
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED

root = Path(__file__).resolve().parent
info = ZipInfo("cleanup.py", date_time=(2026, 1, 1, 0, 0, 0))
info.compress_type = ZIP_DEFLATED
info.external_attr = 0o644 << 16
with ZipFile(root / "lambda" / "cleanup.zip", "w") as archive:
    archive.writestr(info, (root / "lambda" / "cleanup.py").read_bytes())
print("Lambda ZIP built")
