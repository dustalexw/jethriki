#!/usr/bin/env python3
"""Recompiles FFmpeg's ffmpeg and ffprobe tools as library objects that run inside the app.

Run after a normal `make V=1` of FFmpeg whose output was saved to a log. The log gives the exact compile
command for every fftools object (with the cross compiler and flags of that build) and the objects each
tool links. Each object is compiled again with jt_force.h force-included; ffmpeg.c is replaced by
jt_ffmpeg_wrap.c and the tools' main() functions are renamed. ffprobe shares helper sources with ffmpeg,
so every global symbol its objects define gets a `jtp_` prefix, letting both tools live in one library.

Writes the objects, plus jt_tools.o, to OUT and prints their paths, one per line.

    build_fftools.py --build BUILD_DIR --log make.log --out OUT
"""
import argparse, os, re, shlex, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def run(cmd, cwd):
    result = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if result.returncode != 0:
        sys.exit(f"command failed in {cwd}:\n{shlex.join(cmd)}\n{result.stdout}")
    return result.stdout


def parse_log(path):
    """Compile commands by object path, and the fftools objects each tool links."""
    compiles, links = {}, {}
    for line in open(path, errors="replace"):
        line = line.strip()
        if not line or line.startswith(("make", "CC\t", "AR\t", "LD\t")):
            continue
        try:
            tokens = shlex.split(line)
        except ValueError:
            continue
        if "-c" in tokens and "-o" in tokens:
            obj = tokens[tokens.index("-o") + 1]
            if obj.startswith(("fftools/", "compat/")) and obj.endswith(".o"):
                compiles[obj] = tokens
        elif "-o" in tokens:
            target = tokens[tokens.index("-o") + 1]
            for tool in ("ffmpeg", "ffprobe"):
                if target in (f"{tool}_g", f"{tool}_g.exe"):
                    links[tool] = [t for t in tokens if t.endswith(".o") and t.startswith(("fftools/", "compat/"))]
    for tool in ("ffmpeg", "ffprobe"):
        if tool not in links:
            sys.exit(f"no link command for {tool}_g in the log; build FFmpeg with `make V=1` and --enable-{tool}")
        missing = [o for o in links[tool] if o not in compiles]
        if missing:
            sys.exit(f"no compile command for {missing} in the log")
    return compiles, links


def recompile(tokens, obj, out_obj, extra, source=None):
    cmd = list(tokens)
    # Drop dependency-file generation: it writes next to the original object.
    cleaned, skip = [], 0
    for i, t in enumerate(cmd):
        if skip:
            skip -= 1
            continue
        if t in ("-MF", "-MT", "-MQ"):
            skip = 1
            continue
        if t in ("-MMD", "-MD", "-MP"):
            continue
        cleaned.append(t)
    cmd = cleaned
    cmd[cmd.index("-o") + 1] = out_obj
    if source:
        sources = [i for i, t in enumerate(cmd) if t.endswith(".c")]
        cmd[sources[-1]] = source
    c = cmd.index("-c")
    return cmd[:c] + extra + cmd[c:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--nm", default="nm")
    args = ap.parse_args()
    build, out = os.path.abspath(args.build), os.path.abspath(args.out)
    compiles, links = parse_log(args.log)
    force = ["-include", os.path.join(HERE, "jt_force.h")]

    objects = []
    for tool in ("ffmpeg", "ffprobe"):
        tool_dir = os.path.join(out, tool)
        os.makedirs(tool_dir, exist_ok=True)

        def build_set(extra):
            built = []
            for obj in links[tool]:
                target = os.path.join(tool_dir, obj.replace("/", "__"))
                flags, source = force + extra, None
                if obj == f"fftools/{tool}.o":
                    flags = flags + [f"-Dmain=jt_{tool}_main"]
                    if tool == "ffmpeg":
                        source = os.path.join(HERE, "jt_ffmpeg_wrap.c")
                run(recompile(compiles[obj], obj, target, flags, source), build)
                built.append(target)
            return built

        built = build_set([])
        if tool == "ffprobe":
            # Rename every global ffprobe's objects define, so they can't clash with ffmpeg's copies.
            listing = run([args.nm, "-g", "--defined-only", "-j"] + built, build)
            with open(built[0], "rb") as f:
                macho = f.read(4) in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf")   # C names carry a leading _
            names = set()
            for line in listing.splitlines():
                name = line.strip()
                if not name or name.endswith(":"):
                    continue
                if macho and name.startswith("_"):
                    name = name[1:]
                if name.startswith("jt_"):
                    continue
                names.add(name)
            header = os.path.join(tool_dir, "jt_rename.h")
            with open(header, "w") as f:
                f.write("/* Generated by build_fftools.py: ffprobe's own copies of the shared fftools globals. */\n")
                for name in sorted(names):
                    f.write(f"#define {name} jtp_{name}\n")
            built = build_set(["-include", header])
        objects += built

    # jt_tools.c itself, compiled like any libavutil source so it finds the headers.
    template = next(t for o, t in compiles.items() if o == "fftools/cmdutils.o")
    target = os.path.join(out, "jt_tools.o")
    run(recompile(template, "fftools/cmdutils.o", target, ["-I" + HERE], os.path.join(HERE, "jt_tools.c")), build)
    objects.append(target)
    print("\n".join(objects))


if __name__ == "__main__":
    main()
