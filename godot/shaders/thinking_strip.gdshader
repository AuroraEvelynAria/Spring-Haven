shader_type canvas_item;

uniform vec4 color_a : source_color = vec4(0.96, 0.45, 0.24, 1.0);
uniform vec4 color_b : source_color = vec4(0.72, 0.65, 0.90, 1.0);
uniform float speed = 0.24;

void fragment() {
	float phase = UV.x * 2.4 - TIME * speed;
	float wave = 0.5 + 0.5 * sin(phase * 6.2831853);
	float edge_fade = smoothstep(0.0, 0.08, UV.x) * smoothstep(0.0, 0.08, 1.0 - UV.x);
	vec4 tint = mix(color_a, color_b, wave);
	COLOR = vec4(tint.rgb, (0.34 + wave * 0.50) * edge_fade);
}
