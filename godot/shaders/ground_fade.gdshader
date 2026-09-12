shader_type canvas_item;

// 舞台地面渐隐阴影(#11 视觉重构):底部收敛的椭圆软阴影,
// 给立绘一个"站在地上"的落点,替代网页式描边卡片。

uniform float shadow_intensity : hint_range(0.0, 1.0) = 0.40;

void fragment() {
	float vertical = smoothstep(0.1, 0.95, UV.y);
	float horizontal = 1.0 - pow(abs(UV.x - 0.5) * 2.0, 1.6);
	float alpha = shadow_intensity * vertical * horizontal;
	COLOR = vec4(0.02, 0.01, 0.03, alpha);
}
