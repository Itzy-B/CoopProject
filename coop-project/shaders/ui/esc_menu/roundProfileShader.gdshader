shader_type canvas_item;

void fragment() {
    float distance_from_center = length(UV - vec2(0.5));
    float mask = 1.0 - smoothstep(0.48, 0.5, distance_from_center);

    COLOR.a *= mask;
}