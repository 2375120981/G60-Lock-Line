"""Locate a local Lua 5.1 library; never launch or attach to the game."""
from __future__ import annotations

import ctypes.util
import os
from pathlib import Path
import re


def lua_library() -> str:
    explicit = os.environ.get('G60_LUA_LIBRARY')
    if explicit:
        path = Path(explicit).expanduser()
        if not path.is_file():
            raise FileNotFoundError('G60_LUA_LIBRARY does not name an existing file')
        return str(path.resolve())

    game = os.environ.get('G60_GAME_DIR')
    if game:
        path = Path(game).expanduser() / 'bin/lua51.dll'
        if not path.is_file():
            raise FileNotFoundError('G60_GAME_DIR must contain bin/lua51.dll')
        return str(path.resolve())

    system = ctypes.util.find_library('lua5.1') or ctypes.util.find_library('lua51')
    if system:
        return system

    roots = []
    if os.environ.get('STEAM_DIR'):
        roots.append(Path(os.environ['STEAM_DIR']))
    for variable in ('ProgramFiles(x86)', 'ProgramFiles'):
        if os.environ.get(variable):
            roots.append(Path(os.environ[variable]) / 'Steam')
    if os.name == 'nt':
        # Common library roots only: no recursive disk scan or process access.
        roots.extend(Path(f'{drive}:/Steam') for drive in 'CDEFGHIJKLMNOPQRSTUVWXYZ')
    for root in list(roots):
        libraries = root / 'steamapps/libraryfolders.vdf'
        if libraries.is_file():
            content = libraries.read_text(encoding='utf-8', errors='replace')
            roots.extend(Path(value.replace('\\\\', '\\'))
                         for value in re.findall(r'"path"\s*"([^"]+)"', content))
    for root in dict.fromkeys(roots):
        path = root / 'steamapps/common/Helldivers 2/bin/lua51.dll'
        if path.is_file():
            return str(path.resolve())
    raise FileNotFoundError(
        'Lua 5.1 library not found. Set G60_LUA_LIBRARY to a Lua 5.1 shared '
        'library, or G60_GAME_DIR to your Helldivers 2 installation directory. '
        'A 64-bit Python needs a 64-bit library; do not use Lua 5.2+ or bundle game DLLs.'
    )
