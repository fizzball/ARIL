"""Build provider messages including multimodal attachments."""

from __future__ import annotations

import base64
import hashlib
import re
from pathlib import Path

from app.core.schemas import Attachment, ChatMessage
from app.providers.base import ProviderMessage

# Markdown images / raw data URLs — usually generated images retained in history.
_DATA_IMAGE_MD = re.compile(
    r"!\[[^\]]*\]\(data:image\/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=\s]+\)",
    re.IGNORECASE,
)
_DATA_IMAGE_RAW = re.compile(
    r"data:image\/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=\s]{200,}",
    re.IGNORECASE,
)

# Capturing variant used when persisting generated images to disk.
_DATA_IMAGE_MD_CAPTURE = re.compile(
    r"!\[([^\]]*)\]\(data:image\/([a-zA-Z0-9.+-]+);base64,([A-Za-z0-9+/=\s]+)\)",
    re.IGNORECASE,
)


def _images_dir() -> Path:
    from app.core.paths import data_dir

    directory = data_dir() / "GeneratedImages"
    directory.mkdir(parents=True, exist_ok=True)
    return directory


def _image_ext(mime: str) -> str:
    m = mime.lower()
    if "jpeg" in m or "jpg" in m:
        return "jpg"
    if "gif" in m:
        return "gif"
    if "webp" in m:
        return "webp"
    if "heic" in m:
        return "heic"
    return "png"


def persist_inline_images(content: str) -> str:
    """Write inline base64 images to disk and replace them with stable file:// links.

    Used on persistence paths (session store) so generated images survive restarts
    instead of being dropped to a placeholder. Files are content-addressed (sha256)
    and written under the shared ARIL data dir, so the macOS client — which uses the
    same directory and hashing scheme — resolves them to the same on-disk file.
    """
    if not content or "data:image/" not in content:
        return content

    def _replace(match: "re.Match[str]") -> str:
        alt = match.group(1)
        mime = match.group(2)
        b64 = re.sub(r"\s+", "", match.group(3))
        try:
            raw = base64.b64decode(b64, validate=False)
        except Exception:  # noqa: BLE001 — leave malformed payloads untouched
            return match.group(0)
        if not raw:
            return match.group(0)
        digest = hashlib.sha256(raw).hexdigest()[:32]
        path = _images_dir() / f"img-{digest}.{_image_ext(mime)}"
        if not path.exists():
            try:
                path.write_bytes(raw)
            except OSError:
                return match.group(0)
        return f"![{alt}]({path.as_uri()})"

    return _DATA_IMAGE_MD_CAPTURE.sub(_replace, content)

# Soft caps so follow-up turns don't exceed smaller model windows (e.g. 32k).
_MAX_MESSAGE_CHARS = 24_000
_MAX_TOTAL_CHARS = 96_000  # ~24k tokens rough; leave headroom for system/plugins


def sanitize_content_for_context(content: str) -> str:
    """Strip embedded base64 images / huge blobs that blow up chat context."""
    if not content:
        return content
    text = _DATA_IMAGE_MD.sub("![Generated image](omitted-from-context)", content)
    text = _DATA_IMAGE_RAW.sub("data:image/(omitted-from-context)", text)
    if len(text) > _MAX_MESSAGE_CHARS:
        keep = _MAX_MESSAGE_CHARS - 80
        text = text[:keep] + "\n\n…[truncated for model context]"
    return text


def sanitize_chat_messages(messages: list[ChatMessage]) -> list[ChatMessage]:
    """Return a copy of messages safe to send as LLM context."""
    return [
        ChatMessage(role=m.role, content=sanitize_content_for_context(m.content))
        for m in messages
    ]


def trim_provider_messages(
    messages: list[ProviderMessage],
    *,
    max_total_chars: int = _MAX_TOTAL_CHARS,
) -> list[ProviderMessage]:
    """Keep the newest turns within a character budget (drop oldest first)."""
    if not messages:
        return messages

    total = sum(len(m.content or "") for m in messages)
    if total <= max_total_chars:
        return messages

    kept: list[ProviderMessage] = []
    budget = max_total_chars
    # Always try to keep the latest user/assistant turns.
    for m in reversed(messages):
        size = len(m.content or "")
        if kept and size > budget:
            continue
        if size > budget and not kept:
            # Single oversized latest message already sanitized/capped.
            kept.append(m)
            break
        kept.append(m)
        budget -= size
        if budget <= 0:
            break
    kept.reverse()
    if len(kept) < len(messages):
        note = ProviderMessage(
            role="system",
            content="[Earlier conversation turns were omitted to fit the model context window.]",
        )
        return [note] + kept
    return kept


def attachments_to_provider_messages(
    messages: list[ChatMessage],
    attachments: list[Attachment] | None,
) -> list[ProviderMessage]:
    """Convert chat history; fold attachments into the last user turn."""
    safe = sanitize_chat_messages(messages)
    out: list[ProviderMessage] = []
    last_user_idx = None
    for i, m in enumerate(safe):
        out.append(ProviderMessage(role=m.role, content=m.content))
        if m.role == "user":
            last_user_idx = i

    if not attachments or last_user_idx is None:
        return trim_provider_messages(out)

    text_bits: list[str] = [safe[last_user_idx].content]
    parts: list[dict] = []
    has_image = False

    for att in attachments:
        mime = (att.mime_type or "application/octet-stream").lower()
        if mime.startswith("image/"):
            has_image = True
            parts.append(
                {
                    "type": "image_url",
                    "image_url": {
                        "url": f"data:{mime};base64,{att.data_base64}",
                    },
                }
            )
        else:
            # Text-ish files: decode and inline (cap size)
            try:
                raw = base64.b64decode(att.data_base64)
                if mime.startswith("text/") or att.filename.endswith(
                    (".txt", ".md", ".json", ".csv", ".py", ".swift", ".ts", ".js", ".html", ".css")
                ):
                    snippet = raw.decode("utf-8", errors="replace")
                    if len(snippet) > 80_000:
                        snippet = snippet[:80_000] + "\n…[truncated]"
                    text_bits.append(f"\n\n--- Attached file: {att.filename} ---\n{snippet}")
                else:
                    text_bits.append(
                        f"\n\n[Attached binary file: {att.filename} ({mime}, {len(raw)} bytes) — "
                        "content not inlined.]"
                    )
            except Exception:  # noqa: BLE001
                text_bits.append(f"\n\n[Could not read attachment: {att.filename}]")

    combined = "".join(text_bits).strip() or "(see attachments)"
    if has_image:
        parts.insert(0, {"type": "text", "text": combined})
        out[last_user_idx] = ProviderMessage(role="user", content=combined, parts=parts)
    else:
        out[last_user_idx] = ProviderMessage(role="user", content=combined)

    return trim_provider_messages(out)
