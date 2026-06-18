#!/usr/bin/env python3

import argparse
import html
import re
from collections import defaultdict
from pathlib import Path


BUSYBOX_VERSION = "1.38.0"
LIVEOS_BASE_URL = "https://re.xhh.pw"
DEFAULT_HIDDEN_FILES = {
    ".env",
    "context.rewrite",
    "edgeone.json",
    "middleware.js",
}


def normalize_rewrite_path(value):
    value = value.lstrip("/")
    if not value or value == ".." or value.startswith("../") or "/../" in value or value.endswith("/.."):
        raise ValueError(f"invalid rewrite path: {value!r}")
    return value


def parse_rewrite_file(path):
    aliases_by_real = defaultdict(list)
    hidden_files = set()

    if not path.is_file():
        return aliases_by_real, hidden_files

    for line_no, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue

        fields = line.split()
        real = fields[0]
        hidden = real.startswith("!")
        if hidden:
            real = real[1:]

        real = normalize_rewrite_path(real)
        if hidden:
            hidden_files.add(real)

        for alias in fields[1:]:
            alias = normalize_rewrite_path(alias)
            if alias not in aliases_by_real[real]:
                aliases_by_real[real].append(alias)

    return aliases_by_real, hidden_files


def size_label(size):
    units = ["bytes", "KiB", "MiB", "GiB"]
    value = float(size)
    unit = units[0]
    for unit in units:
        if value < 1024 or unit == units[-1]:
            break
        value /= 1024

    if unit == "bytes":
        number = str(int(value))
    elif value >= 10:
        number = f"{value:.0f}"
    else:
        number = f"{value:.1f}".rstrip("0").rstrip(".")

    return f"{number} {unit}"


def version_tuple(version):
    return tuple(int(part) for part in version.split("."))


def sort_key(name):
    kernel_match = re.fullmatch(r"bzImage-(\d+\.\d+\.\d+)-(mod|std)", name)
    if kernel_match:
        suffix_rank = 0 if kernel_match.group(2) == "mod" else 1
        return (10, version_tuple(kernel_match.group(1)), suffix_rank, name)

    image_match = re.fullmatch(r"Image\.gz-(\d+\.\d+\.\d+)-(mod|std)", name)
    if image_match:
        suffix_rank = 0 if image_match.group(2) == "mod" else 1
        return (20, version_tuple(image_match.group(1)), suffix_rank, name)

    special_rank = {
        "bzImage-busybox": (30, 0),
        "Image.gz-busybox": (30, 1),
        "initrd.1": (40, 0),
        "initrd.2": (40, 1),
        "initrd_amd64.zst": (50, 0),
        "initrd_amd64.gz": (50, 1),
        "initrd_arm64.zst": (50, 2),
        "initrd_arm64.gz": (50, 3),
        "busybox_amd64": (60, 0),
        "busybox_arm64": (60, 1),
        "busybox_amd64.tar.gz": (60, 2),
        "busybox_arm64.tar.gz": (60, 3),
        "dropbearmulti_amd64": (70, 0),
        "dropbearmulti_arm64": (70, 1),
        "sftp-server_amd64": (80, 0),
        "sftp-server_arm64": (80, 1),
        "reinstall.sh": (100, 0),
        "reinstall_rootfs.sh": (100, 1),
        "index.html": (110, 0),
        "context.rewrite": (110, 1),
        "edgeone.json": (110, 2),
        "middleware.js": (110, 3),
    }
    if name in special_rank:
        return (*special_rank[name], name)

    python_match = re.fullmatch(r"python-(\d+\.\d+\.\d+)-(x86_64|aarch64)\.tar\.(gz|zst)", name)
    if python_match:
        arch_rank = 0 if python_match.group(2) == "aarch64" else 1
        compress_rank = 0 if python_match.group(3) == "gz" else 1
        return (90, version_tuple(python_match.group(1)), arch_rank, compress_rank, name)

    return (999, name)


def describe_file(name):
    kernel_match = re.fullmatch(r"bzImage-(\d+\.\d+\.\d+)-(mod|std)", name)
    if kernel_match:
        kind = "modular" if kernel_match.group(2) == "mod" else "standard"
        return f'<span class="tag">amd64</span> Linux {html.escape(kernel_match.group(1))} {kind} kernel'

    image_match = re.fullmatch(r"Image\.gz-(\d+\.\d+\.\d+)-(mod|std)", name)
    if image_match:
        kind = "modular" if image_match.group(2) == "mod" else "standard"
        return f'<span class="tag">arm64</span> Linux {html.escape(image_match.group(1))} {kind} gzip kernel image'

    if name == "bzImage-busybox":
        return f'<span class="tag">amd64</span> Linux 6.18.35 embed BusyBox {BUSYBOX_VERSION}'
    if name == "Image.gz-busybox":
        return f'<span class="tag">arm64</span> Linux 6.18.35 embed BusyBox {BUSYBOX_VERSION}'
    if name == "initrd.1":
        return "Ubuntu LiveOS initrd part 1 (load before initrd.2)"
    if name == "initrd.2":
        return "Ubuntu LiveOS initrd part 2 (load after initrd.1)"

    initrd_match = re.fullmatch(r"initrd_(amd64|arm64)\.(zst|gz)", name)
    if initrd_match:
        compression = "zstd" if initrd_match.group(2) == "zst" else "gzip"
        return f'<span class="tag">{html.escape(initrd_match.group(1))}</span> BusyBox initramfs ({compression})'

    busybox_match = re.fullmatch(r"busybox_(amd64|arm64)(\.tar\.gz)?", name)
    if busybox_match:
        prefix = "compressed" if busybox_match.group(2) else "static"
        return f'{prefix} <span class="tag">{html.escape(busybox_match.group(1))}</span> BusyBox {BUSYBOX_VERSION}'

    dropbear_match = re.fullmatch(r"dropbearmulti_(amd64|arm64)", name)
    if dropbear_match:
        return f'static <span class="tag">{html.escape(dropbear_match.group(1))}</span> Dropbear multi-call binary'

    sftp_match = re.fullmatch(r"sftp-server_(amd64|arm64)", name)
    if sftp_match:
        return f'static <span class="tag">{html.escape(sftp_match.group(1))}</span> OpenSSH SFTP server'

    python_match = re.fullmatch(r"python-(\d+\.\d+\.\d+)-(x86_64|aarch64)\.tar\.(gz|zst)", name)
    if python_match:
        compression = "gzip" if python_match.group(3) == "gz" else "zstd"
        return (
            f'<span class="tag">{html.escape(python_match.group(2))}</span> '
            f'Python {html.escape(python_match.group(1))} rescue runtime ({compression})'
        )

    descriptions = {
        "reinstall.sh": "host-side reinstall script",
        "reinstall_rootfs.sh": "BusyBox rootfs reinstall script",
        "index.html": "directory index page",
        "context.rewrite": "rewrite alias source mirrored from repo root",
        "edgeone.json": "EdgeOne Pages generated rewrite configuration",
        "middleware.js": "EdgeOne Pages middleware for case-insensitive path fallback",
    }
    return html.escape(descriptions.get(name, "static artifact"))


def render_alias_links(aliases):
    links = []
    for alias in aliases:
        escaped_alias = html.escape(alias)
        links.append(f'<a href="/{escaped_alias}"><code>/{escaped_alias}</code></a>')

    return "".join(links)


def render_alias_action(name, row_id, aliases):
    if not aliases:
        return '<span class="alias-empty">-</span>'

    escaped_name = html.escape(name, quote=True)
    return (
        f'<button class="alias-toggle" type="button" aria-expanded="false" '
        f'aria-controls="{row_id}" aria-label="Show aliases for {escaped_name}">'
        '<span class="alias-caret" aria-hidden="true">&gt;</span>'
        '<span class="alias-dots" aria-hidden="true">...</span>'
        '</button>'
    )


def render_rows(edgeone_dir, aliases_by_real, hidden_files, index_size=None):
    rows = []
    files = []

    for path in edgeone_dir.iterdir():
        if not path.is_file():
            continue
        if path.name in DEFAULT_HIDDEN_FILES or path.name in hidden_files:
            continue
        files.append(path.name)

    for index, name in enumerate(sorted(files, key=sort_key)):
        path = edgeone_dir / name
        size = index_size if name == "index.html" and index_size is not None else path.stat().st_size
        escaped_name = html.escape(name)
        aliases = aliases_by_real.get(name, [])
        alias_row_id = f"aliases-{index}"
        row_html = (
            '              <tr class="file-row">\n'
            f'                <td><a href="/{escaped_name}" download>{escaped_name}</a></td>\n'
            f'                <td><code class="path">/{escaped_name}</code></td>\n'
            f"                <td>{html.escape(size_label(size))}</td>\n"
            f"                <td>{describe_file(name)}</td>\n"
            f'                <td class="action-cell">{render_alias_action(name, alias_row_id, aliases)}</td>\n'
            "              </tr>"
        )
        if aliases:
            row_html += (
                "\n"
                f'              <tr id="{alias_row_id}" class="alias-row" hidden>\n'
                f'                <td colspan="2"><div class="alias-list">{render_alias_links(aliases)}</div></td>\n'
                '                <td colspan="3" class="alias-fill"></td>\n'
                "              </tr>"
            )
        rows.append(row_html)

    return "\n".join(rows), len(files)


def render_document(edgeone_dir, aliases_by_real, hidden_files, index_size=None):
    rows, row_count = render_rows(edgeone_dir, aliases_by_real, hidden_files, index_size)
    download_command = "curl re.xhh.pw/re.sh || wget -O ${_##*/} $_"

    return f'''<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>kernel-liveos directory</title>
    <style>
      :root {{
        color-scheme: light;
        --bg: #f6f7f9;
        --fg: #15181d;
        --muted: #69707a;
        --line: #d8dde5;
        --head: #e9edf3;
        --link: #075e9f;
        --ok: #2f6f52;
      }}

      * {{
        box-sizing: border-box;
      }}

      body {{
        margin: 0;
        background: var(--bg);
        color: var(--fg);
        font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        font-size: 15px;
        line-height: 1.5;
      }}

      main {{
        width: min(1180px, calc(100% - 32px));
        margin: 0 auto;
        padding: 28px 0 40px;
      }}

      h1 {{
        margin: 0 0 6px;
        font-size: 26px;
        font-weight: 650;
      }}

      .meta,
      .note {{
        color: var(--muted);
      }}

      .meta {{
        margin: 0 0 22px;
      }}

      .run {{
        margin: 0 0 18px;
        border: 1px solid var(--line);
        background: #fff;
        padding: 14px 16px;
      }}

      .run p {{
        margin: 0 0 8px;
        color: var(--muted);
      }}

      .command {{
        display: block;
        overflow-x: auto;
        padding: 10px 12px;
        background: #15181d;
        color: #f6f7f9;
        white-space: nowrap;
      }}

      .command + p {{
        margin-top: 12px;
      }}

      details.files {{
        margin-top: 18px;
      }}

      details.files > summary {{
        cursor: pointer;
        margin-bottom: 10px;
        color: var(--link);
        font-weight: 650;
      }}

      .table-wrap {{
        overflow-x: auto;
        border: 1px solid var(--line);
        background: #fff;
      }}

      table {{
        width: 100%;
        min-width: 920px;
        border-collapse: collapse;
      }}

      th,
      td {{
        padding: 10px 12px;
        border-bottom: 1px solid var(--line);
        text-align: left;
        vertical-align: top;
      }}

      th {{
        background: var(--head);
        font-size: 13px;
        font-weight: 650;
        color: #363c45;
      }}

      tr:last-child td {{
        border-bottom: 0;
      }}

      a {{
        color: var(--link);
        font-weight: 600;
        text-decoration: none;
      }}

      a:hover,
      a:focus {{
        text-decoration: underline;
      }}

      code {{
        font-family: ui-monospace, SFMono-Regular, Consolas, "Liberation Mono", monospace;
        font-size: 13px;
      }}

      .path {{
        color: var(--muted);
      }}

      .tag {{
        color: var(--ok);
        font-weight: 650;
      }}

      .action-head,
      .action-cell {{
        width: 64px;
        text-align: center;
      }}

      .alias-toggle {{
        display: inline-flex;
        align-items: center;
        gap: 4px;
        border: 0;
        background: transparent;
        color: var(--link);
        cursor: pointer;
        font: inherit;
        font-weight: 650;
        padding: 0;
      }}

      .alias-caret {{
        display: inline-block;
        transition: transform 120ms ease;
      }}

      .alias-toggle[aria-expanded="true"] .alias-caret {{
        transform: rotate(90deg);
      }}

      .alias-row[hidden] {{
        display: none;
      }}

      .alias-row td {{
        padding-top: 0;
        background: #fff;
      }}

      .alias-list {{
        display: flex;
        flex-wrap: wrap;
        gap: 6px 10px;
        padding: 0 0 12px;
      }}

      .alias-empty {{
        color: var(--muted);
      }}

      .alias-fill {{
        padding: 0;
      }}
    </style>
  </head>
  <body>
    <main>
      <h1>kernel-liveos directory</h1>
      <p class="meta">Static files available from this EdgeOne Pages deployment.</p>

      <div class="run">
        <p>Download the reinstall script with curl or wget:</p>
        <code class="command">{html.escape(download_command)}</code>
        <p>Ubuntu LiveOS note:</p>
        <code class="command">Load initrd.1 then load initrd.2</code>
      </div>

      <details class="files">
        <summary>File list ({row_count})</summary>
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>File</th>
                <th>Path</th>
                <th>Size</th>
                <th>Notes</th>
                <th class="action-head" aria-label="Actions"></th>
              </tr>
            </thead>
            <tbody>
{rows}
            </tbody>
          </table>
        </div>
      </details>

      <p class="note">
        amd64 uses <code>bzImage</code>. arm64 uses <code>Image</code>; there is no arm64 <code>bzImage</code> format.
        Python archives are stripped static rescue runtimes; use <code>x86_64</code> packages on amd64 hosts and <code>aarch64</code> packages on arm64 hosts.
      </p>
    </main>
    <script>
      for (const button of document.querySelectorAll('.alias-toggle')) {{
        button.addEventListener('click', () => {{
          const row = document.getElementById(button.getAttribute('aria-controls'));
          const expanded = button.getAttribute('aria-expanded') === 'true';
          button.setAttribute('aria-expanded', String(!expanded));
          if (row) {{
            row.hidden = expanded;
          }}
        }});
      }}
    </script>
  </body>
</html>
'''


def main():
    parser = argparse.ArgumentParser(description="Generate edgeone/index.html from deployed files and rewrite aliases.")
    parser.add_argument("--edgeone-dir", required=True, type=Path)
    parser.add_argument("--rewrite-source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    aliases_by_real, hidden_files = parse_rewrite_file(args.rewrite_source)

    index_size = args.output.stat().st_size if args.output.exists() else None
    document = ""
    for _ in range(6):
        document = render_document(args.edgeone_dir, aliases_by_real, hidden_files, index_size)
        next_size = len(document.encode("utf-8"))
        if next_size == index_size:
            break
        index_size = next_size

    args.output.write_text(document, encoding="utf-8")
    row_count = document.count('<tr class="file-row">')
    print(f"Generated {args.output} with {row_count} listed files.")


if __name__ == "__main__":
    main()
