// unit_tint.gdshader
// Desaturates and darkens a unit sprite once it has finished acting this
// phase (the genre's "done" greying). unit.gd drives the uniforms;
// at the defaults the sprite renders unchanged.
shader_type canvas_item;

uniform float saturation : hint_range(0.0, 1.0) = 1.0;
uniform float brightness : hint_range(0.0, 1.0) = 1.0;

void fragment() {
    vec4 tex = texture(TEXTURE, UV);
    float grey = dot(tex.rgb, vec3(0.299, 0.587, 0.114));
    vec3 tinted = mix(vec3(grey), tex.rgb, saturation) * brightness;
    COLOR = vec4(tinted, tex.a) * COLOR;
}
