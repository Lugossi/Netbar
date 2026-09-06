#!/usr/bin/env python3

import argparse
import json
import os
import re
import subprocess
import sys
import time

CLK_TCK = os.sysconf("SC_CLK_TCK") or 100
SELF_UID = os.getuid()

DESKTOP_APPS = {
    "firefox", "chrome", "chromium", "brave", "vivaldi", "opera", "zen",
    "thunderbird", "discord", "slack", "spotify", "steam", "signal-desktop",
    "telegram-desktop", "element-desktop", "obs", "kdeconnectd", "syncthing",
    "dropbox", "code", "codium", "cursor", "zoom", "teams", "1password",
    "keybase", "nextcloud", "insync", "megasync", "tailscaled", "warp",
}

KIND_RULES = [
    (r"\bvite\b", "vite"),
    (r"\bnext(-server|\b)", "next"),
    (r"\bnuxt\b", "nuxt"),
    (r"\bwebpack\b", "webpack"),
    (r"\bstorybook\b", "storybook"),
    (r"\bnodemon\b", "nodemon"),
    (r"\bastro\b", "astro"),
    (r"\besbuild\b", "esbuild"),
    (r"\bng\b.*\bserve\b", "angular"),
    (r"\bbun\b", "bun"),
    (r"\bdeno\b", "deno"),
    (r"\bnode\b|\bnpm\b|\bpnpm\b|\byarn\b", "node"),
    (r"\buvicorn\b|\bgunicorn\b|\bhypercorn\b", "python"),
    (r"\bflask\b|\bdjango\b|manage\.py", "django"),
    (r"\bpython[0-9.]*\b", "python"),
    (r"\bpuma\b|\brails\b|\bruby\b", "ruby"),
    (r"\bphp\b|\bartisan\b", "php"),
    (r"\bjava\b|\bgradle\b|\bmaven\b|\bkotlin\b", "java"),
    (r"\bdotnet\b", "dotnet"),
    (r"\bcargo\b|\brustc\b", "rust"),
    (r"\bair\b|\bgo\b|\bgin\b", "go"),
    (r"\bmix\b|\bbeam\b|\bphoenix\b", "elixir"),
    (r"postgres", "postgres"),
    (r"\bmysqld\b|\bmariadb", "mysql"),
    (r"redis", "redis"),
    (r"mongod", "mongo"),
    (r"docker-proxy|containerd|dockerd", "docker"),
    (r"\bnginx\b|\bcaddy\b|\bapache\b|httpd", "webserver"),
    (r"\bssh\b|sshd", "ssh"),
]

PROC_RE = re.compile(r'\("([^"]+)",pid=(\d+)')

WELL_KNOWN_PORTS = {
    22: "SSH", 25: "SMTP", 53: "DNS", 67: "DHCP", 80: "HTTP", 111: "rpcbind",
    123: "NTP", 139: "NetBIOS", 143: "IMAP", 161: "SNMP", 323: "chrony",
    443: "HTTPS", 445: "SMB", 465: "SMTPS", 587: "SMTP", 631: "CUPS/IPP",
    993: "IMAPS", 995: "POP3S", 1900: "SSDP", 3306: "MySQL", 3389: "RDP",
    5353: "mDNS", 5355: "LLMNR", 5432: "PostgreSQL", 6379: "Redis",
    8080: "HTTP alt", 8443: "HTTPS alt", 11211: "memcached", 27017: "MongoDB",
}

def username_for(uid):
    if uid is None or uid < 0:
        return ""
    try:
        import pwd
        return pwd.getpwuid(uid).pw_name
    except (KeyError, ImportError):
        return "uid %d" % uid

def socket_uids():
    out = {}
    sources = (
        ("tcp", "/proc/net/tcp"), ("tcp", "/proc/net/tcp6"),
        ("udp", "/proc/net/udp"), ("udp", "/proc/net/udp6"),
    )
    for proto, path in sources:
        lines = read_text(path).splitlines()
        for line in lines[1:]:
            fields = line.split()
            if len(fields) < 10:
                continue
            if proto == "tcp" and fields[3] != "0A":
                continue
            try:
                port = int(fields[1].rsplit(":", 1)[1], 16)
                uid = int(fields[7])
            except (ValueError, IndexError):
                continue
            out.setdefault((proto, port), uid)
    return out

def run(cmd, timeout=4):
    try:
        out = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=False
        )
        return out.stdout or ""
    except (OSError, subprocess.SubprocessError):
        return ""

def split_hostport(addr):
    if ":" not in addr:
        return addr, 0
    host, _, port = addr.rpartition(":")
    host = host.strip("[]")
    host = host.split("%", 1)[0]
    try:
        return host, int(port)
    except ValueError:
        return host, 0

def exposure_for(host):
    if host in ("127.0.0.1", "::1") or host.startswith("127."):
        return "local"
    if host in ("0.0.0.0", "::", "*", ""):
        return "all"
    return "iface"

def friendly_name(comm, cmdline):
    comm = str(comm or "")
    if not cmdline:
        return comm
    argv0 = os.path.basename(cmdline.split(" ")[0])
    if argv0 and comm.startswith(argv0[:15]):
        return argv0
    return comm

def classify(name, cmdline):
    hay = (name + " " + cmdline).lower()
    for pattern, kind in KIND_RULES:
        if re.search(pattern, hay):
            return kind
    return "other"

def read_text(path):
    try:
        with open(path, "r", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""

def boot_uptime():
    raw = read_text("/proc/uptime").split()
    try:
        return float(raw[0])
    except (IndexError, ValueError):
        return 0.0

def proc_info(pid, uptime_now):
    info = {
        "cmdline": "",
        "cwd": "",
        "project": "",
        "uptimeSec": -1,
        "uid": -1,
        "owned": False,
        "exe": "",
    }
    raw_cmd = read_text("/proc/%d/cmdline" % pid)
    if raw_cmd:
        info["cmdline"] = " ".join(p for p in raw_cmd.split("\0") if p).strip()

    for line in read_text("/proc/%d/status" % pid).splitlines():
        if line.startswith("Uid:"):
            parts = line.split()
            if len(parts) > 1:
                try:
                    info["uid"] = int(parts[1])
                except ValueError:
                    pass
            break
    info["owned"] = info["uid"] == SELF_UID

    try:
        info["cwd"] = os.readlink("/proc/%d/cwd" % pid)
    except OSError:
        pass
    try:
        info["exe"] = os.readlink("/proc/%d/exe" % pid)
    except OSError:
        pass
    if info["cwd"]:
        info["project"] = project_name(info["cwd"])

    stat = read_text("/proc/%d/stat" % pid)
    close = stat.rfind(")")
    if close != -1:
        fields = stat[close + 2:].split()
        if len(fields) >= 20:
            try:
                started = float(fields[19]) / CLK_TCK
                info["uptimeSec"] = max(0, int(uptime_now - started))
            except ValueError:
                pass
    return info

def project_name(cwd):
    home = os.path.expanduser("~")
    path = cwd
    best = os.path.basename(cwd) or cwd
    for _ in range(8):
        if not path or path == "/" or path == home:
            break
        for marker in (".git", "package.json", "Cargo.toml", "go.mod",
                       "pyproject.toml", "Gemfile", "composer.json"):
            if os.path.exists(os.path.join(path, marker)):
                best = os.path.basename(path)
                return best
        path = os.path.dirname(path)
    return best

def established_counts():
    counts = {}
    for line in run(["ss", "-H", "-tn", "state", "established"]).splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        _, port = split_hostport(parts[2])
        if port:
            counts[port] = counts.get(port, 0) + 1
    return counts

DOCKER_SOCKET = "/var/run/docker.sock"
DOCKER_HELPER = "/usr/local/lib/netbar/netbar-docker"

def docker_ps():
    fmt = "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}"
    out = run(["docker", "ps", "--format", fmt], timeout=3)
    if out.strip():
        return out, "direct"
    if os.path.exists(DOCKER_HELPER):
        out = run(["sudo", "-n", DOCKER_HELPER, "ps"], timeout=3)
        if out.strip():
            return out, "helper"
    return "", "none"

def docker_status():
    socket_present = os.path.exists(DOCKER_SOCKET)
    if not socket_present:
        return {"socket": False, "readable": False, "method": "none",
                "helperInstalled": os.path.exists(DOCKER_HELPER)}
    out, method = docker_ps()
    return {
        "socket": True,
        "readable": method != "none" or _docker_probe(),
        "method": method,
        "helperInstalled": os.path.exists(DOCKER_HELPER),
    }

def _docker_probe():
    try:
        res = subprocess.run(["docker", "version", "--format", "{{.Server.Version}}"],
                             capture_output=True, text=True, timeout=3, check=False)
        if res.returncode == 0:
            return True
    except (OSError, subprocess.SubprocessError):
        pass
    if os.path.exists(DOCKER_HELPER):
        try:
            res = subprocess.run(["sudo", "-n", DOCKER_HELPER, "ps"],
                                 capture_output=True, text=True, timeout=3, check=False)
            return res.returncode == 0
        except (OSError, subprocess.SubprocessError):
            return False
    return False

def docker_proxy_map():
    out = {}
    try:
        pids = os.listdir("/proc")
    except OSError:
        return out
    for pid in pids:
        if not pid.isdigit():
            continue
        raw = read_text("/proc/%s/cmdline" % pid)
        if not raw or "docker-proxy" not in raw:
            continue
        args = [a for a in raw.split("\0") if a]
        if not args:
            continue
        if os.path.basename(args[0]) != "docker-proxy":
            continue
        flags = {}
        for i, arg in enumerate(args):
            if arg.startswith("-") and i + 1 < len(args):
                flags[arg.lstrip("-")] = args[i + 1]
        try:
            host_port = int(flags.get("host-port", ""))
        except ValueError:
            continue
        proto = flags.get("proto", "tcp").lower()
        if proto not in ("tcp", "udp"):
            proto = "tcp"
        out[(proto, host_port)] = {
            "pid": int(pid),
            "hostIp": flags.get("host-ip", ""),
            "containerIp": flags.get("container-ip", ""),
            "containerPort": flags.get("container-port", ""),
        }
    return out

def docker_map():
    out, _ = docker_ps()
    mapping = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        cid, names, image, ports = parts[0], parts[1], parts[2], parts[3]
        for match in re.finditer(r"(?:([\d.]+|\[[^\]]+\]):)?(\d+)->(\d+)/(\w+)", ports):
            host_port = int(match.group(2))
            mapping[host_port] = {
                "id": cid,
                "name": names,
                "image": image,
                "containerPort": int(match.group(3)),
            }
    return mapping

def parse_ss(include_udp):
    flags = "-tulnp" if include_udp else "-tlnp"
    rows = []
    for line in run(["ss", "-H", flags]).splitlines():
        parts = line.split(None, 6)
        if len(parts) < 5:
            continue
        if parts[0] in ("tcp", "udp", "tcp6", "udp6"):
            netid, state = parts[0], parts[1]
            local = parts[4] if len(parts) > 4 else ""
            tail = parts[6] if len(parts) > 6 else ""
        else:
            netid, state = "tcp", parts[0]
            local = parts[3] if len(parts) > 3 else ""
            tail = parts[5] if len(parts) > 5 else ""
        proto = "udp" if netid.startswith("udp") else "tcp"
        if proto == "tcp" and state != "LISTEN":
            continue
        if proto == "udp" and state not in ("UNCONN", "LISTEN"):
            continue
        host, port = split_hostport(local)
        if not port:
            continue
        procs = PROC_RE.findall(tail)
        rows.append({
            "proto": proto,
            "host": host,
            "port": port,
            "procs": [(name, int(pid)) for name, pid in procs],
        })
    return rows

EXPOSURE_RANK = {"local": 0, "iface": 1, "all": 2}

def scan(include_udp=False, probe_docker=False):
    uptime_now = boot_uptime()
    rows = parse_ss(include_udp)
    conns = established_counts()

    proxies = docker_proxy_map()
    needs_docker = bool(proxies)
    dockers = docker_map() if needs_docker else {}

    sock_uids = socket_uids()
    proc_cache = {}
    merged = {}

    for row in rows:
        name, pid = row["procs"][0] if row["procs"] else ("", 0)
        key = "%s/%d/%d" % (row["proto"], row["port"], pid)
        entry = merged.get(key)
        exposure = exposure_for(row["host"])

        if entry is None:
            if pid and pid not in proc_cache:
                proc_cache[pid] = proc_info(pid, uptime_now)
            info = proc_cache.get(pid, {})
            cmdline = info.get("cmdline", "")
            proxy = proxies.get((row["proto"], row["port"]))
            is_proxy = bool(proxy) or name == "docker-proxy"
            container = dockers.get(row["port"]) if is_proxy else None
            kind = "docker" if is_proxy else classify(name, cmdline)
            if proxy and not pid:
                pid = proxy["pid"]
                if pid not in proc_cache:
                    proc_cache[pid] = proc_info(pid, uptime_now)
                info = proc_cache.get(pid, {})
                cmdline = info.get("cmdline", "")
                name = "docker-proxy"
                key = "%s/%d/%d" % (row["proto"], row["port"], pid)
            uid = info.get("uid", -1)
            owned = bool(info.get("owned"))
            is_dev = bool(
                (owned or container or is_proxy)
                and row["port"] >= 1024
                and name not in DESKTOP_APPS
            )
            attributed = bool(pid)
            if not attributed and uid < 0:
                sock_uid = sock_uids.get((row["proto"], row["port"]))
                if sock_uid is not None:
                    uid = sock_uid
                    owned = uid == SELF_UID
            service = WELL_KNOWN_PORTS.get(row["port"], "")

            entry = {
                "key": key,
                "proto": row["proto"],
                "port": row["port"],
                "binds": [],
                "exposure": exposure,
                "pid": pid,
                "name": friendly_name(name, cmdline) or service or "unknown",
                "comm": name,
                "cmdline": cmdline,
                "cwd": info.get("cwd", ""),
                "project": info.get("project", ""),
                "uptimeSec": info.get("uptimeSec", -1),
                "uid": uid,
                "user": username_for(uid),
                "owned": owned,
                "attributed": attributed,
                "service": service,
                "needsDockerAccess": bool(is_proxy and not container),
                "containerTarget": "%s:%s" % (proxy["containerIp"], proxy["containerPort"])
                if proxy else "",
                "canKill": bool((attributed and owned) or container),
                "kind": kind,
                "isDev": is_dev,
                "connections": conns.get(row["port"], 0),
                "container": container,
                "extraPids": [p for _, p in row["procs"][1:]],
            }
            merged[key] = entry
        elif EXPOSURE_RANK.get(exposure, 0) > EXPOSURE_RANK.get(entry["exposure"], 0):
            entry["exposure"] = exposure

        if row["host"] not in entry["binds"]:
            entry["binds"].append(row["host"])

    entries = sorted(merged.values(), key=lambda e: (not e["isDev"], e["port"]))
    return {
        "ok": True,
        "scannedAt": int(time.time()),
        "docker": dict(docker_status(), probed=True)
        if (needs_docker or probe_docker)
        else {
            "socket": os.path.exists(DOCKER_SOCKET),
            "readable": False,
            "method": "none",
            "helperInstalled": os.path.exists(DOCKER_HELPER),
            "probed": False,
        },
        "ports": entries,
    }

def do_kill(pid, expect, force):
    comm = read_text("/proc/%d/comm" % pid).strip()
    if not comm:
        return {"ok": False, "error": "Process %d is already gone" % pid}
    if expect and comm != expect[:15]:
        return {
            "ok": False,
            "error": "PID %d is now '%s', not '%s' -- refusing to kill" % (pid, comm, expect),
        }
    sig = 9 if force else 15
    try:
        os.kill(pid, sig)
    except PermissionError:
        return {"ok": False, "error": "Not permitted to signal %d (owned by another user)" % pid}
    except ProcessLookupError:
        return {"ok": False, "error": "Process %d is already gone" % pid}
    except OSError as exc:
        return {"ok": False, "error": str(exc)}
    return {"ok": True, "pid": pid, "signal": sig}

def do_stop_container(cid):
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$", cid or ""):
        return {"ok": False, "error": "Refusing to stop container id %r" % cid}
    attempts = [["docker", "stop", "--", cid]]
    if os.path.exists(DOCKER_HELPER):
        attempts.append(["sudo", "-n", DOCKER_HELPER, "stop", cid])
    last = "docker stop failed"
    for argv in attempts:
        try:
            out = subprocess.run(argv, capture_output=True, text=True, timeout=30, check=False)
        except (OSError, subprocess.SubprocessError) as exc:
            last = str(exc)
            continue
        if out.returncode == 0:
            return {"ok": True, "container": cid}
        last = (out.stderr or last).strip()
    return {"ok": False, "error": last}

def main():
    parser = argparse.ArgumentParser(prog="netbar-scan")
    sub = parser.add_subparsers(dest="cmd")

    scan_cmd = sub.add_parser("scan")
    scan_cmd.add_argument("--udp", action="store_true")
    scan_cmd.add_argument("--docker", action="store_true",
                          help="also probe whether the docker daemon is readable")

    kill_cmd = sub.add_parser("kill")
    kill_cmd.add_argument("pid", type=int)
    kill_cmd.add_argument("--expect", default="")
    kill_cmd.add_argument("--force", action="store_true")

    stop_cmd = sub.add_parser("stop-container")
    stop_cmd.add_argument("id")

    sub.add_parser("docker-status")

    args = parser.parse_args()
    if args.cmd == "kill":
        result = do_kill(args.pid, args.expect, args.force)
    elif args.cmd == "stop-container":
        result = do_stop_container(args.id)
    elif args.cmd == "docker-status":
        result = dict(docker_status(), ok=True)
    else:
        result = scan(include_udp=getattr(args, "udp", False),
                      probe_docker=getattr(args, "docker", False))
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")

if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        json.dump({"ok": False, "error": "%s: %s" % (type(exc).__name__, exc)}, sys.stdout)
        sys.stdout.write("\n")
        sys.exit(1)
