"""Static checks for docker-compose.yml: required services, healthchecks, volumes, pinned images, no secrets."""
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
failures = []


def check(cond, msg):
    print(("  PASS  " if cond else "  FAIL  ") + msg)
    if not cond:
        failures.append(msg)


compose = yaml.safe_load((ROOT / "docker-compose.yml").read_text())
services = compose.get("services", {})

for name in ("postgres", "n8n", "caddy"):
    check(name in services, f"service '{name}' defined")

for name, svc in services.items():
    check("healthcheck" in svc, f"{name}: has a healthcheck")
    check(svc.get("restart") == "unless-stopped", f"{name}: restart=unless-stopped")
    image = svc.get("image", "")
    check(not image.endswith(":latest") and ":" in image, f"{name}: image tag pinned ({image})")

check(services["n8n"]["depends_on"]["postgres"]["condition"] == "service_healthy",
      "n8n waits for a healthy postgres")
check("ports" not in services["n8n"] and "ports" not in services["postgres"],
      "only the proxy publishes ports (n8n and postgres stay private)")
check(sorted(services["caddy"]["ports"]) == ["443:443", "80:80"], "proxy publishes only 80 and 443")
check(compose["networks"]["backend"].get("internal") is True, "backend network is internal")

declared = set(compose.get("volumes", {}))
for vol in ("postgres_data", "n8n_data", "caddy_data"):
    check(vol in declared, f"named volume '{vol}' declared")

env = services["n8n"]["environment"]
for key in ("N8N_HOST", "N8N_PROTOCOL", "WEBHOOK_URL", "N8N_ENCRYPTION_KEY", "DB_TYPE", "N8N_SECURE_COOKIE"):
    check(key in env, f"n8n env sets {key}")
check(env["N8N_PROTOCOL"] == "https", "n8n protocol is https")
check(env["N8N_ENCRYPTION_KEY"] == "${N8N_ENCRYPTION_KEY}", "encryption key comes from .env")

raw = (ROOT / "docker-compose.yml").read_text()
secret_like = re.findall(r"(PASSWORD|KEY|SECRET)\s*:\s*(?!\$\{)[^\s\"']+", raw)
check(not secret_like, "no hardcoded secrets in docker-compose.yml")

example = (ROOT / ".env.example").read_text()
used = set(re.findall(r"\$\{([A-Z0-9_]+)\}", raw))
defined = set(re.findall(r"^([A-Z0-9_]+)=", example, re.M))
check(used <= defined, f".env.example defines every variable compose uses ({len(used)} vars)")

gitignore = (ROOT / ".gitignore").read_text().split()
check(".env" in gitignore, ".env is git-ignored")

print(f"compose checks: {len(failures)} failed")
sys.exit(1 if failures else 0)
