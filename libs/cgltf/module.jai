// based on https://github.com/napina/jai_cgltf (version 1.13)
// upgraded to a commit after version 1.15 - 08470a2b08980cd3221002a9b2ef29a37e3111dc

cgltf_size :: #type u64;
cgltf_ssize :: #type u64;
cgltf_float :: #type float;
cgltf_int :: #type s32;
cgltf_uint :: #type u32;
cgltf_bool :: #type s32;

cgltf_file_type :: enum s32 {
	cgltf_file_type_invalid;
	cgltf_file_type_gltf;
	cgltf_file_type_glb;
}

cgltf_result :: enum s32 {
	cgltf_result_success;
	cgltf_result_data_too_short;
	cgltf_result_unknown_format;
	cgltf_result_invalid_json;
	cgltf_result_invalid_gltf;
	cgltf_result_invalid_options;
	cgltf_result_file_not_found;
	cgltf_result_io_error;
	cgltf_result_out_of_memory;
	cgltf_result_legacy_gltf;
}

cgltf_memory_options :: struct {
	alloc: #type ( user: *void, size: cgltf_size ) -> *void #c_call;
	free: #type ( user: *void, ptr: *void ) #c_call;
	user_data: *void;
}

cgltf_file_options :: struct {
	read: #type ( memory_options: *cgltf_memory_options, file_options: *cgltf_file_options, path: *u8, size: *cgltf_size, data: **void ) -> cgltf_result;
	release: #type ( memory_options: *cgltf_memory_options, file_options: *cgltf_file_options, data: *void );
	user_data: *void;
}

cgltf_options :: struct {
	type: cgltf_file_type; /* invalid == auto detect */
	json_token_count: cgltf_size; /* 0 == auto */
	memory: cgltf_memory_options;
	file: cgltf_file_options;
}

cgltf_buffer_view_type :: enum s32 {
	cgltf_buffer_view_type_invalid;
	cgltf_buffer_view_type_indices;
	cgltf_buffer_view_type_vertices;
}

cgltf_attribute_type :: enum s32 {
	cgltf_attribute_type_invalid;
	cgltf_attribute_type_position;
	cgltf_attribute_type_normal;
	cgltf_attribute_type_tangent;
	cgltf_attribute_type_texcoord;
	cgltf_attribute_type_color;
	cgltf_attribute_type_joints;
	cgltf_attribute_type_weights;
	cgltf_attribute_type_custom;
}

cgltf_component_type :: enum s32 {
	cgltf_component_type_invalid;
	cgltf_component_type_r_8; /* BYTE */
	cgltf_component_type_r_8u; /* UNSIGNED_BYTE */
	cgltf_component_type_r_16; /* SHORT */
	cgltf_component_type_r_16u; /* UNSIGNED_SHORT */
	cgltf_component_type_r_32u; /* UNSIGNED_INT */
	cgltf_component_type_r_32f; /* FLOAT */
}

cgltf_type :: enum s32 {
	cgltf_type_invalid;
	cgltf_type_scalar;
	cgltf_type_vec2;
	cgltf_type_vec3;
	cgltf_type_vec4;
	cgltf_type_mat2;
	cgltf_type_mat3;
	cgltf_type_mat4;
}

cgltf_primitive_type :: enum s32 {
	cgltf_primitive_type_invalid;
	cgltf_primitive_type_points;
	cgltf_primitive_type_lines;
	cgltf_primitive_type_line_loop;
	cgltf_primitive_type_line_strip;
	cgltf_primitive_type_triangles;
	cgltf_primitive_type_triangle_strip;
	cgltf_primitive_type_triangle_fan;
}

cgltf_alpha_mode :: enum s32 {
	cgltf_alpha_mode_opaque;
	cgltf_alpha_mode_mask;
	cgltf_alpha_mode_blend;
}

cgltf_animation_path_type :: enum s32 {
	cgltf_animation_path_type_invalid;
	cgltf_animation_path_type_translation;
	cgltf_animation_path_type_rotation;
	cgltf_animation_path_type_scale;
	cgltf_animation_path_type_weights;
}

cgltf_interpolation_type :: enum s32 {
	cgltf_interpolation_type_linear;
	cgltf_interpolation_type_step;
	cgltf_interpolation_type_cubic_spline;
}

cgltf_camera_type :: enum s32 {
	cgltf_camera_type_invalid;
	cgltf_camera_type_perspective;
	cgltf_camera_type_orthographic;
}

cgltf_light_type :: enum s32 {
	cgltf_light_type_invalid;
	cgltf_light_type_directional;
	cgltf_light_type_point;
	cgltf_light_type_spot;
}

cgltf_data_free_method :: enum s32 {
	cgltf_data_free_method_none;
	cgltf_data_free_method_file_release;
	cgltf_data_free_method_memory_free;
}

cgltf_extras :: struct {
	start_offset: cgltf_size; /* this field is deprecated and will be removed in the future; use data instead */
	end_offset: cgltf_size; /* this field is deprecated and will be removed in the future; use data instead */
	data: *u8;
}

cgltf_extension :: struct {
	name: *u8;
	data: *u8;
}

cgltf_buffer :: struct {
	name: *u8;
	size: cgltf_size;
	uri: *u8;
	data: *void; /* loaded by cgltf_load_buffers */
	data_free_method: cgltf_data_free_method;
	extras: cgltf_extras;
	extensions_count: cgltf_size;
	extensions: *cgltf_extension;
}

cgltf_meshopt_compression_mode :: enum s32 {
	cgltf_meshopt_compression_mode_invalid;
	cgltf_meshopt_compression_mode_attributes;
	cgltf_meshopt_compression_mode_triangles;
	cgltf_meshopt_compression_mode_indices;
}

cgltf_meshopt_compression_filter :: enum s32 {
	cgltf_meshopt_compression_filter_none;
	cgltf_meshopt_compression_filter_octahedral;
	cgltf_meshopt_compression_filter_quaternion;
	cgltf_meshopt_compression_filter_exponential;
}

cgltf_meshopt_compression :: struct {
	buffer: *cgltf_buffer;
	offset: cgltf_size;
	size: cgltf_size;
	stride: cgltf_size;
	count: cgltf_size;
	mode: cgltf_meshopt_compression_mode;
	filter: cgltf_meshopt_compression_filter;
}

cgltf_buffer_view :: struct {
	name: *u8;
	buffer: *cgltf_buffer;
	offset: cgltf_size;
	size: cgltf_size;
	stride: cgltf_size; /* 0 == automatically determined by accessor */
	type: cgltf_buffer_view_type;
	data: *void; /* overrides buffer->data if present, filled by extensions */
	has_meshopt_compression: cgltf_bool;
	meshopt_compression: cgltf_meshopt_compression;
	extras: cgltf_extras;
	extensions_count: cgltf_size;
	extensions: *cgltf_extension;
}

cgltf_accessor_sparse :: struct {
	count: cgltf_size;
	indices_buffer_view: *cgltf_buffer_view;
	indices_byte_offset: cgltf_size;
	indices_component_type: cgltf_component_type;
	values_buffer_view: *cgltf_buffer_view;
	values_byte_offset: cgltf_size;
}

cgltf_accessor :: struct {
	name: *u8;
	component_type: cgltf_component_type;
	normalized: cgltf_bool;
	type: cgltf_type;
	offset: cgltf_size;
	count: cgltf_size;
	stride: cgltf_size;
	buffer_view: *cgltf_buffer_view;
	has_min: cgltf_bool;
	min: [16]cgltf_float;
	has_max: cgltf_bool;
	max: [16]cgltf_float;
	is_sparse: cgltf_bool;
	sparse: cgltf_accessor_sparse;
	extras: cgltf_extras;
	extensions_count: cgltf_size;
	extensions: *cgltf_extension;
}

cgltf_attribute :: struct {
	name: *u8;
	type: cgltf_attribute_type;
	index: cgltf_int;
	data: *cgltf_accessor;
}

cgltf_image :: struct {
	name: *u8;
	uri: *u8;
	buffer_view: *cgltf_buffer_view;
	mime_type: *u8;
	extras: cgltf_extras;
	extensions_count: cgltf_size;
	extensions: *cgltf_extension;
}

cgltf_filter_type :: enum {
	cgltf_filter_type_undefined :: 0;
	cgltf_filter_type_nearest :: 9728;
	cgltf_filter_type_linear :: 9729;
	cgltf_filter_type_nearest_mipmap_nearest :: 9984;
	cgltf_filter_type_linear_mipmap_nearest :: 9985;
	cgltf_filter_type_nearest_mipmap_linear :: 9986;
	cgltf_filter_type_linear_mipmap_linear :: 9987;
};

cgltf_wrap_mode :: enum {
	cgltf_wrap_mode_clamp_to_edge :: 33071;
	cgltf_wrap_mode_mirrored_repeat :: 33648;
	cgltf_wrap_mode_repeat :: 10497;
};

cgltf_sampler :: struct {
	name: *u8;
	mag_filter: cgltf_filter_type;
	min_filter: cgltf_filter_type;
	wrap_s: cgltf_wrap_mode;
	wrap_t: cgltf_wrap_mode;
	extras: cgltf_extras;
	extensions_count: cgltf_size;
	extensions: *cgltf_extension;
}

cgltf_texture :: struct {
	name: *u8;
	image: *cgltf_image;
	sampler: *cgltf_sampler;
	has_basisu: cgltf_bool;
	basisu_image: *cgltf_image;
	has_webp: cgltf_bool;
	webp_image: *cgltf_image;
	extras: cgltf_extras;
	extensions_count: cgltf_size;
	extensions: *cgltf_extension;
}

cgltf_texture_transform :: struct {
	offset: [2]cgltf_float;
	rotation: cgltf_float;
	scale: [2]cgltf_float;
	has_texcoord: cgltf_bool;
	texcoord: cgltf_int;
}

cgltf_texture_view :: struct {
	texture: *cgltf_texture;
	texcoord: cgltf_int;
	scale: cgltf_float; /* equivalent to strength for occlusion_texture */
	has_transform_: cgltf_bool;
	transform: cgltf_texture_transform;
}

cgltf_pbr_metallic_roughness :: struct {
	base_color_texture: cgltf_texture_view;
	metallic_roughness_texture: cgltf_texture_view;

	base_color_factor: [4]cgltf_float;
	metallic_factor: cgltf_float;
	roughness_factor: cgltf_float;
}

cgltf_pbr_specular_glossiness :: struct {
	diffuse_texture: cgltf_texture_view;
	specular_glossiness_texture: cgltf_texture_view;

	diffuse_factor: [4]cgltf_float;
	specular_factor: [3]cgltf_float;
	glossiness_factor: cgltf_float;
}

cgltf_clearcoat :: struct {
	clearcoat_texture: cgltf_texture_view;
	clearcoat_roughness_texture: cgltf_texture_view;
	clearcoat_normal_texture: cgltf_texture_view;

	clearcoat_factor: cgltf_float;
	clearcoat_roughness_factor: cgltf_float;
}

cgltf_transmission :: struct {
	transmission_texture: cgltf_texture_view;
	transmission_factor: cgltf_float;
}

cgltf_ior :: struct {
	ior: cgltf_float;
}

cgltf_specular :: struct {
	specular_texture: cgltf_texture_view;
	specular_color_texture: cgltf_texture_view;
	specular_color_factor: [3]cgltf_float;
	specular_factor: cgltf_float;
}

cgltf_volume :: struct {
	thickness_texture: cgltf_texture_view;
	thickness_factor: cgltf_float;
	attenuation_color: [3]cgltf_float;
	attenuation_distance: cgltf_float;
}

cgltf_sheen :: struct {
	sheen_color_texture: cgltf_texture_view;
	sheen_color_factor: [3]cgltf_float;
	sheen_roughness_texture: cgltf_texture_view;
	sheen_roughness_factor: cgltf_float;
}

cgltf_emissive_strength :: struct {
	emissive_strength: cgltf_float;
}

cgltf_iridescence :: struct {
	iridescence_factor: cgltf_float;
	iridescence_texture: cgltf_texture_view;
	iridescence_ior: cgltf_float;
	iridescence_thickness_min: cgltf_float;
	iridescence_thickness_max: cgltf_float;
	iridescence_thickness_texture: cgltf_texture_view;
}

cgltf_diffuse_transmission :: struct
{
	diffuse_transmission_texture: cgltf_texture_view;
	diffuse_transmission_factor: cgltf_float;
	diffuse_transmission_color_factor: [3] cgltf_float;
	diffuse_transmission_color_texture: cgltf_texture_view;
};

cgltf_anisotropy :: struct
{
	anisotropy_strength: cgltf_float;
	anisotropy_rotation: cgltf_float;
	anisotropy_texture: cgltf_texture_view;
};

cgltf_dispersion :: struct
{
	dispersion: cgltf_float;
};

cgltf_material :: struct {
	name: *u8;
	has_pbr_metallic_roughness: cgltf_bool;
	has_pbr_specular_glossiness: cgltf_bool;
	has_clearcoat: cgltf_bool;
	has_transmission: cgltf_bool;
	has_volume: cgltf_bool;
	has_ior: cgltf_bool;
	has_specular: cgltf_bool;
	has_sheen: cgltf_bool;
	has_emissive_strength: cgltf_bool;
	has_iridescence: cgltf_bool;
	has_diffuse_transmission: cgltf_bool;
	has_anisotropy: cgltf_bool;
	has_dispersion: cgltf_bool;
	pbr_metallic_roughness: cgltf_pbr_metallic_roughness;
	pbr_specular_glossiness: cgltf_pbr_specular_glossiness;
	clearcoat: cgltf_clearcoat;
	ior: cgltf_ior;
	specular: cgltf_specular;
	sheen: cgltf_sheen;
	transmission: cgltf_transmission;
	volume: cgltf_volume;
	emissive_strength: cgltf_emissive_strength;
	iridescence: cgltf_iridescence;
	diffuse_transmission: cgltf_diffuse_transmission;
	anisotropy: cgltf_anisotropy;
	dispersion: cgltf_dispersion;
	normal_texture: cgltf_texture_view;
	occlusion_texture: cgltf_texture_view;
	emissive_texture: cgltf_texture_view;
	emissive_factor: [3]cgltf_float;
	alpha_mode: cgltf_alpha_mode;
	alpha_cutoff: cgltf_float;
	double_sided: cgltf_bool;
	unlit: cgltf_bool;
	extras: cgltf_extras;
	extensions_count: cgltf_size;
	extensions: *cgltf_extension;
}

cgltf_material_mapping :: struct {
	variant: cgltf_size;
	material: *cgltf_material;
	extras: cgltf_extras;
}

cgltf_morph_target :: struct {
	attributes: *cgltf_attribute;
	attributes_count: cgltf_size;
}

cgltf_draco_mesh_compression :: struct {
	buffer_view: *cgltf_buffer_view;
	attributes: *cgltf_attribute;
	attributes_count: cgltf_size;
}

cgltf_mesh_gpu_instancing :: struct {
	attributes: *cgltf_attribute;
	attributes_count: cgltf_size;
}

cgltf_primitive :: struct {
	type: cgltf_primitive_type;
	indices: *cgltf_accessor;
	material: *cgltf_material;
	attributes: *cgltf_attribute;
	attributes_count: cgltf_size;
	targets: *cgltf_morph_target;
	targets_count: cgltf_size;
	extras: cgltf_extras;
	has_draco_mesh_compression: cgltf_bool;
	draco_mesh_compression: cgltf_draco_mesh_compression;
	mappings: *cgltf_material_mapping;
	mappings_count: cgltf_size;
	extensions_count: cgltf_size;
	extensions: *cgltf_extension;
}

cgltf_mesh :: struct {
	name: *u8;
	primitives: *cgltf_primitive;
	primitives_count: cgltf_size;
	weights: *cgltf_float;
	weights_count: cgltf_size;
	target_names: **u8;
	target_names_count: cgltf_size;
	extras: cgltf_extras;
	extensions_count: cgltf_size;
	extensions: *cgltf_extension;
}

cgltf_skin :: struct {
	name: *u8;
	joints: **cgltf_node;
	joints_count: cgltf_size;
	skeleton: *cgltf_node;
	inverse_bind_matrices: *cgltf_accessor;
	extras: cgltf_extras;
	extensions_count: cgltf_size;
	extensions: *cgltf_extension;
}

cgltf_camera_perspective :: struct {
	has_aspect_ratio: cgltf_bool;
	aspect_ratio: cgltf_float;
	yfov: cgltf_float;
	has_zfar: cgltf_bool;
	zfar: cgltf_float;
	znear: cgltf_float;
	extras: cgltf_extras;
}

cgltf_camera_orthographic :: struct {
	xmag: cgltf_float;
	ymag: cgltf_float;
	zfar: cgltf_float;
	znear: cgltf_float;
	extras: cgltf_extras;
}

cgltf_camera :: struct {
	name: *u8;
	type: cgltf_camera_type;
	data: union {
		perspective: cgltf_camera_perspective;
		orthographic: cgltf_camera_orthographic;
	};
	extras: cgltf_extras;
	extensions_count: cgltf_size;
	extensions: *cgltf_extension;
}

cgltf_light :: struct {
	name: *u8;
	color: [3]cgltf_float;
	intensity: cgltf_float;
	type: cgltf_light_type;
	range: cgltf_float;
	spot_inner_cone_angle: cgltf_float;
	spot_outer_cone_angle: cgltf_float;
	extras: cgltf_extras;
}

cgltf_node :: struct {
	name: *u8;
	parent: *cgltf_node;
	children: **cgltf_node;
	children_count: cgltf_size;
	skin: *cgltf_skin;
	mesh: *cgltf_mesh;
	camera: *cgltf_camera;
	light: *cgltf_light;
	weights: *cgltf_float;
	weights_count: cgltf_size;
	has_translation: cgltf_bool;
	has_rotation: cgltf_bool;
	has_scale: cgltf_bool;
	has_matrix: cgltf_bool;
	translation: [3]cgltf_float;
	rotation: [4]cgltf_float;
	scale: [3]cgltf_float;
	matrix: [16]cgltf_float;
	extras: cgltf_extras;
	has_mesh_gpu_instancing: cgltf_bool;
	mesh_gpu_instancing: cgltf_mesh_gpu_instancing;
	extensions_count: cgltf_size;
	extensions: *cgltf_extension;
}

cgltf_scene :: struct {
	name: *u8;
	nodes: **cgltf_node;
	nodes_count: cgltf_size;
	extras: cgltf_extras;
	extensions_count: cgltf_size;
	extensions: *cgltf_extension;
}

cgltf_animation_sampler :: struct {
	input: *cgltf_accessor;
	output: *cgltf_accessor;
	interpolation: cgltf_interpolation_type;
	extras: cgltf_extras;
	extensions_count: cgltf_size;
	extensions: *cgltf_extension;
}

cgltf_animation_channel :: struct {
	sampler: *cgltf_animation_sampler;
	target_node: *cgltf_node;
	target_path: cgltf_animation_path_type;
	extras: cgltf_extras;
	extensions_count: cgltf_size;
	extensions: *cgltf_extension;
}

cgltf_animation :: struct {
	name: *u8;
	samplers: *cgltf_animation_sampler;
	samplers_count: cgltf_size;
	channels: *cgltf_animation_channel;
	channels_count: cgltf_size;
	extras: cgltf_extras;
	extensions_count: cgltf_size;
	extensions: *cgltf_extension;
}

cgltf_material_variant :: struct {
	name: *u8;
	extras: cgltf_extras;
}

cgltf_asset :: struct {
	copyright: *u8;
	generator: *u8;
	version: *u8;
	min_version: *u8;
	extras: cgltf_extras;
	extensions_count: cgltf_size;
	extensions: *cgltf_extension;
}

cgltf_data :: struct {
	file_type: cgltf_file_type;
	file_data: *void;

	asset: cgltf_asset;

	meshes: *cgltf_mesh;
	meshes_count: cgltf_size;

	materials: *cgltf_material;
	materials_count: cgltf_size;

	accessors: *cgltf_accessor;
	accessors_count: cgltf_size;

	buffer_views: *cgltf_buffer_view;
	buffer_views_count: cgltf_size;

	buffers: *cgltf_buffer;
	buffers_count: cgltf_size;

	images: *cgltf_image;
	images_count: cgltf_size;

	textures: *cgltf_texture;
	textures_count: cgltf_size;

	samplers: *cgltf_sampler;
	samplers_count: cgltf_size;

	skins: *cgltf_skin;
	skins_count: cgltf_size;

	cameras: *cgltf_camera;
	cameras_count: cgltf_size;

	lights: *cgltf_light;
	lights_count: cgltf_size;

	nodes: *cgltf_node;
	nodes_count: cgltf_size;

	scenes: *cgltf_scene;
	scenes_count: cgltf_size;

	scene: *cgltf_scene;

	animations: *cgltf_animation;
	animations_count: cgltf_size;

	variants: *cgltf_material_variant;
	variants_count: cgltf_size;

	extras: cgltf_extras;

	data_extensions_count: cgltf_size;
	data_extensions: *cgltf_extension;

	extensions_used: **u8;
	extensions_used_count: cgltf_size;

	extensions_required: **u8;
	extensions_required_count: cgltf_size;

	json: *u8;
	json_size: cgltf_size;

	bin: *void;
	bin_size: cgltf_size;

	memory: cgltf_memory_options;
	file: cgltf_file_options;
}

cgltf_parse :: ( options: *cgltf_options, data: *void, size: cgltf_size, out_data: **cgltf_data ) -> cgltf_result #foreign cgltflib;
cgltf_parse_file :: ( options: *cgltf_options, path: *u8, out_data: **cgltf_data ) -> cgltf_result #foreign cgltflib;

cgltf_load_buffers :: ( options: *cgltf_options, data: *cgltf_data, gltf_path: *u8 ) -> cgltf_result #foreign cgltflib;
cgltf_load_buffer_base64 :: ( options: *cgltf_options, size: cgltf_size, base64: *u8, out_data: **void ) -> cgltf_result #foreign cgltflib;

cgltf_decode_string :: ( str: *u8 ) -> cgltf_size #foreign cgltflib;
cgltf_decode_uri :: ( uri: *u8 ) -> cgltf_size #foreign cgltflib;

cgltf_validate :: ( data: *cgltf_data ) -> cgltf_result #foreign cgltflib;

cgltf_free :: ( data: *cgltf_data ) #foreign cgltflib;

cgltf_node_transform_local :: ( node: *cgltf_node, out_matrix: *cgltf_float ) #foreign cgltflib;
cgltf_node_transform_world :: ( node: *cgltf_node, out_matrix: *cgltf_float ) #foreign cgltflib;

cgltf_find_accessor :: (prim: *cgltf_primitive, type: cgltf_attribute_type, index: cgltf_int) -> *cgltf_accessor #foreign cgltflib;

cgltf_buffer_view_data :: ( view: *cgltf_buffer_view ) -> *u8  #foreign cgltflib;

cgltf_accessor_read_float :: ( accessor: *cgltf_accessor, index: cgltf_size, out: *cgltf_float, element_size: cgltf_size ) -> cgltf_bool #foreign cgltflib;
cgltf_accessor_read_uint :: ( accessor: *cgltf_accessor, index: cgltf_size, out: *cgltf_uint, element_size: cgltf_size ) -> cgltf_bool #foreign cgltflib;
cgltf_accessor_read_index :: ( accessor: *cgltf_accessor, index: cgltf_size ) -> cgltf_size #foreign cgltflib;
cgltf_accessor_unpack_floats :: ( accessor: *cgltf_accessor, out: *cgltf_float, float_count: cgltf_size ) -> cgltf_size #foreign cgltflib;
cgltf_accessor_unpack_indices :: (accessor: *cgltf_accessor, out: *void, out_component_size: cgltf_size, index_count: cgltf_size) -> cgltf_size #foreign cgltflib;

cgltf_num_components :: ( type: cgltf_type ) -> cgltf_size #foreign cgltflib;
cgltf_component_size :: ( component_type: cgltf_component_type ) -> cgltf_size #foreign cgltflib;
cgltf_calc_size :: ( type: cgltf_type, component_type: cgltf_component_type ) -> cgltf_size #foreign cgltflib;

/* this function is deprecated and will be removed in the future; use cgltf_extras::data instead */
cgltf_copy_extras_json :: ( data: *cgltf_data, extras: *cgltf_extras, dest: *u8, dest_size: *cgltf_size ) -> cgltf_result #foreign cgltflib;

cgltf_mesh_index              :: (data: *cgltf_data,           object: *cgltf_mesh)              -> cgltf_size #foreign cgltflib;
cgltf_material_index          :: (data: *cgltf_data,           object: *cgltf_material)          -> cgltf_size #foreign cgltflib;
cgltf_accessor_index          :: (data: *cgltf_data,           object: *cgltf_accessor)          -> cgltf_size #foreign cgltflib;
cgltf_buffer_view_index       :: (data: *cgltf_data,           object: *cgltf_buffer_view)       -> cgltf_size #foreign cgltflib;
cgltf_buffer_index            :: (data: *cgltf_data,           object: *cgltf_buffer)            -> cgltf_size #foreign cgltflib;
cgltf_image_index             :: (data: *cgltf_data,           object: *cgltf_image)             -> cgltf_size #foreign cgltflib;
cgltf_texture_index           :: (data: *cgltf_data,           object: *cgltf_texture)           -> cgltf_size #foreign cgltflib;
cgltf_sampler_index           :: (data: *cgltf_data,           object: *cgltf_sampler)           -> cgltf_size #foreign cgltflib;
cgltf_skin_index              :: (data: *cgltf_data,           object: *cgltf_skin)              -> cgltf_size #foreign cgltflib;
cgltf_camera_index            :: (data: *cgltf_data,           object: *cgltf_camera)            -> cgltf_size #foreign cgltflib;
cgltf_light_index             :: (data: *cgltf_data,           object: *cgltf_light)             -> cgltf_size #foreign cgltflib;
cgltf_node_index              :: (data: *cgltf_data,           object: *cgltf_node)              -> cgltf_size #foreign cgltflib;
cgltf_scene_index             :: (data: *cgltf_data,           object: *cgltf_scene)             -> cgltf_size #foreign cgltflib;
cgltf_animation_index         :: (data: *cgltf_data,           object: *cgltf_animation)         -> cgltf_size #foreign cgltflib;
cgltf_animation_sampler_index :: (animation: *cgltf_animation, object: *cgltf_animation_sampler) -> cgltf_size #foreign cgltflib;
cgltf_animation_channel_index :: (animation: *cgltf_animation, object: *cgltf_animation_channel) -> cgltf_size #foreign cgltflib;

#scope_file

cgltflib :: #library, no_dll "cgltf";
