import main;

// This shader takes no vertices. Instead, it reads
// sprite data and outputs a position based on the vertex index.

struct Scene {
    float4x4 view;
    float4x4 projection;
    float4x4 view_projection;
}

struct Sprite {
    // 16 floats
    static const uint size = 4 * 16;

    float3 world_position;
    float  _padding;
    float2 rotation;
    float2 scale;
    float4 uv; // [ u_0, u_1, v_0, v_1 ]
    float4 color;
};

struct BillboardOut {
    float4 position: SV_Position;
    float4 color;
    float2 uv;
};

float3 billboard_adjust(float2 position, float2 rotation, float4x4 view) {
    float3 camera_up = float3(view[0][1], view[1][1], view[2][1]);
    float3 camera_right = float3(view[0][0], view[1][0], view[2][0]);

    return billboard_adjust_with_right_up(position, 0.0, rotation, camera_right, camera_up);

}

float3 billboard_adjust_with_right_up(float2 position, float2 offset, float2 rotation, float3 right, float3 up) {
    var p = position - offset;
    p = float2(p.x * rotation.x - p.y * rotation.y,
               p.y * rotation.x + p.x * rotation.y);

    let position_world = right * p.x +
                         up    * p.y;

    return position_world;
}


[vk::binding(0, 0)]
StructuredBuffer<Scene> scene_buffer;

[vk::binding(1, 0)]
ByteAddressBuffer sprites;

[vk::binding(0, 1)]
ConstantBuffer<int> instance_offset;

static const int indices[6] = { 0, 1, 2, 3, 2, 1 };

static const float2 vertex_position_buffer[4] = {
    { 0.0, -1.0f },
    { 1.0f, -1.0f },
    { 0.0f, 0.0f },
    { 1.0f, 0.0f },
};

[shader("vertex")]
BillboardOut vertex_main(uint idx: SV_VertexID) {
    int instance_idx = (idx / 6);
    int vertex_idx = indices[idx % 6];

    Scene scene = scene_buffer[0];
    Sprite sprite = sprites.Load<Sprite>(instance_offset + instance_idx * Sprite.size);

    float3 world_position = sprite.world_position;

    float4x4 view = scene.view;
    float3 camera_right = float3(view[0][0], view[1][0], view[2][0]);
    float3 camera_up = float3(view[0][1], view[1][1], view[2][1]);

    let th = sprite.rotation;
    let offset = vertex_position_buffer[vertex_idx] * sprite.scale;
    let position = billboard_adjust_with_right_up(offset, 0, th, camera_right, camera_up);

    let position_world = float4(world_position + position, 1.0);

    float2 uv_lookup[4] = {
        { sprite.uv[0], sprite.uv[3] },
        { sprite.uv[1], sprite.uv[3] },
        { sprite.uv[0], sprite.uv[2] },
        { sprite.uv[1], sprite.uv[2] },
    };

    var output: BillboardOut;
    output.position = mul(position_world, scene.view_projection);
    output.color = sprite.color;
    output.uv = uv_lookup[vertex_idx];

    return output;
}

[vk::binding(0, 2)]
Sampler2D tex_sprites;

[shader("fragment")]
float4 fragment_main(BillboardOut input): SV_Target {
    let albedo = tex_sprites.Sample(input.uv);
    let frag_color = albedo * input.color;
    return frag_color;
};
