"""Integration tests: media upload/download."""

from __future__ import annotations

from tests.conftest import auth_header, register


def test_upload_and_download_file(client):
    a = register(client, "alice")
    b = register(client, "bob")
    ha, hb = auth_header(a["token"]), auth_header(b["token"])

    dm = client.post("/api/conversations/dm", headers=ha, json={"user_id": b["user"]["id"]})
    conv_id = dm.json()["id"]

    files = {"file": ("hello.txt", b"hello local chat", "text/plain")}
    data = {"type": "file", "caption": "note"}
    up = client.post(
        f"/api/conversations/{conv_id}/media",
        headers=ha,
        files=files,
        data=data,
    )
    assert up.status_code == 200, up.text
    body = up.json()
    assert body["type"] == "file"
    assert body["media_name"] == "hello.txt"
    assert body["body"] == "note"
    message_id = body["id"]

    # Member can download
    dl = client.get(f"/api/media/{message_id}", headers=hb)
    assert dl.status_code == 200
    assert dl.content == b"hello local chat"

    # Stranger cannot
    c = register(client, "carol")
    denied = client.get(f"/api/media/{message_id}", headers=auth_header(c["token"]))
    assert denied.status_code == 403


def test_upload_image_and_voice_types(client):
    a = register(client, "alice")
    b = register(client, "bob")
    ha = auth_header(a["token"])
    dm = client.post("/api/conversations/dm", headers=ha, json={"user_id": b["user"]["id"]})
    conv_id = dm.json()["id"]

    img = client.post(
        f"/api/conversations/{conv_id}/media",
        headers=ha,
        files={"file": ("pic.png", b"\x89PNG\r\n", "image/png")},
        data={"type": "image"},
    )
    assert img.status_code == 200
    assert img.json()["type"] == "image"

    voice = client.post(
        f"/api/conversations/{conv_id}/media",
        headers=ha,
        files={"file": ("note.m4a", b"fakeaudio", "audio/mp4")},
        data={"type": "voice"},
    )
    assert voice.status_code == 200
    assert voice.json()["type"] == "voice"

    bad = client.post(
        f"/api/conversations/{conv_id}/media",
        headers=ha,
        files={"file": ("x.bin", b"x", "application/octet-stream")},
        data={"type": "sticker"},
    )
    assert bad.status_code == 400
