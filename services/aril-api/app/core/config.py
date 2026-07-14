from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    aril_env: str = "development"
    aril_host: str = "127.0.0.1"
    aril_port: int = 8741
    aril_log_level: str = "info"
    aril_default_temperature: float = 0.7
    aril_cache_token_threshold: int = 1024
    aril_rewrite_model: str = "openai/gpt-4.1-mini"
    aril_compare_model_count: int = 3

    # Primary: OpenRouter (one key → many models)
    openrouter_api_key: str = ""
    openrouter_base_url: str = "https://openrouter.ai/api/v1"
    openrouter_site_url: str = "https://github.com/fizzball/ARIL"
    openrouter_app_name: str = "ARIL"

    # Optional direct providers (unused when OpenRouter is configured)
    openai_api_key: str = ""
    anthropic_api_key: str = ""
    ollama_base_url: str = "http://127.0.0.1:11434"


settings = Settings()
