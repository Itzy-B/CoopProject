shader_type canvas_item;
render_mode unshaded;

uniform float fade_height : hint_range(0.001, 0.25) = 0.05;
uniform bool fade_top = false;
uniform bool fade_bottom = false;

void fragment() {
    float mask = 1.0;

    if (fade_top) {
        mask *= smoothstep(0.0, fade_height, UV.y);
    }

    if (fade_bottom) {
        mask *= smoothstep(0.0, fade_height, 1.0 - UV.y);
    }

    COLOR.a *= mask;
}