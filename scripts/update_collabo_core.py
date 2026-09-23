#!/usr/bin/env python3
"""collaboCore 를 collabo_ide 로 들여온다 — Dart 패키지와 플랫폼별 런타임.

    python3 scripts/update_collabo_core.py            # 바뀐 것만 들인다
    python3 scripts/update_collabo_core.py --check    # 무엇이 바뀔지만 본다(아무것도 안 쓴다)
    python3 scripts/update_collabo_core.py --only runtime --platform win-x64
    python3 scripts/update_collabo_core.py --config other.json

설정은 scripts/collabo_core_update.json (경로는 그 파일 기준 상대 경로). 둘은 짝이다 —
note.md §15 "들여온 것" 의 표가 이 스크립트가 하는 일이다.

런타임은 **검증한 것만** 들인다:
  - release 압축본: dist/release/SHA256SUMS 에 있으면 대조(다르면 중단). Mac·Windows 릴리스를 따로
    만들면 나중 것이 SHA256SUMS 를 덮어써 앞의 것이 빠진다 — 그때는 경고만 하고 manifest 로 넘어간다.
  - 그리고 항상: 풀어 놓은 것의 파일 전부를 manifest.json 의 해시와 대조(하나라도 다르면 중단).
지금 들어 있는 것과 manifest 가 같으면 건드리지 않는다.

표준 라이브러리만 쓴다(Windows 의 python, macOS 의 python3 어디서나).
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import shutil
import stat
import sys
import tarfile
import tempfile
import time
import zipfile
from pathlib import Path

DEFAULT_CONFIG = Path(__file__).resolve().parent / "collabo_core_update.json"


class UpdateError(Exception):
    pass


# ---------------------------------------------------------------- 공통


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def rel(path: Path, base: Path) -> str:
    try:
        return str(path.relative_to(base))
    except ValueError:
        return str(path)


def excluded(name: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatch(name, p) for p in patterns)


def files_under(root: Path, exclude: list[str]) -> dict[str, Path]:
    """root 아래 파일들 (상대 경로 '/' 구분 → 절대 경로). 제외 패턴은 경로의 어느 조각에든 건다."""
    out: dict[str, Path] = {}
    if not root.is_dir():
        return out
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not excluded(d, exclude)]
        for fn in filenames:
            if excluded(fn, exclude):
                continue
            p = Path(dirpath) / fn
            out[p.relative_to(root).as_posix()] = p
    return out


def remove_tree(path: Path) -> None:
    def onerror(func, p, _exc):  # 읽기 전용 파일(Windows) — 쓰기 가능으로 바꾸고 다시
        os.chmod(p, stat.S_IWRITE)
        func(p)

    if path.exists():
        shutil.rmtree(path, onerror=onerror)


# ---------------------------------------------------------------- Dart 패키지


def update_package(cfg: dict, core: Path, base: Path, check: bool) -> bool:
    pkg = cfg["package"]
    src = (core / pkg["from"]).resolve()
    dst = (base / pkg["to"]).resolve()
    exclude = pkg.get("exclude", [])
    if not (src / "pubspec.yaml").is_file():
        raise UpdateError(f"Dart 패키지가 아니다(pubspec.yaml 없음): {src}")

    new = files_under(src, exclude)
    old = files_under(dst, exclude)
    added = sorted(set(new) - set(old))
    removed = sorted(set(old) - set(new))
    changed = sorted(k for k in set(new) & set(old) if sha256(new[k]) != sha256(old[k]))

    print(f"[package] {rel(src, core.parent)} → {dst}")
    if not (added or removed or changed):
        print("  같다 — 건너뜀")
        return False
    for tag, names in (("+", added), ("~", changed), ("-", removed)):
        for n in names:
            print(f"  {tag} {n}")
    if check:
        return True

    for n in added + changed:
        target = dst / n
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(new[n], target)
    for n in removed:
        old[n].unlink()
    # 비게 된 폴더 정리(제외 폴더는 건드리지 않는다).
    for dirpath, _dirs, _files in sorted(os.walk(dst), key=lambda t: -len(t[0])):
        d = Path(dirpath)
        if d != dst and not any(d.iterdir()) and not excluded(d.name, exclude):
            d.rmdir()
    print(f"  반영: +{len(added)} ~{len(changed)} -{len(removed)}")
    return True


# ---------------------------------------------------------------- 런타임


def read_sums(path: Path) -> dict[str, str]:
    sums: dict[str, str] = {}
    if not path.is_file():
        return sums
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) >= 2:
            sums[os.path.basename(parts[-1].lstrip("*"))] = parts[0].lower()
    return sums


def find_release_archive(release_dir: Path, platform: str) -> Path | None:
    for ext in (".zip", ".tar.gz", ".tgz"):
        p = release_dir / f"collabo-core-{platform}{ext}"
        if p.is_file():
            return p
    return None


def extract(archive: Path, into: Path) -> None:
    # 빌드가 도는 중이면 압축본이 아직 쓰이는 중일 수 있다 — 깨진 것으로 보이면 이유와 함께 멈춘다.
    try:
        _extract(archive, into)
    except (zipfile.BadZipFile, tarfile.TarError, EOFError, OSError) as e:
        age = time.time() - archive.stat().st_mtime
        hint = " — 방금 바뀐 파일이다(릴리스를 만드는 중이면 끝난 뒤 다시)" if age < 120 else ""
        raise UpdateError(f"{archive.name} 을 풀 수 없다: {e}{hint}")


def _extract(archive: Path, into: Path) -> None:
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as z:
            z.extractall(into)
            # zip 은 실행 비트를 안 살린다 — unix 에서는 권한 정보(외부 속성)대로 되돌린다.
            if os.name != "nt":
                for info in z.infolist():
                    mode = info.external_attr >> 16
                    if mode:
                        os.chmod(into / info.filename, mode & 0o7777)
    else:
        with tarfile.open(archive) as t:
            for m in t.getmembers():  # 압축본 밖으로 나가는 경로는 받지 않는다
                target = (into / m.name).resolve()
                if not str(target).startswith(str(into.resolve())):
                    raise UpdateError(f"압축본에 밖을 가리키는 경로: {m.name}")
            if hasattr(tarfile, "data_filter"):  # 3.12+: 링크·권한까지 안전하게(실행 비트는 남는다)
                t.extractall(into, filter="data")
            else:
                t.extractall(into)


def runtime_root(extracted: Path, platform: str) -> Path:
    direct = extracted / f"collabo-core-{platform}"
    if (direct / "manifest.json").is_file():
        return direct
    if (extracted / "manifest.json").is_file():
        return extracted
    for m in extracted.rglob("manifest.json"):
        return m.parent
    raise UpdateError(f"압축본 안에 manifest.json 이 없다: {platform}")


def load_manifest(root: Path) -> dict:
    try:
        return json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise UpdateError(f"manifest.json 을 못 읽는다: {root} ({e})")


def verify_manifest(root: Path, platform: str) -> dict:
    m = load_manifest(root)
    if m.get("platform") != platform:
        raise UpdateError(f"{root}: manifest 의 platform 이 {m.get('platform')!r} (기대 {platform!r})")
    files = m.get("files") or {}
    if not files:
        raise UpdateError(f"{root}: manifest 에 files 가 없다")
    bad = [n for n, h in files.items() if not (root / n).is_file() or sha256(root / n) != h.lower()]
    if bad:
        raise UpdateError(f"{platform}: manifest 와 다른 파일 {len(bad)}개 — " + ", ".join(bad[:5]))
    return m


def same_runtime(dst: Path, manifest: dict) -> bool:
    if not (dst / "manifest.json").is_file():
        return False
    try:
        cur = load_manifest(dst)
    except UpdateError:
        return False
    if cur.get("files") != manifest.get("files") or cur.get("entry") != manifest.get("entry"):
        return False
    # manifest 가 같아도 파일이 빠졌거나 바뀌었으면 다시 들인다.
    return all((dst / n).is_file() and sha256(dst / n) == h.lower() for n, h in manifest["files"].items())


def install_runtime(src_root: Path, dst: Path) -> None:
    tmp = dst.with_name(dst.name + ".updating")
    remove_tree(tmp)
    shutil.copytree(src_root, tmp)
    if os.name != "nt":
        for engine in (tmp / "bin").glob("*"):
            engine.chmod(engine.stat().st_mode | 0o111)
    remove_tree(dst)
    tmp.rename(dst)


def update_runtime(cfg: dict, core: Path, base: Path, platform: str, check: bool, work: Path) -> bool:
    rt = cfg["runtimes"]
    dst_root = (base / rt["to"]).resolve()
    dst = dst_root / f"collabo-core-{platform}"
    release_dir = core / rt.get("release_dir", "dist/release")
    runtime_dir = core / rt.get("runtime_dir", "dist/runtime")
    sums = read_sums(release_dir / "SHA256SUMS")
    print(f"[runtime {platform}]")

    src_root: Path | None = None
    origin = ""
    for kind in rt.get("sources", ["release", "runtime"]):
        if kind == "release":
            archive = find_release_archive(release_dir, platform)
            if archive is None:
                continue
            expected = sums.get(archive.name)
            if expected is None:
                print(f"  ! {archive.name} 이 SHA256SUMS 에 없다(다른 플랫폼 릴리스가 덮어썼을 수 있다) — manifest 로만 검증")
            elif sha256(archive) != expected:
                raise UpdateError(f"{archive.name}: SHA256SUMS 와 다르다")
            into = work / platform
            into.mkdir(parents=True)
            extract(archive, into)
            src_root = runtime_root(into, platform)
            origin = f"{rel(archive, core.parent)}{'' if expected is None else ' (SHA256SUMS 일치)'}"
            break
        if kind == "runtime":
            d = runtime_dir / f"collabo-core-{platform}"
            if (d / "manifest.json").is_file():
                src_root, origin = d, rel(d, core.parent)
                break
        elif kind != "release":
            raise UpdateError(f"알 수 없는 sources 항목: {kind!r}")

    if src_root is None:
        print("  CollaboCore 에 이 플랫폼 런타임이 없다 — 건너뜀(지금 것 유지)")
        return False
    manifest = verify_manifest(src_root, platform)
    print(f"  원본: {origin} — manifest 파일 {len(manifest['files'])}개 해시 일치")
    if same_runtime(dst, manifest):
        print("  지금 들어 있는 것과 같다 — 건너뜀")
        return False
    tools = "--tools-image" in manifest.get("entry", [])
    print(f"  → {dst}  (tools 이미지 {'있음' if tools else '없음'})")
    if not check:
        install_runtime(src_root, dst)
        verify_manifest(dst, platform)
        print("  반영(들인 뒤 다시 검증함)")
    return True


def update_version(cfg: dict, core: Path, base: Path, check: bool) -> bool:
    rt = cfg["runtimes"]
    src = core / rt.get("version_file", "dist/release/VERSION")
    dst = (base / rt["to"]).resolve() / "VERSION"
    if not src.is_file():
        return False
    if dst.is_file() and sha256(src) == sha256(dst):
        return False
    print(f"[VERSION] {rel(src, core.parent)} → {dst}")
    if not check:
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
    return True


# ---------------------------------------------------------------- main


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="collaboCore(Dart 패키지·런타임)를 collabo_ide 로 들여온다.")
    ap.add_argument("--config", type=Path, default=DEFAULT_CONFIG, help="설정 JSON (기본: scripts/collabo_core_update.json)")
    ap.add_argument("--check", action="store_true", help="바뀔 것만 보여 주고 아무것도 쓰지 않는다")
    ap.add_argument("--only", choices=["package", "runtime"], help="한쪽만")
    ap.add_argument("--platform", action="append", help="이 플랫폼만(여러 번 가능). 기본: 설정의 platforms")
    args = ap.parse_args(argv)

    cfg_path = args.config.resolve()
    try:
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        print(f"설정을 못 읽는다: {cfg_path} ({e})", file=sys.stderr)
        return 2
    base = cfg_path.parent
    core = (base / cfg["collabo_core"]).resolve()
    if not core.is_dir():
        print(f"CollaboCore 가 없다: {core}  (설정의 collabo_core 를 확인)", file=sys.stderr)
        return 2
    print(f"CollaboCore: {core}{'   [--check: 쓰지 않음]' if args.check else ''}")

    changed = False
    try:
        if args.only in (None, "package"):
            changed |= update_package(cfg, core, base, args.check)
        if args.only in (None, "runtime"):
            platforms = args.platform or cfg["runtimes"]["platforms"]
            with tempfile.TemporaryDirectory(prefix="collabo-core-update-") as work:
                for plat in platforms:
                    changed |= update_runtime(cfg, core, base, plat, args.check, Path(work))
            changed |= update_version(cfg, core, base, args.check)
    except UpdateError as e:
        print(f"중단: {e}", file=sys.stderr)
        return 1

    if not changed:
        print("바뀐 것 없음.")
    elif args.check:
        print("(--check) 위 내용이 바뀐다. 들이려면 --check 없이 다시.")
    else:
        print("끝. 확인: flutter test test/collabo_core_runtime_test.dart test/sandbox_executor_test.dart"
              "  (Z:\\ 공유 폴더면 로컬 복사본에서)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
