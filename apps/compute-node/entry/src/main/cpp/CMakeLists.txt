cmake_minimum_required(VERSION 3.5.0)
project(GewuProbe)
set(CMAKE_CXX_STANDARD 17)

# ---- 文本 GEWU 引擎探针（系统 QoS GEWU 服务，backend=knpu，无 NPU 直连）----
add_library(gewu_probe SHARED gewu_probe.cpp)
target_link_libraries(gewu_probe PUBLIC libace_napi.z.so libqos.so libhilog_ndk.z.so)

# ---- Qwen2.5-VL 多模态引擎（可整体摘除的可选模块）----
# 私有预编译产物放在 src/main/cpp/libs/${OHOS_ARCH}/，不入库：
#   清单 apps/compute-node/entry/src/main/cpp/libs.manifest.json
#   放置 scripts/place-vl-libs.ps1
# 探测到 SDK 就编真引擎，否则编空实现。两条分支的模块名与导出面完全一致
# （qwenvl_engine: start/takeEvents/complete/cancel/release），所以 ArkTS 侧无需
# 条件编译、也不会有动态 import 的兼容问题；缺库时应用仍可构建，只是不带 VL 能力。
set(QWEN2VL_SDK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/libs/${OHOS_ARCH}")

if(EXISTS "${QWEN2VL_SDK_DIR}/libqwen2vl_sdk.so")

  # ---- Qwen2.5-VL-3B-NPU 多模态引擎桥（移植 modelshare t7/t8 已验证的 NPU 链路）----
  # 预编译产物：src/main/cpp/libs/${OHOS_ARCH}/（libqwen2vl_sdk.so = NPU 版 9,388,104B，
  # 含 knpu 符号 + DT_NEEDED libc++.so->libcxx.so 等长 patch 版；libcxx.so = SDK 的 C++
  # 运行时，自定义名规避打包器对 libc++.so 的系统库白名单丢弃）。
  add_library(qwenvl_engine SHARED napi_engine.cpp)

  add_library(qwen2vl_sdk SHARED IMPORTED)
  set_target_properties(qwen2vl_sdk PROPERTIES
      IMPORTED_LOCATION "${QWEN2VL_SDK_DIR}/libqwen2vl_sdk.so"
  )
  add_library(cjson SHARED IMPORTED)
  set_target_properties(cjson PROPERTIES
      IMPORTED_LOCATION "${QWEN2VL_SDK_DIR}/libcjson.z.so"
  )
  add_library(cxx SHARED IMPORTED)
  set_target_properties(cxx PROPERTIES
      IMPORTED_LOCATION "${QWEN2VL_SDK_DIR}/libcxx.so"
  )

  # NPU kernel（CCE 算子）与 base（引擎符号库）：NPU 引擎 load 时运行期
  # dlopen("libgewurt_kernel.so")（src/knpu/knpu_cce.cpp L303），kernel 又
  # NEEDED libgewurt_base.so。两者必须打进 HAP 与 SDK 同目录，否则
  # load 10ms 快速失败（KNPU backend disabled, QWEN2VL_ERR_LOAD=-3）。
  add_library(gewurt_kernel SHARED IMPORTED)
  set_target_properties(gewurt_kernel PROPERTIES
      IMPORTED_LOCATION "${QWEN2VL_SDK_DIR}/libgewurt_kernel.so"
  )
  add_library(gewurt_base SHARED IMPORTED)
  set_target_properties(gewurt_base PROPERTIES
      IMPORTED_LOCATION "${QWEN2VL_SDK_DIR}/libgewurt_base.so"
  )

  # --- libai_runtime NPU 运行时链打包（运行期 dlopen("libai_runtime.so") 目标）---
  # 根因（modelshare t6）：App moduleNs_default 不含 /vendor/lib64/passthrough/indirect
  # → dlopen("libai_runtime.so") ENOENT → KnpuRt* 静默 0x56080001。
  # 措施（t7 已验证）：整条 vendor NPU 运行时链 + 系统侧依赖闭包 IMPORTED 进 HAP 与
  # SDK 同目录，并在 qwenvl_engine 上强制 DT_NEEDED（--no-as-needed）保证 hvigor
  # 打包 + 启动预加载。闭包实测：moduleNs_default 在引擎加载时刻无法解析
  # chipset-sdk-sp 短名（libhitrace_meter ENOENT）→ 系统侧依赖必须一并打包。
  # 含 libc++.so NEEDED 的库已字节级等长 patch 为 libcxx.so（备份 .pre_libcxx_patch.so）。
  # 22 库闭包（+libhilog 最终验证版一并入包）：
  set(LLM_AI_CHAIN
      libai_runtime libnpu_slog libai_drv_dlog libai_drv_device
      libai_drv_devmm libai_drv_profiling libai_drv_syslog
      libai_om_trace_engine libai_om_event_manager libai_infra_log
      libhitrace_meter libhitracechain libbegetutil.z libconfigpolicy_util.z
      libsystemparam.z libsec_shared.z libdmabufheap.z libhilog
      libhilog_inner libsandboxlog libhilog_encode libclang_rt.ubsan_minimal)
  foreach(lib ${LLM_AI_CHAIN})
      add_library(${lib} SHARED IMPORTED)
      set_target_properties(${lib} PROPERTIES
          IMPORTED_LOCATION "${QWEN2VL_SDK_DIR}/${lib}.so")
  endforeach()

  target_include_directories(qwenvl_engine PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_link_libraries(qwenvl_engine PUBLIC
      libace_napi.z.so
      libhilog_ndk.z.so
      qwen2vl_sdk
      cjson
      cxx
      gewurt_kernel
      gewurt_base
      ${LLM_AI_CHAIN}
  )

  # --no-as-needed：kernel/base 与 qwenvl_engine 无符号级引用，默认 as-needed
  # 会剔除它们的 DT_NEEDED，导致 hvigor 按链接关系收集 so 时不打包。
  # 强制写入 DT_NEEDED 后：1) 一定进 HAP；2) 进程启动即预加载，运行期
  # dlopen("libgewurt_kernel.so") 短名直接命中已加载 DSO。
  target_link_options(qwenvl_engine PRIVATE "-Wl,--no-as-needed")

else()

  # 私有库未放置：编空实现，保持模块名与导出面一致。
  # 应用照常构建、照常运行，只是带图请求会拿到「引擎不可用」而不是真实推理。
  message(STATUS "libqwen2vl_sdk.so not found under ${QWEN2VL_SDK_DIR}; "
                 "building the text-only stub for qwenvl_engine "
                 "(run scripts/place-vl-libs.ps1 to install the private libraries)")
  add_library(qwenvl_engine SHARED napi_engine_stub.cpp)
  target_link_libraries(qwenvl_engine PUBLIC libace_napi.z.so libhilog_ndk.z.so)

endif()

# ---- llama.cpp direct NAPI（与 GEWU 同进程，不经过 HTTP）----
# Runtime libraries are built from the local llama.cpp tree used by the
# llama-server-ohos application. The HAP carries the CPU backend only.
set(LLAMA_RUNTIME_DIR "${CMAKE_CURRENT_SOURCE_DIR}/llama/${OHOS_ARCH}")
foreach(LLAMA_TARGET IN ITEMS llama_runtime ggml_runtime ggml_base_runtime ggml_cpu_runtime ggml_rpc_runtime llama_openmp)
    add_library(${LLAMA_TARGET} SHARED IMPORTED)
endforeach()
set_target_properties(llama_runtime PROPERTIES
    IMPORTED_LOCATION "${LLAMA_RUNTIME_DIR}/libllama.so.0.3.0")
set_target_properties(ggml_runtime PROPERTIES
    IMPORTED_LOCATION "${LLAMA_RUNTIME_DIR}/libggml.so.0.22.0")
set_target_properties(ggml_base_runtime PROPERTIES
    IMPORTED_LOCATION "${LLAMA_RUNTIME_DIR}/libggml-base.so.0.22.0")
set_target_properties(ggml_cpu_runtime PROPERTIES
    IMPORTED_LOCATION "${LLAMA_RUNTIME_DIR}/libggml-cpu.so.0.22.0")
set_target_properties(ggml_rpc_runtime PROPERTIES
    IMPORTED_LOCATION "${LLAMA_RUNTIME_DIR}/libggml-rpc.so.0.22.0")
set_target_properties(llama_openmp PROPERTIES
    IMPORTED_LOCATION "${LLAMA_RUNTIME_DIR}/libomp.so")

add_library(llama_probe SHARED llama_probe.cpp)
target_include_directories(llama_probe PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/llama/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/llama/include/ggml"
    "${CMAKE_CURRENT_SOURCE_DIR}/llama/vendor")
target_link_libraries(llama_probe PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    llama_runtime
    ggml_runtime
    ggml_base_runtime
    ggml_cpu_runtime
    ggml_rpc_runtime
    llama_openmp)
target_link_options(llama_probe PRIVATE "-Wl,--no-as-needed")
target_compile_features(llama_probe PRIVATE cxx_std_17)
