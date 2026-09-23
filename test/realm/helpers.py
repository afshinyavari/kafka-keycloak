"""Helpers for rendering the chart and extracting the generated realm."""
import copy
import os
import subprocess
import tempfile

import yaml

CHART = os.path.join(os.path.dirname(__file__), "..", "..", "charts", "kafka-keycloak-realm")
RELEASE = "kc"

BASE_VALUES = {
    "keycloak": {"url": "https://sso.example.com", "existingSecret": "kcc-creds"},
    "realm": {"name": "kafka-test"},
    "identityProvider": {"enabled": False},
    "teams": {},
}


def deep_merge(base, override):
    out = copy.deepcopy(base)
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = copy.deepcopy(v)
    return out


def helm_template(values, values_files=()):
    """Run helm template. Returns (returncode, stdout, stderr)."""
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        yaml.safe_dump(values, f)
        path = f.name
    cmd = ["helm", "template", RELEASE, CHART]
    for vf in values_files:
        cmd += ["-f", vf]
    cmd += ["-f", path]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True)
    finally:
        os.unlink(path)
    return p.returncode, p.stdout, p.stderr


def render_manifests(overrides=None, values_files=(), base=BASE_VALUES):
    values = deep_merge(base, overrides or {})
    rc, out, err = helm_template(values, values_files)
    if rc != 0:
        raise AssertionError("helm template failed:\n" + err)
    return [d for d in yaml.safe_load_all(out) if d]


def find(manifests, kind, name=None):
    for m in manifests:
        if m["kind"] == kind and (name is None or m["metadata"]["name"] == name):
            return m
    raise AssertionError(f"no {kind} {name or ''} in rendered output")


def render_realm(overrides=None, values_files=(), base=BASE_VALUES):
    cm = find(render_manifests(overrides, values_files, base), "ConfigMap", f"{RELEASE}-realm")
    return yaml.safe_load(cm["data"]["realm.yaml"])


def render_error(overrides=None, base=BASE_VALUES):
    """Render expecting failure; return stderr."""
    values = deep_merge(base, overrides or {})
    rc, out, err = helm_template(values)
    if rc == 0:
        raise AssertionError("expected helm template to fail but it succeeded")
    return err


def by_name(items, name):
    for it in items:
        if it.get("name") == name:
            return it
    raise AssertionError(f"no item named {name!r} in {[i.get('name') for i in items]}")
