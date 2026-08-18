# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for a one-folder Windows Local Chat server build.

Build (from the server/ directory, with the project venv active)::

    pip install -r requirements.txt pyinstaller
    pyinstaller localchat.spec

Output: ``dist/LocalChatServer/LocalChatServer.exe`` plus ``ResetPassword.exe``
for admin password resets on hosts without Python installed.
"""

from PyInstaller.utils.hooks import collect_all, collect_submodules

fastapi_datas, fastapi_binaries, fastapi_hidden = collect_all("fastapi")
starlette_datas, starlette_binaries, starlette_hidden = collect_all("starlette")
uvicorn_datas, uvicorn_binaries, uvicorn_hidden = collect_all("uvicorn")
pydantic_datas, pydantic_binaries, pydantic_hidden = collect_all("pydantic")
jose_hidden = collect_submodules("jose")
# passlib resolves its bcrypt backend lazily, so the handlers need naming.
passlib_hidden = collect_submodules("passlib")

# Push notifications. firebase-admin and Google's auth stack load plenty of
# modules by name at runtime, so without this the exe starts but quietly logs
# "FCM disabled: firebase-admin not installed" and no phone is ever woken.
firebase_datas, firebase_binaries, firebase_hidden = collect_all("firebase_admin")
google_auth_datas, google_auth_binaries, google_auth_hidden = collect_all("google.auth")
oauth2_datas, oauth2_binaries, oauth2_hidden = collect_all("google.oauth2")
api_core_datas, api_core_binaries, api_core_hidden = collect_all("google.api_core")
grpc_datas, grpc_binaries, grpc_hidden = collect_all("grpc")

hiddenimports = sorted(
    set(
        fastapi_hidden
        + starlette_hidden
        + uvicorn_hidden
        + pydantic_hidden
        + jose_hidden
        # The server hashes passwords too: without these the exe dies on the
        # first import of app.auth with "No module named passlib.handlers.bcrypt".
        + passlib_hidden
        + firebase_hidden
        + google_auth_hidden
        + oauth2_hidden
        + api_core_hidden
        + grpc_hidden
        + [
            "bcrypt",
            "passlib.handlers.bcrypt",
            "uvicorn.logging",
            "uvicorn.loops",
            "uvicorn.loops.auto",
            "uvicorn.protocols",
            "uvicorn.protocols.http",
            "uvicorn.protocols.http.auto",
            "uvicorn.protocols.websockets",
            "uvicorn.protocols.websockets.auto",
            "uvicorn.lifespan",
            "uvicorn.lifespan.on",
            "app",
            "app.main",
            "app.db",
            "app.models",
            "app.fcm",
            "firebase_admin.messaging",
            "firebase_admin.credentials",
            "multipart",
            "email_validator",
        ]
    )
)

datas = (
    fastapi_datas
    + starlette_datas
    + uvicorn_datas
    + pydantic_datas
    + firebase_datas
    + google_auth_datas
    + oauth2_datas
    + api_core_datas
    + grpc_datas
)
binaries = (
    fastapi_binaries
    + starlette_binaries
    + uvicorn_binaries
    + pydantic_binaries
    + firebase_binaries
    + google_auth_binaries
    + oauth2_binaries
    + api_core_binaries
    + grpc_binaries
)

a = Analysis(
    ["run.py"],
    pathex=["."],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["tkinter", "matplotlib", "numpy", "pandas"],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="LocalChatServer",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

# Second entry point in the same folder: admin password reset without Python.
reset = Analysis(
    ["reset_password.py"],
    pathex=["."],
    binaries=[],
    datas=[],
    hiddenimports=sorted(
        set(
            passlib_hidden
            + [
                "app",
                "app.auth",
                "app.db",
                "app.models",
                "app.sessions",
                "bcrypt",
                "passlib.handlers.bcrypt",
            ]
        )
    ),
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["tkinter", "matplotlib", "numpy", "pandas"],
    noarchive=False,
    optimize=0,
)
reset_pyz = PYZ(reset.pure)

reset_exe = EXE(
    reset_pyz,
    reset.scripts,
    [],
    exclude_binaries=True,
    name="ResetPassword",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

# Third entry: operator break-glass for admin username / device pin.
set_admin = Analysis(
    ["set_admin.py"],
    pathex=["."],
    binaries=[],
    datas=[],
    hiddenimports=sorted(
        set(
            passlib_hidden
            + [
                "app",
                "app.admin",
                "app.auth",
                "app.db",
                "app.models",
                "app.sessions",
                "bcrypt",
                "passlib.handlers.bcrypt",
            ]
        )
    ),
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["tkinter", "matplotlib", "numpy", "pandas"],
    noarchive=False,
    optimize=0,
)
set_admin_pyz = PYZ(set_admin.pure)

set_admin_exe = EXE(
    set_admin_pyz,
    set_admin.scripts,
    [],
    exclude_binaries=True,
    name="SetAdmin",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    reset_exe,
    reset.binaries,
    reset.datas,
    set_admin_exe,
    set_admin.binaries,
    set_admin.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name="LocalChatServer",
)
