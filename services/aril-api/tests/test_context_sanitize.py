"""Unit tests for chat-context sanitization (base64 image / size blow-up)."""

from app.core.schemas import ChatMessage
from app.providers.messages import (
    attachments_to_provider_messages,
    sanitize_content_for_context,
)


def test_sanitize_strips_markdown_data_image():
    huge_b64 = "A" * 50_000
    content = f"Here you go:\n\n![Generated image](data:image/png;base64,{huge_b64})\n\nEnjoy."
    out = sanitize_content_for_context(content)
    assert "base64," not in out
    assert "omitted-from-context" in out
    assert "Enjoy." in out
    assert len(out) < 500


def test_provider_messages_drop_historical_images():
    huge_b64 = "B" * 200_000
    prior = ChatMessage(
        role="assistant",
        content=f"![Generated image](data:image/png;base64,{huge_b64})",
    )
    user = ChatMessage(role="user", content="Now describe that image briefly.")
    msgs = attachments_to_provider_messages([prior, user], None)
    joined = " ".join(m.content for m in msgs)
    assert "base64," not in joined
    assert len(joined) < 5_000
