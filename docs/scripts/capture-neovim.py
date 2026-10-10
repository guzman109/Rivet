"""Capture Rivet's real Neovim line-grid UI (no mocked widget layouts).
Requires Python msgpack and Pillow. Run from the repository root.
"""

import os
import pathlib
import select
import subprocess
import sys
import tempfile
import time

# Optional dependency directory for reproducible local capture runs.
if os.environ.get("RIVET_CAPTURE_LIBS"):
    sys.path.insert(0, os.environ["RIVET_CAPTURE_LIBS"])
import msgpack
from PIL import Image, ImageDraw, ImageFont

REPO = pathlib.Path(__file__).resolve().parents[2]
OUT = REPO / "docs/static/images"
FONT = os.environ.get("RIVET_CAPTURE_FONT", "/System/Library/Fonts/Menlo.ttc")


class Capture:
    def __init__(self):
        self.proc = subprocess.Popen(
            ["nvim", "--embed", "--headless", "-n", "-u", "NONE", "-i", "NONE"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env={**os.environ, "NVIM_LOG_FILE": str(pathlib.Path(tempfile.gettempdir()) / "rivet-capture-nvim.log")},
        )
        self.unpack = msgpack.Unpacker(raw=False, strict_map_key=False)
        self.seq = 0
        self.replies = {}
        self.grids = {}
        self.attrs = {0: {}}
        self.fg = 0xCDD6F4
        self.bg = 0x1E1E2E
        self.rpc("nvim_ui_attach", [118, 34, {"rgb": True, "ext_linegrid": True}])
        self.lua(
            "vim.opt.runtimepath:prepend(...); vim.o.termguicolors=true; vim.cmd('filetype on'); vim.cmd('syntax on'); vim.o.laststatus=0; vim.o.showmode=false; vim.o.ruler=false; vim.o.showcmd=false; vim.o.fillchars='eob: '; vim.api.nvim_set_hl(0,'Normal',{fg='#cdd6f4',bg='#1e1e2e'}); vim.api.nvim_set_hl(0,'NormalFloat',{fg='#cdd6f4',bg='#181825'}); vim.api.nvim_set_hl(0,'FloatBorder',{fg='#eba0ac',bg='#181825'}); vim.api.nvim_set_hl(0,'FloatTitle',{fg='#eba0ac',bold=true}); vim.api.nvim_set_hl(0,'Title',{fg='#eba0ac',bold=true}); vim.api.nvim_set_hl(0,'CursorLine',{bg='#313244'}); vim.api.nvim_set_hl(0,'PmenuSel',{bg='#45475a',fg='#cdd6f4'}); require('rivet').setup()",
            [str(REPO)],
        )

    def lua(self, code, args=None):
        return self.rpc("nvim_exec_lua", [code, args or []])

    def rpc(self, name, args):
        self.seq += 1
        idx = self.seq
        self.proc.stdin.write(msgpack.packb([0, idx, name, args], use_bin_type=True))
        self.proc.stdin.flush()
        end = time.monotonic() + 20
        while idx not in self.replies and time.monotonic() < end:
            self.pump(0.1)
        error, value = self.replies.pop(idx)
        if error:
            raise RuntimeError(error)
        return value

    def pump(self, timeout):
        if not select.select([self.proc.stdout], [], [], timeout)[0]:
            return
        data = os.read(self.proc.stdout.fileno(), 65536)
        if not data:
            raise RuntimeError("Neovim exited")
        self.unpack.feed(data)
        for item in self.unpack:
            if item[0] == 1:
                self.replies[item[1]] = (item[2], item[3])
            elif item[0] == 2 and item[1] == "redraw":
                for event in item[2]:
                    name = event[0]
                    for args in event[1:]:
                        self.event(name, args)

    def event(self, name, a):
        if name == "default_colors_set":
            self.fg, self.bg = a[0], a[1]
        elif name == "hl_attr_define":
            self.attrs[a[0]] = a[1]
        elif name == "grid_resize":
            self.grids[a[0]] = [[(" ", 0) for _ in range(a[1])] for _ in range(a[2])]
        elif name == "grid_clear":
            g = self.grids[a[0]]
            self.grids[a[0]] = [[(" ", 0) for _ in row] for row in g]
        elif name == "grid_line":
            g, row, col, cells = a[:4]
            hl = 0
            for cell in cells:
                if len(cell) > 1:
                    hl = cell[1]
                for _ in range(cell[2] if len(cell) > 2 else 1):
                    self.grids[g][row][col] = (cell[0], hl)
                    col += 1
        elif name == "grid_scroll":
            g, top, bottom, left, right, rows, cols = a
            old = [r[:] for r in self.grids[g]]
            for row in range(top, bottom):
                for col in range(left, right):
                    self.grids[g][row][col] = (
                        old[row + rows][col + cols]
                        if top <= row + rows < bottom and left <= col + cols < right
                        else (" ", 0)
                    )

    def save(self, name):
        self.rpc("nvim_command", ["redraw!"])
        until = time.monotonic() + 0.4
        while time.monotonic() < until:
            self.pump(0.03)
        grid = self.grids[1]
        cw, ch = 9, 20
        padding = 16
        image = Image.new(
            "RGB",
            (len(grid[0]) * cw + padding * 2, len(grid) * ch + padding * 2),
            f"#{self.bg:06x}",
        )
        draw = ImageDraw.Draw(image)
        font = ImageFont.truetype(FONT, 14)
        for y, row in enumerate(grid):
            for x, (text, hl) in enumerate(row):
                attr = self.attrs.get(hl, {})
                fg = attr.get("foreground", self.fg)
                bg = attr.get("background", self.bg)
                if attr.get("reverse"):
                    fg, bg = bg, fg
                origin = (padding + x * cw, padding + y * ch)
                draw.rectangle(
                    (*origin, origin[0] + cw, origin[1] + ch), fill=f"#{bg:06x}"
                )
                if text and text != " ":
                    draw.text(
                        (origin[0], origin[1] + 1), text, font=font, fill=f"#{fg:06x}"
                    )
        OUT.mkdir(parents=True, exist_ok=True)
        image.save(OUT / name)

    def close(self):
        self.proc.terminate()
        self.proc.wait(timeout=5)


def scene(name, code, wait=False, args=None):
    c = Capture()
    try:
        c.lua(code, args)
        if wait:
            end = time.monotonic() + 3
            while time.monotonic() < end:
                c.pump(0.05)
        c.save(name)
    finally:
        c.close()


scene(
    "neovim-wizard.png",
    "local steps=require('rivet.model').questions('new',{language='cpp'},{tools={}}); for _,step in ipairs(steps) do if step.key=='profile' then require('rivet.ui').select_preview(step.title,step.items,function() end); break end end",
)
scene(
    "neovim-review.png",
    "local plan=require('rivet.model').plan({name='simulation',standard=23,modules=true,module_layout='single',profile='cpu',comment_header={style='compact',author='Ada Lovelace'}}); local ui=require('rivet.ui'); local panel=ui.review('/projects/simulation',plan,function() end); for row,line in ipairs(vim.api.nvim_buf_get_lines(panel.list,0,-1,false)) do if line:find('src/core/core.cppm',1,true) then vim.api.nvim_win_set_cursor(panel.windows[1],{row,0}); break end end;vim.api.nvim_exec_autocmds('CursorMoved',{buffer=panel.list})",
)
with tempfile.TemporaryDirectory(prefix="rivet-capture-") as temporary:
    fixture = str(pathlib.Path(temporary).resolve() / "simulation")
    subprocess.run(
        [
            str(REPO / "bin/rivet"),
            "new",
            fixture,
            "--name",
            "simulation",
            "--profile",
            "cpu",
            "--modules",
            "false",
            "--standard",
            "17",
            "--build",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    scene(
        "neovim-output.png",
        "local root=...; vim.cmd.edit(vim.fn.fnameescape(root..'/examples/cpu/main.cpp')); vim.o.number=true; require('rivet.ui').run(root,{'ctest','--test-dir','build/debug','--output-on-failure'},'CTest · CPU correctness',function() end)",
        True,
        [fixture],
    )
print("Saved real Neovim UI captures to", OUT)
