shader_type canvas_item;

uniform vec4 color_top : source_color = vec4(0.10, 0.07, 0.05, 1.0);
uniform vec4 color_bottom : source_color = vec4(0.04, 0.03, 0.03, 1.0);
uniform vec4 color_glow : source_color = vec4(0.96, 0.66, 0.50, 1.0);
uniform float motion_speed : hint_range(0.0, 0.2) = 0.055;
uniform float glow_strength : hint_range(0.0, 0.4) = 0.20;

void fragment() {
	vec2 uv = UV;
	float time = TIME * motion_speed;

	// A slow layered drift: visible at a glance, calm enough for a main menu.
	float broad_wave = sin(uv.x * 4.2 + time * 4.0) * 0.055;
	float fine_wave = cos(uv.x * 8.0 - time * 2.6 + uv.y * 2.0) * 0.018;
	float vertical_mix = smoothstep(0.0, 1.0, uv.y + broad_wave + fine_wave);
	vec3 background = mix(color_top.rgb, color_bottom.rgb, vertical_mix);

	vec2 glow_center_a = vec2(
		0.42 + sin(time * 1.35) * 0.14,
		0.40 + cos(time * 0.93) * 0.08
	);
	vec2 delta_a = vec2((uv.x - glow_center_a.x) * 1.22, uv.y - glow_center_a.y);
	float glow_a = exp(-dot(delta_a, delta_a) * 6.2) * glow_strength;

	vec2 glow_center_b = vec2(
		0.76 + cos(time * 0.72) * 0.10,
		0.68 + sin(time * 1.08) * 0.07
	);
	vec2 delta_b = vec2((uv.x - glow_center_b.x) * 1.45, uv.y - glow_center_b.y);
	float glow_b = exp(-dot(delta_b, delta_b) * 10.0) * glow_strength * 0.42;

	background += color_glow.rgb * (glow_a + glow_b);
	COLOR = vec4(background, 1.0);
}
