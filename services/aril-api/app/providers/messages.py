"""Build provider messages including multimodal attachments."""

from __future__ import annotations

import base64

from app.core.schemas import Attachment, ChatMessage
from app.providers.base import ProviderMessage


def attachments_to_provider_messages(
    messages: list[ChatMessage],
    attachments: list[Attachment] | None,
) -> list[ProviderMessage]:
    """Convert chat history; fold attachments into the last user turn."""
    out: list[ProviderMessage] = []
    last_user_idx = None
    for i, m in enumerate(messages):
        out.append(ProviderMessage(role=m.role, content=m.content))
        if m.role == "user":
            last_user_idx = i

    if not attachments or last_user_idx is None:
        return out

    text_bits: list[str] = [messages[last_user_idx].content]
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

    return out
