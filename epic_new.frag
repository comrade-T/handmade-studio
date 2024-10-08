#version 330 core

uniform float time;
uniform vec2 resolution;
uniform sampler2D texture0;

out vec4 finalColor;
in vec2 fragTexCoord;
in vec4 fragColor;

vec3 hsl2rgb(vec3 c) {
    vec3 rgb = clamp(abs(mod(c.x*6.0+vec3(0.0,4.0,2.0),6.0)-3.0)-1.0, 0.0, 1.0);
    return c.z + c.y * (rgb-0.5)*(1.0-abs(2.0*c.z-1.0));
}

void main() {
    vec4 tc = texture(texture0, fragTexCoord);
    float d = tc.r;
    float aaf = fwidth(d);
    float alpha = smoothstep(0.5 - aaf, 0.5 + aaf, d);
    vec2 frag_uv = fragTexCoord.xy / resolution;
    vec4 rainbow = vec4(hsl2rgb(vec3((time + fragColor.x + fragColor.y), 0.5, 0.5)), 1.0);
    finalColor = vec4(rainbow.rgb, alpha);
}
