#pragma once

#include "ggml-backend.h"

#ifdef  __cplusplus
extern "C" {
#endif

#define RPC_PROTO_MAJOR_VERSION    5
#define RPC_PROTO_MINOR_VERSION    2
#define RPC_PROTO_PATCH_VERSION    0

#ifdef  __cplusplus
static_assert(GGML_OP_COUNT == 101, "GGML_OP_COUNT has changed - update RPC_PROTO_PATCH_VERSION");
#endif

#define GGML_RPC_MAX_SERVERS       16

// backend API
GGML_BACKEND_API ggml_backend_t ggml_backend_rpc_init(const char * endpoint, uint32_t device);
GGML_BACKEND_API bool ggml_backend_is_rpc(ggml_backend_t backend);

GGML_BACKEND_API ggml_backend_buffer_type_t ggml_backend_rpc_buffer_type(const char * endpoint, uint32_t device);

GGML_BACKEND_API void ggml_backend_rpc_get_device_memory(const char * endpoint, uint32_t device, size_t * free, size_t * total);

GGML_BACKEND_API void ggml_backend_rpc_start_server(const char * endpoint, const char * cache_dir,
                                                    size_t n_threads, size_t n_devices, ggml_backend_dev_t * devices);

// Expert pool of a device: the client owns the slot memory (a buffer of the
// device) and the server fills it from its own copy of the model file, so no
// expert weight ever crosses the network. `model_path` is the server side model
// file, `layers` the pool layers of this device.
GGML_BACKEND_API void ggml_backend_rpc_start_server_ex(const char * endpoint, const char * cache_dir,
                                                       size_t n_threads, size_t n_devices, ggml_backend_dev_t * devices,
                                                       const char * model_path, size_t pool_budget, int32_t pool_banks);

// the part of an expert a pool slot of one device keeps: all zero (src_ne0 == 0)
// means the slot holds the whole expert. ggml layout: ne0 is the contiguous one.
struct ggml_rpc_pool_slice {
    int64_t ne0;
    int64_t ne1;
    int64_t src_ne0;
    int64_t src_ne1;
    int64_t first_ne0;
    int64_t first_ne1;
    int64_t ne1_2;       // fused gate_up: the second run of the slot
    int64_t first_ne1_2;
};

// hand the slot arena of a device to the server that computes its experts
// `slices` holds three entries (up, gate, down) per layer, or is NULL when every
// slot holds a whole expert. returns false when the server has no pool or the
// geometry does not match
GGML_BACKEND_API bool ggml_backend_rpc_moe_pool_setup(ggml_backend_buffer_t arena,
                                                      size_t budget, size_t kv_reserve, size_t io_align, int32_t n_banks,
                                                      const int32_t * layers, int32_t n_layers,
                                                      const struct ggml_rpc_pool_slice * slices,
                                                      uint64_t * out_arena_size, uint64_t * out_geometry_hash,
                                                      bool lock);

GGML_BACKEND_API ggml_backend_reg_t ggml_backend_rpc_reg(void);
GGML_BACKEND_API ggml_backend_reg_t ggml_backend_rpc_add_server(const char * endpoint);

#ifdef  __cplusplus
}
#endif
