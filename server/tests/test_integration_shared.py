"""Conversation Media / Docs / Links gallery index."""

from __future__ import annotations

from tests.conftest import auth_header, register


def _dm(client, a, b):
    res = client.post(
        "/api/conversations/dm",
        headers=auth_header(a["token"]),
        json={"user_id": b["user"]["id"]},
    )
    return res.json()["id"]


def test_shared_index_groups_media_docs_and_links(client):
    a = register(client, "alice")
    b = register(client, "bob")
    ha = auth_header(a["token"])
    conv_id = _dm(client, a, b)

    client.post(
        f"/api/conversations/{conv_id}/messages",
        headers=ha,
        json={
            "type": "text",
            "body": "see https://example.com/a and https://example.com/b",
        },
    )
    img = client.post(
        f"/api/conversations/{conv_id}/media",
        headers=ha,
        files={"file": ("shot.png", b"\x89PNG\r\n", "image/png")},
        data={"type": "image"},
    )
    assert img.status_code == 200, img.text

    doc = client.post(
        f"/api/conversations/{conv_id}/media",
        headers=ha,
        files={"file": ("notes.pdf", b"%PDF-1.4 fake", "application/pdf")},
        data={"type": "file"},
    )
    assert doc.status_code == 200, doc.text

    shared = client.get(f"/api/conversations/{conv_id}/shared", headers=ha)
    assert shared.status_code == 200
    items = shared.json()
    kinds = {i["kind"] for i in items}
    assert kinds == {"media", "docs", "links"}
    links = [i for i in items if i["kind"] == "links"]
    assert len(links) == 2
    assert {i["url"] for i in links} == {
        "https://example.com/a",
        "https://example.com/b",
    }


def test_shared_index_requires_membership(client):
    a = register(client, "alice")
    b = register(client, "bob")
    c = register(client, "carol")
    conv_id = _dm(client, a, b)
    denied = client.get(
        f"/api/conversations/{conv_id}/shared",
        headers=auth_header(c["token"]),
    )
    assert denied.status_code == 403
