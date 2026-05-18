import asyncio
import hashlib
import hmac
import logging
import os
import time

import docker
import jwt as _jwt
import requests as _requests
from fastapi import FastAPI, HTTPException, Request
from github import GithubIntegration

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

app = FastAPI()
docker_client = docker.from_env()

_private_key = os.environ["GITHUB_APP_PRIVATE_KEY"].replace("\\n", "\n")
_app_id = int(os.environ["GITHUB_APP_ID"])
gi = GithubIntegration(_app_id, _private_key)

MAX_RUNNERS = int(os.getenv("MAX_RUNNERS") or os.cpu_count())
RUNNER_IDLE_TIMEOUT = int(os.getenv("RUNNER_IDLE_TIMEOUT", "600"))
RUNNER_JOB_TIMEOUT = int(os.getenv("RUNNER_JOB_TIMEOUT", "7200"))
RUNNER_POLL_INTERVAL = int(os.getenv("RUNNER_POLL_INTERVAL", "15"))
# Alert via Telegram if a runner hasn't picked up a job within this many seconds.
RUNNER_IDLE_ALERT_SECS = int(os.getenv("RUNNER_IDLE_ALERT_SECS", "300"))
sem = asyncio.Semaphore(MAX_RUNNERS)
DEFAULT_IMAGE = os.environ["DEFAULT_RUNNER_IMAGE"]
ALLOWED_ORGS: set[str] = set(filter(None, os.getenv("ALLOWED_ORGS", "").split(",")))
# Master mode: set SLAVE_URL to forward overflow jobs to the slave server.
SLAVE_URL = os.getenv("SLAVE_URL", "").rstrip("/")

_TG_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "")
_TG_CHAT = os.getenv("TELEGRAM_CHAT_ID", "")

_GITHUB_HOSTED = {
    "ubuntu-latest", "ubuntu-24.04", "ubuntu-22.04", "ubuntu-20.04", "ubuntu-18.04",
    "windows-latest", "windows-2022", "windows-2019",
    "macos-latest", "macos-14", "macos-13", "macos-12",
}
_NON_LINUX_OS = {"Windows", "macOS"}

log.info(
    "Build server starting: mode=%s MAX_RUNNERS=%d IDLE_TIMEOUT=%ds JOB_TIMEOUT=%ds DEFAULT_IMAGE=%s ALLOWED_ORGS=%s",
    "master" if SLAVE_URL else "slave/standalone",
    MAX_RUNNERS, RUNNER_IDLE_TIMEOUT, RUNNER_JOB_TIMEOUT, DEFAULT_IMAGE, ALLOWED_ORGS or "unrestricted",
)


def _tg_notify(text: str) -> None:
    if not _TG_TOKEN or not _TG_CHAT:
        return
    try:
        _requests.post(
            f"https://api.telegram.org/bot{_TG_TOKEN}/sendMessage",
            json={"chat_id": _TG_CHAT, "text": text, "parse_mode": "HTML"},
            timeout=10,
        )
    except Exception:
        log.exception("Telegram notification failed")


def _parse_image(labels: list[str]) -> str:
    for lbl in labels:
        if lbl.startswith("runner-image:"):
            return lbl.removeprefix("runner-image:")
    return DEFAULT_IMAGE


def _verify_signature(body: bytes, header: str) -> None:
    secret = os.environ["WEBHOOK_SECRET"].encode()
    expected = "sha256=" + hmac.new(secret, body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(header, expected):
        raise HTTPException(status_code=401, detail="invalid signature")


def _resolve_installation_id(org: str, owner_type: str) -> int | None:
    now = int(time.time())
    token = _jwt.encode({"iat": now - 60, "exp": now + 600, "iss": str(_app_id)}, _private_key, algorithm="RS256")
    segment = "users" if owner_type == "User" else "orgs"
    url = f"https://api.github.com/{segment}/{org}/installation"
    resp = _requests.get(
        url,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
        timeout=10,
    )
    if resp.ok:
        return resp.json()["id"]
    log.warning("Installation lookup failed for org=%s: %s", org, resp.text[:200])
    return None


@app.get("/capacity")
async def capacity():
    active = MAX_RUNNERS - sem._value  # noqa: SLF001
    return {"active": active, "max": MAX_RUNNERS, "available": sem._value}


@app.post("/webhook")
async def webhook(request: Request):
    body = await request.body()
    _verify_signature(body, request.headers.get("X-Hub-Signature-256", ""))

    payload = await request.json()
    action = payload.get("action")
    if action != "queued" or "workflow_job" not in payload:
        return {"ok": True}

    installation_id = (payload.get("installation") or {}).get("id")
    org = payload["repository"]["owner"]["login"]
    owner_type = payload["repository"]["owner"].get("type", "Organization")
    repo_full_name = payload["repository"]["full_name"]
    labels: list[str] = payload["workflow_job"].get("labels", [])
    job_id = payload["workflow_job"]["id"]

    if ALLOWED_ORGS and org not in ALLOWED_ORGS:
        log.warning("Ignored job from unlisted org=%s job_id=%d", org, job_id)
        return {"ok": True}

    if all(lbl in _GITHUB_HOSTED for lbl in labels):
        return {"ok": True}

    if any(lbl in _NON_LINUX_OS for lbl in labels):
        log.info("Skipped non-Linux job: org=%s job_id=%d labels=%s", org, job_id, labels)
        return {"ok": True}

    if not installation_id:
        installation_id = _resolve_installation_id(org, owner_type)
    if not installation_id:
        log.warning("Could not resolve installation_id for org=%s job_id=%d — skipping", org, job_id)
        return {"ok": True}

    log.info("Job queued: org=%s job_id=%d labels=%s", org, job_id, labels)

    # Master mode: if we're at capacity, forward to slave.
    if SLAVE_URL and sem._value == 0:  # noqa: SLF001
        log.info("Master full, forwarding job to slave: org=%s job_id=%d", org, job_id)
        asyncio.create_task(_forward_to_slave(body, request.headers))
        return {"ok": True}

    asyncio.create_task(spawn_runner(installation_id, org, owner_type, repo_full_name, labels, job_id))
    return {"ok": True}


async def _forward_to_slave(body: bytes, headers) -> None:
    loop = asyncio.get_event_loop()
    try:
        await loop.run_in_executor(None, lambda: _requests.post(
            f"{SLAVE_URL}/webhook",
            data=body,
            headers={
                "Content-Type": "application/json",
                "X-Hub-Signature-256": headers.get("x-hub-signature-256", ""),
                "X-GitHub-Event": headers.get("x-github-event", "workflow_job"),
            },
            timeout=10,
        ))
        log.info("Forwarded job to slave: %s", SLAVE_URL)
    except Exception:
        log.exception("Failed to forward job to slave %s", SLAVE_URL)


async def spawn_runner(
    installation_id: int, org: str, owner_type: str,
    repo_full_name: str, labels: list[str], job_id: int,
):
    async with sem:
        active = MAX_RUNNERS - sem._value  # noqa: SLF001
        log.info("Spawning runner: org=%s job_id=%d active=%d/%d", org, job_id, active, MAX_RUNNERS)
        try:
            token = gi.get_access_token(installation_id).token
        except Exception:
            log.exception("Failed to get installation token for installation_id=%d", installation_id)
            return

        image = _parse_image(labels)
        custom_labels = [lbl for lbl in labels if lbl not in _GITHUB_HOSTED]

        if owner_type == "User":
            env = {
                "RUNNER_SCOPE": "repo",
                "REPO_URL": f"https://github.com/{repo_full_name}",
                "ACCESS_TOKEN": token,
                "EPHEMERAL": "true",
                "DISABLE_AUTO_UPDATE": "true",
                "LABELS": ",".join(custom_labels),
            }
        else:
            env = {
                "RUNNER_SCOPE": "org",
                "ORG_NAME": org,
                "ACCESS_TOKEN": token,
                "EPHEMERAL": "true",
                "DISABLE_AUTO_UPDATE": "true",
                "LABELS": ",".join(custom_labels),
            }

        loop = asyncio.get_event_loop()
        try:
            container = await loop.run_in_executor(
                None,
                lambda: docker_client.containers.run(
                    image,
                    detach=True,
                    user="root",
                    volumes={"/var/run/docker.sock": {"bind": "/var/run/docker.sock", "mode": "rw"}},
                    environment=env,
                ),
            )
        except Exception:
            log.exception("Runner start failed: org=%s job_id=%d image=%s", org, job_id, image)
            return

        start = asyncio.get_event_loop().time()
        job_started_at: float | None = None
        idle_alerted = False
        try:
            while True:
                await asyncio.sleep(RUNNER_POLL_INTERVAL)
                try:
                    await loop.run_in_executor(None, container.reload)
                except docker.errors.NotFound:
                    log.info("Runner container gone: org=%s job_id=%d", org, job_id)
                    return
                if container.status != "running":
                    result = await loop.run_in_executor(None, container.wait)
                    log.info(
                        "Runner finished: org=%s job_id=%d exit=%d",
                        org, job_id, result.get("StatusCode", -1),
                    )
                    break

                now = asyncio.get_event_loop().time()
                elapsed = now - start
                if job_started_at is None:
                    try:
                        logs = await loop.run_in_executor(
                            None, lambda: container.logs().decode("utf-8", "replace")
                        )
                    except Exception:
                        logs = ""
                    if "Running job:" in logs:
                        job_started_at = now
                        log.info("Runner picked up job: org=%s job_id=%d", org, job_id)
                    else:
                        if not idle_alerted and elapsed >= RUNNER_IDLE_ALERT_SECS:
                            idle_alerted = True
                            msg = (
                                f"⚠️ <b>Build server alert</b>\n"
                                f"Runner for <code>{org}</code> job <code>{job_id}</code> "
                                f"has been idle {int(elapsed)}s without picking up a job.\n"
                                f"Labels: <code>{', '.join(labels)}</code>\n"
                                f"Image: <code>{image}</code>"
                            )
                            log.warning("Sending idle alert: org=%s job_id=%d elapsed=%ds", org, job_id, int(elapsed))
                            await loop.run_in_executor(None, lambda: _tg_notify(msg))
                        if elapsed > RUNNER_IDLE_TIMEOUT:
                            log.warning(
                                "Runner idle %ds without a job: org=%s job_id=%d — killing",
                                RUNNER_IDLE_TIMEOUT, org, job_id,
                            )
                            await loop.run_in_executor(None, container.kill)
                            break
                elif now - job_started_at > RUNNER_JOB_TIMEOUT:
                    log.warning(
                        "Job exceeded %ds: org=%s job_id=%d — killing",
                        RUNNER_JOB_TIMEOUT, org, job_id,
                    )
                    await loop.run_in_executor(None, container.kill)
                    break
        except Exception:
            log.exception("Runner wait failed: org=%s job_id=%d", org, job_id)
        finally:
            try:
                await loop.run_in_executor(None, lambda: container.remove(force=True))
            except Exception:
                pass
