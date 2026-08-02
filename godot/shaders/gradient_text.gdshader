shader_type canvas_item;

uniform vec4 color_a : source_color = vec4(0.96, 0.66, 0.50, 1.0);
uniform vec4 color_b : source_color = vec4(0.90, 0.79, 0.48, 1.0);
uniform float flow_speed : hint_range(0.0, 1.0) = 0.10;

void fragment() {
	vec4 glyph = texture(TEXTURE, UV);
	float drift = sin(TIME * flow_speed + UV.x * 3.14159265) * 0.10;
	float across_title = smoothstep(0.18, 0.82, UV.x + drift);
	vec4 gradient = mix(color_a, color_b, across_title);
	COLOR = vec4(gradient.rgb, glyph.a * COLOR.a);
}
