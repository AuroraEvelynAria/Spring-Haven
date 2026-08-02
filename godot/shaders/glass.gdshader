shader_type canvas_item;

uniform vec4 tint_color : source_color = vec4(0.1, 0.08, 0.07, 1.0);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.28;

void fragment() {
	vec4 source = COLOR;
	// Sampling the screen from several overlapping Control nodes creates a
	// feedback loop on the GL compatibility renderer. It shows up as flashing
	// panels during scene changes and viewport resizes. A stable translucent
	// tint keeps the glass look without reading the framebuffer.
	vec3 glass_color = mix(source.rgb, tint_color.rgb, tint_strength);
	COLOR = vec4(glass_color, source.a);
}
