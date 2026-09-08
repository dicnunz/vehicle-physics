shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 surface_tint : source_color = vec4(0.4,0.38,0.35,1.0);
uniform sampler2D grain_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grain_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grain_roughness : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D contact_ao : hint_default_white, filter_linear_mipmap, repeat_disable;
uniform vec2 grain_uv_scale = vec2(1.0);
uniform vec2 roughness_range = vec2(0.62,0.90);
uniform float normal_strength = 0.35;
uniform float color_variation = 0.70;
uniform float surface_specular = 0.25;
uniform float color_coarse_lod = 5.0;
uniform float normal_coarse_lod = 5.0;

float footprint_lod(vec2 coordinates, ivec2 dimensions) {
    vec2 dx = dFdx(coordinates) * vec2(dimensions);
    vec2 dy = dFdy(coordinates) * vec2(dimensions);
    return 0.5 * log2(max(max(dot(dx,dx),dot(dy,dy)),1.0));
}

void fragment() {
    vec2 coordinates = UV * grain_uv_scale;
    float color_lod = max(color_coarse_lod,footprint_lod(coordinates,textureSize(grain_color,0))+1.5);
    float normal_lod = max(normal_coarse_lod,footprint_lod(coordinates,textureSize(grain_normal,0))+1.5);
    vec3 color = texture(grain_color,coordinates).rgb;
    vec3 local_average = textureLod(grain_color,coordinates,color_lod).rgb;
    const vec3 luminance = vec3(0.2126,0.7152,0.0722);
    float grain_ratio = dot(color,luminance) / max(dot(local_average,luminance),0.005);
    float tonal_variation = 1.0 + color_variation * clamp((grain_ratio-1.0)*2.0,-0.42,0.42);
    ALBEDO = surface_tint.rgb * tonal_variation;
    vec2 fine_normal = texture(grain_normal,coordinates).rg;
    vec2 broad_normal = textureLod(grain_normal,coordinates,normal_lod).rg;
    vec2 normal_xy = (fine_normal-broad_normal)*2.0;
    NORMAL_MAP = vec3(normal_xy*0.5+0.5,sqrt(max(1.0-dot(normal_xy,normal_xy),0.01))*0.5+0.5);
    NORMAL_MAP_DEPTH = normal_strength;
    float photographed_roughness = texture(grain_roughness,coordinates).g;
    ROUGHNESS = mix(roughness_range.x,roughness_range.y,smoothstep(0.22,0.86,photographed_roughness));
    METALLIC = 0.0;
    SPECULAR = surface_specular;
    AO = texture(contact_ao,UV2).r;
    AO_LIGHT_AFFECT = 0.22;
}
