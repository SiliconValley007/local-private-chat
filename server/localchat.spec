# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for a single-file Windows Local Chat server build.

Build (from the server/ directory, with the project venv active)::

    pip install -r requirements.txt pyinstaller
    pyinstaller localchat.spec

Output: ``dist/LocalChatServer.exe``. Double-clicking it starts the server;
operator tools are subcommands of the same executable.
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
            "app.admin",
            "app.auth",
            "app.sessions",
            "reset_password",
            "set_admin",
            "tailscale_check",
            # Windows blocks inbound connections by default; this module is what
            # tells the operator so and offers to open the port.
            "firewall",
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
    a.binaries,
    a.datas,
    [],
    exclude_binaries=False,
    name="LocalChatServer",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    # UPX-compressed executables are commonly quarantined by Windows security
    # products. Reliability matters more than a smaller download here.
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
