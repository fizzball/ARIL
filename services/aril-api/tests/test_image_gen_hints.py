"""Image-generation prompt detection."""

from app.routing.pipeline import wants_image_generation


def test_classic_image_prompts():
    assert wants_image_generation("draw me an image of the moon")
    assert wants_image_generation("generate an image of a cat")
    assert wants_image_generation("create a picture showing the sunset")


def test_bitmap_and_pixel_art_prompts():
    assert wants_image_generation("make a bitmap of a cat")
    assert wants_image_generation("draw a bitmap")
    assert wants_image_generation("pixel art of a dragon")
    assert wants_image_generation("create a bitmap style picture of a house")
    assert wants_image_generation("generate pixel art of a robot")


def test_non_image_prompts():
    assert not wants_image_generation("explain how bitmaps work")
    assert not wants_image_generation("what is a bitmap?")
    assert not wants_image_generation("I love pixel art")
    assert not wants_image_generation("what is the capital of France?")


def test_draw_a_bitmap_still_matches():
    # verb + bitmap noun (no trailing "of …" required)
    assert wants_image_generation("draw a bitmap")
    assert wants_image_generation("make a bitmap of a cat")
    assert wants_image_generation("pixel art of a dragon")
