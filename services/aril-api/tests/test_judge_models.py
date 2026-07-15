from fastapi.testclient import TestClient

from app.core.schemas import RouteCategory, RoutingProfile
from app.main import app
from app.routing.pipeline import (
    CATEGORY_RECOMMENDATIONS,
    IMAGE_GEN_MODEL,
    IMAGE_GEN_RECOMMENDATIONS,
    classify,
    select_judge_models,
)

client = TestClient(app)


def test_select_judge_models_vision_peers():
    prompt = "Please OCR this screenshot and extract the table"
    classification = classify(prompt)
    assert classification.primary == RouteCategory.vision

    profile = RoutingProfile().as_map()
    models = select_judge_models(prompt, classification.primary, profile=profile, count=3)
    assert len(models) == 3
    assert models[0] == profile[RouteCategory.vision]
    # Remaining picks should all be known vision-capable peers or the primary.
    allowed = set(CATEGORY_RECOMMENDATIONS[RouteCategory.vision]) | {profile[RouteCategory.vision]}
    assert set(models).issubset(allowed)


def test_select_judge_models_image_gen_peers():
    prompt = "Generate an image of a red sailboat at sunset"
    classification = classify(prompt)
    assert classification.primary == RouteCategory.vision
    models = select_judge_models(prompt, classification.primary, count=3)
    assert IMAGE_GEN_MODEL in models
    assert set(models).issubset(set(IMAGE_GEN_RECOMMENDATIONS) | {IMAGE_GEN_MODEL})


def test_select_judge_models_coding_peers():
    prompt = "Refactor this Python module and add unit tests please"
    classification = classify(prompt)
    assert classification.primary == RouteCategory.coding
    models = select_judge_models(prompt, classification.primary, count=3)
    assert len(models) == 3
    allowed = set(CATEGORY_RECOMMENDATIONS[RouteCategory.coding]) | set(
        RoutingProfile().as_map().values()
    )
    assert set(models).issubset(allowed)


def test_compare_auto_selects_capability_peers():
    prompt = "Describe what you see in this diagram and chart carefully"
    r = client.post(
        "/v1/compare",
        json={
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0,
            "run_probe": False,
        },
    )
    assert r.status_code == 200
    body = r.json()
    assert body["route_category"] == "vision"
    models = [row["model"] for row in body["results"]]
    assert len(models) == 3
    allowed = set(CATEGORY_RECOMMENDATIONS[RouteCategory.vision]) | {
        RoutingProfile().as_map()[RouteCategory.vision]
    }
    for mid in models:
        assert mid in allowed
