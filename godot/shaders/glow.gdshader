shader_type canvas_item;

uniform vec4 glow_color : source_color = vec4(1.0, 1.0, 1.0, 0.1);
uniform float radius : hint_range(0.0, 1.0) = 0.6;

void fragment() {
	vec2 uv = UV - 0.5;
	float dist = length(uv) * 2.0;
	float alpha = smoothstep(radius, 0.0, dist) * glow_color.a;
	COLOR = vec4(glow_color.rgb, alpha);
}
