"""Unit tests for Tailscale / LAN IP discovery helpers in run.py."""

from __future__ import annotations

import run as run_mod


def test_is_tailscale_ip_range():
    assert run_mod.is_tailscale_ip("100.71.32.92")
    assert run_mod.is_tailscale_ip("100.64.0.1")
    assert run_mod.is_tailscale_ip("100.127.255.254")
    assert not run_mod.is_tailscale_ip("100.63.255.255")
    assert not run_mod.is_tailscale_ip("100.128.0.1")
    assert not run_mod.is_tailscale_ip("192.168.29.48")
    assert not run_mod.is_tailscale_ip("10.197.190.179")
    assert not run_mod.is_tailscale_ip("not-an-ip")


def test_preferred_client_ip_prefers_tailscale():
    ips = ["172.23.96.1", "192.168.29.48", "100.71.32.92", "10.197.190.179"]
    assert run_mod.preferred_client_ip(ips) == "100.71.32.92"


def test_preferred_client_ip_falls_back_to_lan():
    ips = ["172.23.96.1", "10.197.190.179", "192.168.29.48"]
    assert run_mod.preferred_client_ip(ips) == "192.168.29.48"


def test_tailscale_and_lan_split():
    ips = ["100.71.32.92", "192.168.29.48", "10.1.1.1"]
    assert run_mod.tailscale_ips(ips) == ["100.71.32.92"]
    assert run_mod.lan_ips(ips) == ["192.168.29.48", "10.1.1.1"]


def test_unique_non_loopback_filters():
    raw = ["127.0.0.1", "192.168.1.5", "192.168.1.5", "", "100.71.32.92"]
    assert run_mod.unique_non_loopback(raw) == ["192.168.1.5", "100.71.32.92"]


def test_route_probe_returns_usable_addresses():
    """The probe must never raise, and must only yield real IPv4 strings."""
    for addr in run_mod._ips_from_route_probe():  # pylint: disable=protected-access
        parts = addr.split(".")
        assert len(parts) == 4
        assert all(part.isdigit() for part in parts)


def test_interface_scan_returns_usable_addresses():
    """On Linux/Android this finds the tun interface; elsewhere it returns []."""
    for addr in run_mod._ips_from_interfaces():  # pylint: disable=protected-access
        parts = addr.split(".")
        assert len(parts) == 4
        assert all(part.isdigit() for part in parts)


def test_discovery_prefers_tailscale_when_present():
    """Whatever the machine reports, a Tailscale address wins the banner slot."""
    addresses = run_mod.discover_ipv4_addresses()
    assert "127.0.0.1" not in addresses
    if any(run_mod.is_tailscale_ip(a) for a in addresses):
        assert run_mod.is_tailscale_ip(run_mod.preferred_client_ip(addresses))
