# Attachments & web search

## Attachments
- Paperclip in the input bar opens a file picker (images + common docs).
- Images are sent as multimodal content via OpenRouter.
- Text-like files are inlined into the prompt (truncated ~80KB).
- Max ~8MB per file.

## Web search
Toggle **Web** next to Auto/Manual/Compare.

ARIL enables OpenRouter’s **`web` plugin** on that request (`plugins: [{ "id": "web" }]`).  
The selected model then retrieves live web context before answering.

Notes:
- Requires `OPENROUTER_API_KEY` and OpenRouter account/model support for the plugin.
- Adds latency and cost vs plain chat.
- Not used for preview grading; only on send/stream.
- Future option: dedicated Brave/Tavily search tool + cite URLs in the UI.
