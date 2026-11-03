#include "napi/native_api.h"

#include "hilog/log.h"
#include "llama.h"
#include "ggml-backend.h"
#include "json.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cctype>
#include <cerrno>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <deque>
#include <dirent.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <linux/neighbour.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <mutex>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <sstream>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "LlamaProbe"

// Process-wide MoE expert skip override from the bundled llama.cpp tree.
void llama_set_bisect_params(int32_t k1, int32_t k2);
// The same entry point used by llama-server-ohos. Keeping the model and context
// lifecycle inside tools/server is what makes placement and memory accounting
// match the application that already sustains the 14 GiB configuration.
extern int llama_server(int argc, char ** argv);
extern void llama_server_terminate();

namespace {

using Clock = std::chrono::steady_clock;
using json = nlohmann::json;

std::string dumpJson(const json & value) {
    return value.dump(-1, ' ', false, json::error_handler_t::replace);
}

bool continuation(unsigned char value) {
    return (value & 0xc0) == 0x80;
}

/**
 * A token can end in the middle of a UTF-8 code point. Keep that suffix until
 * the next token completes it instead of handing invalid bytes to JSON.
 */
std::string takeCompleteUtf8(std::string & pending) {
    std::string output;
    size_t offset = 0;
    while (offset < pending.size()) {
        const unsigned char first = static_cast<unsigned char>(pending[offset]);
        size_t length = 0;
        if (first < 0x80) {
            length = 1;
        } else if (first >= 0xc2 && first <= 0xdf) {
            length = 2;
        } else if (first >= 0xe0 && first <= 0xef) {
            length = 3;
        } else if (first >= 0xf0 && first <= 0xf4) {
            length = 4;
        }
        if (length == 0) {
            output += "\xef\xbf\xbd";
            ++offset;
            continue;
        }
        if (offset + length > pending.size()) break;
        bool valid = true;
        for (size_t index = 1; index < length; ++index) {
            valid = valid && continuation(static_cast<unsigned char>(pending[offset + index]));
        }
        if (length == 3) {
            const unsigned char second = static_cast<unsigned char>(pending[offset + 1]);
            if (first == 0xe0) valid = valid && second >= 0xa0;
            if (first == 0xed) valid = valid && second <= 0x9f;
        } else if (length == 4) {
            const unsigned char second = static_cast<unsigned char>(pending[offset + 1]);
            if (first == 0xf0) valid = valid && second >= 0x90;
            if (first == 0xf4) valid = valid && second <= 0x8f;
        }
        if (!valid) {
            output += "\xef\xbf\xbd";
            ++offset;
            continue;
        }
        output.append(pending.data() + offset, length);
        offset += length;
    }
    pending.erase(0, offset);
    return output;
}

std::string flushUtf8(std::string & pending) {
    std::string output = takeCompleteUtf8(pending);
    if (!pending.empty()) {
        output += "\xef\xbf\xbd";
        pending.clear();
    }
    return output;
}

std::atomic<uint64_t> g_statusExpertRamBytes{0};
std::atomic<uint64_t> g_statusDiskBytes{0};
std::atomic<int32_t> g_statusHitPct{-1};
std::atomic<bool> g_serverFollowerReady{false};
std::atomic<bool> g_serverThreadRunning{false};
std::atomic<int32_t> g_serverExitCode{1};
std::atomic<bool> g_logCaptureStarted{false};

void observeRuntimeLogLine(const std::string & line) {
    double value = 0.0;
    if (line.find("ggml_pool_mlock: slot arena locked in physical memory") != std::string::npos &&
        sscanf(line.c_str(), "%*[^0-9]%lf", &value) == 1) {
        g_statusExpertRamBytes.store(static_cast<uint64_t>(std::max(0.0, value) * 1024.0 * 1024.0));
    } else if (line.find("POOL: fill loaded=") != std::string::npos) {
        const char * loaded = strstr(line.c_str(), "loaded=");
        if (loaded != nullptr && sscanf(loaded, "loaded=%lf", &value) == 1) {
            g_statusExpertRamBytes.store(static_cast<uint64_t>(std::max(0.0, value) * 1024.0 * 1024.0));
        }
    } else if (line.find("POOL: cache eval=") != std::string::npos) {
        int hits = -1;
        int misses = -1;
        const char * hit = strstr(line.c_str(), "hit=");
        const char * miss = strstr(line.c_str(), "miss=");
        const char * resident = strstr(line.c_str(), "resident=");
        if (hit != nullptr) sscanf(hit, "hit=%d", &hits);
        if (miss != nullptr) sscanf(miss, "miss=%d", &misses);
        if (hits >= 0 && misses >= 0 && hits + misses > 0) {
            g_statusHitPct.store(static_cast<int32_t>(100.0 * hits / (hits + misses)));
        }
        if (resident != nullptr && sscanf(resident, "resident=%*d slots %lf MiB", &value) == 1) {
            g_statusExpertRamBytes.store(static_cast<uint64_t>(std::max(0.0, value) * 1024.0 * 1024.0));
        }
    }
    if (line.find("common_follower_run: rank ") != std::string::npos) {
        g_serverFollowerReady.store(true);
    }
}

void llamaLogCallback(ggml_log_level level, const char * text, void *) {
    if (text == nullptr) return;
    const std::string line(text);
    observeRuntimeLogLine(line);
    if (level == GGML_LOG_LEVEL_ERROR) {
        OH_LOG_ERROR(LOG_APP, "%{public}s", text);
    } else if (level == GGML_LOG_LEVEL_WARN) {
        OH_LOG_WARN(LOG_APP, "%{public}s", text);
    } else {
        OH_LOG_INFO(LOG_APP, "%{public}s", text);
    }
}

uint64_t processRssBytes() {
    FILE * file = fopen("/proc/self/status", "r");
    if (file == nullptr) return 0;
    char line[256];
    size_t rssKb = 0;
    while (fgets(line, sizeof(line), file) != nullptr) {
        if (sscanf(line, "VmRSS: %zu kB", &rssKb) == 1) break;
    }
    fclose(file);
    return static_cast<uint64_t>(rssKb) * 1024ULL;
}

struct InferenceRequest {
    std::vector<std::string> roles;
    std::vector<std::string> contents;
    int32_t maxTokens = 512;
    bool stream = true;
};

struct RuntimeOptions {
    size_t memoryBudgetMb = 0;
    float kvReservePct = 0.0f;
    float hotAlpha = 0.1f;
    bool ffnHotCold = false;
    bool prefetch = false;
    bool useExtraBufts = true;
    int32_t moeSkipK1 = 0;
    int32_t moeSkipK2 = 0;
    int32_t nBatch = 2048;
    int32_t nUbatch = 512;
    int32_t nSeqMax = 1;
    std::string kvDir;
    int32_t distRank = 0;
    int32_t distRanks = 1;
    std::string distEndpoints;
    std::string distSplit;
    bool distFollower = false;
};

struct Job {
    int64_t id = 0;
    std::string modelPath;
    std::string requestJson;
    std::string runtimeOptionsJson;
    RuntimeOptions runtimeOptions;
    int32_t contextSize = 8192;
    int32_t waitSeconds = 0;
    bool unload = false;
    bool preload = false;
};

std::mutex g_queueMutex;
std::condition_variable g_queueCv;
std::deque<Job> g_jobs;
std::mutex g_eventMutex;
std::vector<std::string> g_events;
std::atomic<int64_t> g_nextJobId{0};
std::atomic<int64_t> g_runningJobId{0};
std::atomic<bool> g_cancelCurrent{false};
std::atomic<bool> g_unloadAfterJob{false};
std::atomic<bool> g_modelReady{false};
std::atomic<bool> g_modelLoading{false};
std::atomic<int32_t> g_statusContext{0};
std::atomic<int32_t> g_statusDistRank{-1};
std::atomic<int32_t> g_statusDistRanks{1};
std::atomic<bool> g_statusDistFollower{false};
std::mutex g_statusMutex;
std::string g_statusModel;
std::string g_statusError;
bool g_workerStarted = false;

void setStatus(const char * error = "", const std::string & model = std::string()) {
    std::lock_guard<std::mutex> lock(g_statusMutex);
    g_statusError = error;
    if (!model.empty()) g_statusModel = model;
}

long long elapsedMs(const Clock::time_point & start) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start).count();
}

void pushEvent(int64_t id, const std::string & event, const std::string & payload, long long elapsed = -1) {
    json value = {
        {"event", event},
        {"id", std::to_string(id)},
        {"payload", payload}
    };
    if (elapsed >= 0) {
        value["elapsedMs"] = elapsed;
    }
    std::lock_guard<std::mutex> lock(g_eventMutex);
    g_events.push_back(dumpJson(value));
}

void pushError(int64_t id, const std::string & message, long long elapsed) {
    json payload = {{"message", message}};
    pushEvent(id, "error", dumpJson(payload), elapsed);
}

RuntimeOptions parseRuntimeOptions(const std::string & text) {
    RuntimeOptions options;
    if (text.empty()) return options;
    try {
        const json value = json::parse(text);
        if (!value.is_object()) return options;
        auto readNumber = [&value](const char * key, double fallback) -> double {
            const auto item = value.find(key);
            return item != value.end() && item->is_number() ? item->get<double>() : fallback;
        };
        auto readBool = [&value](const char * key, bool fallback) -> bool {
            const auto item = value.find(key);
            return item != value.end() && item->is_boolean() ? item->get<bool>() : fallback;
        };
        options.memoryBudgetMb = static_cast<size_t>(
            std::clamp(readNumber("memoryBudgetMb", 0.0), 0.0, 1048576.0));
        options.kvReservePct = static_cast<float>(
            std::clamp(readNumber("kvReservePct", 0.0), 0.0, 100.0));
        options.hotAlpha = static_cast<float>(
            std::clamp(readNumber("hotAlpha", 0.1), 0.001, 1.0));
        options.ffnHotCold = readBool("ffnHotCold", false);
        options.prefetch = readBool("prefetch", false);
        options.useExtraBufts = readBool("useExtraBufts", true);
        options.moeSkipK1 = static_cast<int32_t>(
            std::clamp(readNumber("moeSkipK1", 0.0), 0.0, 64.0));
        options.moeSkipK2 = static_cast<int32_t>(
            std::clamp(readNumber("moeSkipK2", 0.0), 0.0, 64.0));
        options.nBatch = static_cast<int32_t>(
            std::clamp(readNumber("nBatch", 2048.0), 1.0, 32768.0));
        options.nUbatch = static_cast<int32_t>(
            std::clamp(readNumber("nUbatch", 512.0), 1.0, 32768.0));
        options.nSeqMax = static_cast<int32_t>(
            std::clamp(readNumber("nSeqMax", 1.0), 1.0, 8.0));
        const auto kvDir = value.find("kvDir");
        if (kvDir != value.end() && kvDir->is_string()) options.kvDir = kvDir->get<std::string>();
        options.distRank = static_cast<int32_t>(
            std::clamp(readNumber("distRank", 0.0), 0.0, 63.0));
        options.distRanks = static_cast<int32_t>(
            std::clamp(readNumber("distRanks", 1.0), 1.0, 64.0));
        const auto endpoints = value.find("distEndpoints");
        if (endpoints != value.end() && endpoints->is_string()) {
            options.distEndpoints = endpoints->get<std::string>();
        }
        const auto split = value.find("distSplit");
        if (split != value.end() && split->is_string()) options.distSplit = split->get<std::string>();
        options.distFollower = readBool("distFollower", false);
        if (options.distRanks <= 1 || options.distRank < 0 ||
            options.distRank >= options.distRanks || options.distEndpoints.empty()) {
            options.distRank = 0;
            options.distRanks = 1;
            options.distEndpoints.clear();
            options.distSplit.clear();
            options.distFollower = false;
        }
        if (options.distFollower && options.distRank == 0) options.distFollower = false;
    } catch (const std::exception &) {
        return RuntimeOptions();
    }
    return options;
}

void configureDistributed(const RuntimeOptions & options) {
    auto clear = []() {
        unsetenv("LLAMA_DIST_RANKS");
        unsetenv("LLAMA_DIST_RANK");
        unsetenv("LLAMA_DIST_ENDPOINTS");
        unsetenv("LLAMA_DIST_SPLIT");
        unsetenv("LLAMA_DIST_FOLLOWER");
    };
    if (options.distRanks <= 1 || options.distEndpoints.empty()) {
        clear();
        return;
    }
    const std::string ranks = std::to_string(options.distRanks);
    const std::string rank = std::to_string(options.distRank);
    const std::string split = options.distSplit.empty() ? "expert" : options.distSplit;
    setenv("LLAMA_DIST_RANKS", ranks.c_str(), 1);
    setenv("LLAMA_DIST_RANK", rank.c_str(), 1);
    setenv("LLAMA_DIST_ENDPOINTS", options.distEndpoints.c_str(), 1);
    setenv("LLAMA_DIST_SPLIT", split.c_str(), 1);
    if (options.distFollower) setenv("LLAMA_DIST_FOLLOWER", "1", 1);
    else unsetenv("LLAMA_DIST_FOLLOWER");
    OH_LOG_INFO(LOG_APP,
        "distributed rank=%{public}d/%{public}d follower=%{public}d endpoints=%{public}s split=%{public}s",
        options.distRank, options.distRanks, options.distFollower ? 1 : 0,
        options.distEndpoints.c_str(), split.c_str());
}

size_t availableMemoryMiB() {
    FILE * file = fopen("/proc/meminfo", "r");
    if (file == nullptr) return 0;
    char line[256];
    size_t availableKb = 0;
    while (fgets(line, sizeof(line), file) != nullptr) {
        if (sscanf(line, "MemAvailable: %zu kB", &availableKb) == 1) break;
    }
    fclose(file);
    return availableKb / 1024;
}

/**
 * The OHOS llama.cpp build uses memory_budget for weight placement rather than
 * a kernel-enforced RSS limit. Never let placement consume more than 80% of
 * currently available RAM; the remaining fifth is reserved for mmap, KV cache,
 * graph buffers and the application.
 */
size_t safeMemoryBudgetMiB(size_t requested, size_t & available) {
    available = availableMemoryMiB();
    if (available == 0) return requested;
    const size_t usable = available - available / 5;
    return requested == 0 || usable < requested ? usable : requested;
}

bool parseRequest(const std::string & text, InferenceRequest & request, std::string & error) {
    try {
        const json value = json::parse(text);
        const auto messages = value.find("messages");
        if (messages == value.end() || !messages->is_array() || messages->empty()) {
            error = "请求中没有消息";
            return false;
        }
        for (const auto & item : *messages) {
            if (!item.is_object() || !item.contains("role") || !item.contains("content") ||
                !item["role"].is_string() || !item["content"].is_string()) {
                error = "消息格式无效";
                return false;
            }
            request.roles.push_back(item["role"].get<std::string>());
            request.contents.push_back(item["content"].get<std::string>());
        }
        if (value.contains("max_tokens") && value["max_tokens"].is_number_integer()) {
            request.maxTokens = value["max_tokens"].get<int32_t>();
        }
        if (value.contains("stream") && value["stream"].is_boolean()) {
            request.stream = value["stream"].get<bool>();
        }
        request.maxTokens = std::clamp(request.maxTokens, 1, 8192);
        return true;
    } catch (const std::exception & e) {
        error = std::string("请求解析失败: ") + e.what();
        return false;
    }
}

std::string formatMessages(const llama_model * model, const InferenceRequest & request) {
    std::vector<llama_chat_message> messages;
    messages.reserve(request.roles.size());
    for (size_t i = 0; i < request.roles.size(); ++i) {
        messages.push_back({request.roles[i].c_str(), request.contents[i].c_str()});
    }

    const char * tmpl = llama_model_chat_template(model, nullptr);
    if (tmpl != nullptr) {
        int32_t need = llama_chat_apply_template(tmpl, messages.data(), messages.size(), true, nullptr, 0);
        if (need > 0) {
            std::vector<char> buffer(static_cast<size_t>(need) + 1, '\0');
            int32_t written = llama_chat_apply_template(
                tmpl, messages.data(), messages.size(), true, buffer.data(), static_cast<int32_t>(buffer.size()));
            if (written > 0) {
                return std::string(buffer.data(), static_cast<size_t>(written));
            }
        }
    }

    std::string prompt;
    for (size_t i = 0; i < request.roles.size(); ++i) {
        prompt += "<|im_start|>" + request.roles[i] + "\n" + request.contents[i] + "<|im_end|>\n";
    }
    prompt += "<|im_start|>assistant\n";
    return prompt;
}

std::string tokenPiece(const llama_vocab * vocab, llama_token token) {
    char local[256];
    int32_t count = llama_token_to_piece(vocab, token, local, sizeof(local), 0, true);
    if (count >= 0) {
        return std::string(local, static_cast<size_t>(count));
    }
    std::vector<char> larger(static_cast<size_t>(-count) + 16, '\0');
    count = llama_token_to_piece(vocab, token, larger.data(), static_cast<int32_t>(larger.size()), 0, true);
    return count > 0 ? std::string(larger.data(), static_cast<size_t>(count)) : std::string();
}

constexpr int kServerPort = 18080;

struct HttpResponse {
    int status = 0;
    std::string body;
};

bool sendAll(int descriptor, const std::string & data) {
    size_t sent = 0;
    while (sent < data.size()) {
        const ssize_t count = send(descriptor, data.data() + sent, data.size() - sent, MSG_NOSIGNAL);
        if (count > 0) {
            sent += static_cast<size_t>(count);
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        return false;
    }
    return true;
}

int connectLocalServer() {
    const int descriptor = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (descriptor < 0) return -1;
    struct sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_port = htons(kServerPort);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(descriptor, reinterpret_cast<struct sockaddr *>(&address), sizeof(address)) != 0) {
        close(descriptor);
        return -1;
    }
    return descriptor;
}

bool localPortListening(int port) {
    const char * files[] = {"/proc/net/tcp", "/proc/net/tcp6"};
    const unsigned int target = static_cast<unsigned int>(port);
    for (const char * path : files) {
        FILE * file = fopen(path, "r");
        if (file == nullptr) continue;
        char line[512];
        bool found = false;
        while (fgets(line, sizeof(line), file) != nullptr) {
            char localAddress[65] = {};
            char remoteAddress[65] = {};
            unsigned int localPort = 0;
            unsigned int state = 0;
            if (sscanf(line, " %*u: %64[0-9A-Fa-f]:%X %64[0-9A-Fa-f]:%*X %X",
                    localAddress, &localPort, remoteAddress, &state) == 4 &&
                localPort == target && state == 0x0A) {
                found = true;
                break;
            }
        }
        fclose(file);
        if (found) return true;
    }
    return false;
}

std::string socketReadAll(int descriptor, int idleTimeoutMs) {
    std::string output;
    char buffer[16384];
    for (;;) {
        struct pollfd item = {descriptor, POLLIN, 0};
        const int ready = poll(&item, 1, idleTimeoutMs);
        if (ready <= 0) break;
        const ssize_t count = recv(descriptor, buffer, sizeof(buffer), 0);
        if (count <= 0) break;
        output.append(buffer, static_cast<size_t>(count));
    }
    return output;
}

size_t headerEnd(const std::string & data, bool & crlf) {
    const size_t first = data.find("\r\n\r\n");
    if (first != std::string::npos) {
        crlf = true;
        return first + 4;
    }
    const size_t second = data.find("\n\n");
    if (second != std::string::npos) {
        crlf = false;
        return second + 2;
    }
    return std::string::npos;
}

int responseStatus(const std::string & headers) {
    int status = 0;
    if (headers.compare(0, 5, "HTTP/") == 0) {
        const size_t space = headers.find(' ');
        if (space != std::string::npos) status = atoi(headers.c_str() + space + 1);
    }
    return status;
}

bool responseIsChunked(const std::string & headers) {
    std::string lower = headers;
    std::transform(lower.begin(), lower.end(), lower.begin(),
        [](unsigned char value) { return static_cast<char>(tolower(value)); });
    return lower.find("transfer-encoding: chunked") != std::string::npos;
}

class ChunkedDecoder {
public:
    void feed(const char * data, size_t size, std::string & output, bool & complete) {
        buffer.append(data, size);
        for (;;) {
            if (!readingData) {
                const size_t end = buffer.find('\n');
                if (end == std::string::npos) return;
                std::string line = buffer.substr(0, end);
                buffer.erase(0, end + 1);
                if (!line.empty() && line.back() == '\r') line.pop_back();
                const size_t extension = line.find(';');
                if (extension != std::string::npos) line.resize(extension);
                char * parsed = nullptr;
                const unsigned long length = strtoul(line.c_str(), &parsed, 16);
                if (parsed == line.c_str()) {
                    complete = true;
                    return;
                }
                if (length == 0) {
                    complete = true;
                    return;
                }
                remaining = static_cast<size_t>(length);
                readingData = true;
            }
            if (buffer.size() < remaining + 2) return;
            output.append(buffer.data(), remaining);
            buffer.erase(0, remaining);
            if (buffer.size() >= 2 && buffer.compare(0, 2, "\r\n") == 0) buffer.erase(0, 2);
            else if (!buffer.empty() && buffer[0] == '\n') buffer.erase(0, 1);
            readingData = false;
        }
    }

private:
    std::string buffer;
    size_t remaining = 0;
    bool readingData = false;
};

HttpResponse requestHealth() {
    HttpResponse response;
    const int descriptor = connectLocalServer();
    if (descriptor < 0) return response;
    const std::string request =
        "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    if (!sendAll(descriptor, request)) {
        close(descriptor);
        return response;
    }
    const std::string raw = socketReadAll(descriptor, 1500);
    close(descriptor);
    bool crlf = false;
    const size_t split = headerEnd(raw, crlf);
    if (split == std::string::npos) return response;
    const std::string headers = raw.substr(0, split);
    response.status = responseStatus(headers);
    response.body = raw.substr(split);
    return response;
}

void ensureLogCapture() {
    bool expected = false;
    if (!g_logCaptureStarted.compare_exchange_strong(expected, true)) return;
    int descriptors[2] = {-1, -1};
    if (pipe(descriptors) != 0) {
        OH_LOG_WARN(LOG_APP, "server log capture pipe failed errno=%{public}d", errno);
        return;
    }
    fcntl(descriptors[0], F_SETFD, FD_CLOEXEC);
    fcntl(descriptors[1], F_SETFD, FD_CLOEXEC);
    dup2(descriptors[1], STDOUT_FILENO);
    dup2(descriptors[1], STDERR_FILENO);
    close(descriptors[1]);
    std::thread([descriptor = descriptors[0]]() {
        std::string pending;
        char buffer[4096];
        for (;;) {
            const ssize_t count = read(descriptor, buffer, sizeof(buffer));
            if (count <= 0) break;
            pending.append(buffer, static_cast<size_t>(count));
            for (;;) {
                const size_t newline = pending.find('\n');
                if (newline == std::string::npos) break;
                std::string line = pending.substr(0, newline);
                pending.erase(0, newline + 1);
                if (!line.empty() && line.back() == '\r') line.pop_back();
                observeRuntimeLogLine(line);
                if (line.find("POOL:") != std::string::npos ||
                    line.find("common_follower_run: rank ") != std::string::npos) {
                    OH_LOG_INFO(LOG_APP, "%{public}s", line.c_str());
                }
            }
        }
        close(descriptor);
    }).detach();
}

uint64_t modelDirectoryBytes(const std::string & modelPath) {
    const size_t slash = modelPath.find_last_of('/');
    if (slash == std::string::npos) return 0;
    const std::string directory = modelPath.substr(0, slash);
    uint64_t total = 0;
    DIR * dir = opendir(directory.c_str());
    if (dir != nullptr) {
        while (struct dirent * entry = readdir(dir)) {
            const std::string name(entry->d_name);
            if (name.size() < 5 || name.compare(name.size() - 5, 5, ".gguf") != 0) continue;
            struct stat info = {};
            if (stat((directory + "/" + name).c_str(), &info) == 0 && S_ISREG(info.st_mode)) {
                total += static_cast<uint64_t>(info.st_size);
            }
        }
        closedir(dir);
    }
    if (total > 0) return total;
    struct stat info = {};
    return stat(modelPath.c_str(), &info) == 0 ? static_cast<uint64_t>(info.st_size) : 0;
}

std::string modelAlias(const std::string & path) {
    std::string name = path;
    const size_t slash = name.find_last_of('/');
    if (slash != std::string::npos) name.erase(0, slash + 1);
    const size_t shard = name.find("-00001-of-");
    if (shard != std::string::npos) name.resize(shard);
    if (name.size() >= 5 && name.compare(name.size() - 5, 5, ".gguf") == 0) {
        name.resize(name.size() - 5);
    }
    return name;
}

std::vector<std::string> serverArguments(const std::string & modelPath, int32_t contextSize,
    const RuntimeOptions & options) {
    const int32_t nBatch = std::clamp(options.nBatch, 1, contextSize);
    const int32_t nUbatch = std::clamp(options.nUbatch, 1, nBatch);
    std::vector<std::string> args = {
        "llama-server",
        "-m", modelPath,
        "--host", "127.0.0.1",
        "-c", std::to_string(contextSize),
        "--port", std::to_string(kServerPort),
        "-np", std::to_string(std::max<int32_t>(1, options.nSeqMax)),
        "-b", std::to_string(nBatch),
        "-ub", std::to_string(nUbatch),
        "-rea", "off"
    };
    const std::string alias = modelAlias(modelPath);
    if (!alias.empty()) {
        args.push_back("--alias");
        args.push_back(alias);
    }
    if (options.ffnHotCold) args.push_back("--ffn-hot-cold");
    if (options.memoryBudgetMb > 0) {
        args.push_back("--memory-budget");
        args.push_back(std::to_string(options.memoryBudgetMb));
    }
    if (options.kvReservePct > 0.0f) {
        args.push_back("--kv-reserve-pct");
        args.push_back(std::to_string(options.kvReservePct));
    }
    if (options.ffnHotCold) {
        args.push_back("--hot-alpha");
        args.push_back(std::to_string(options.hotAlpha));
    }
    if (options.moeSkipK1 > 0) {
        args.push_back("--moe-skip-k1");
        args.push_back(std::to_string(options.moeSkipK1));
    }
    if (options.moeSkipK2 > 0) {
        args.push_back("--moe-skip-k2");
        args.push_back(std::to_string(options.moeSkipK2));
    }
    args.push_back(options.prefetch ? "--prefetch" : "--no-prefetch");
    if (options.distFollower) args.push_back("--follower");
    return args;
}

class ServerEngine {
public:
    ~ServerEngine() { release(); }

    bool prepare(const std::string & modelPath, int32_t contextSize, const RuntimeOptions & options,
        const std::string & runtimeKey, long long & loadMs) {
        if (serverThread.joinable() && g_modelReady.load() && modelPath == loadedPath &&
            contextSize == loadedContext && runtimeKey == loadedRuntimeKey) {
            loadMs = 0;
            return true;
        }
        release();

        configureDistributed(options);
        g_modelLoading.store(true);
        g_modelReady.store(false);
        g_serverFollowerReady.store(false);
        g_serverExitCode.store(1);
        backendExitCode.store(1);
        backendRunning.store(true);
        g_statusExpertRamBytes.store(0);
        g_statusDiskBytes.store(0);
        g_statusHitPct.store(-1);
        g_statusDistRank.store(options.distRanks > 1 ? options.distRank : -1);
        g_statusDistRanks.store(options.distRanks);
        g_statusDistFollower.store(options.distFollower);
        llama_set_bisect_params(options.moeSkipK1, options.moeSkipK2);
        setenv("LLAMA_HC_KV_DIR", options.kvDir.empty() ? "/data/storage/el2/base/haps/entry/files"
            : options.kvDir.c_str(), 1);
        setenv("LLAMA_POOL_DEBUG", "1", 1);
        ensureLogCapture();
        g_statusDiskBytes.store(modelDirectoryBytes(modelPath));

        size_t availableMiB = 0;
        RuntimeOptions runtimeOptions = options;
        runtimeOptions.memoryBudgetMb = safeMemoryBudgetMiB(options.memoryBudgetMb, availableMiB);
        std::vector<std::string> args = serverArguments(modelPath, contextSize, runtimeOptions);
        OH_LOG_INFO(LOG_APP,
            "server startup model=%{public}s context=%{public}d budgetMiB=%{public}zu "
            "requestedMiB=%{public}zu availableMiB=%{public}zu "
            "hotCold=%{public}d prefetch=%{public}d rank=%{public}d/%{public}d follower=%{public}d",
            modelPath.c_str(), contextSize, runtimeOptions.memoryBudgetMb,
            options.memoryBudgetMb, availableMiB, options.ffnHotCold ? 1 : 0,
            options.prefetch ? 1 : 0, options.distRank, options.distRanks,
            options.distFollower ? 1 : 0);
        const auto started = Clock::now();
        g_serverThreadRunning.store(true);
        serverThread = std::thread([this, args = std::move(args)]() mutable {
            std::vector<char *> argv;
            argv.reserve(args.size());
            for (std::string & arg : args) argv.push_back(arg.data());
            int result = 1;
            try {
                result = llama_server(static_cast<int>(argv.size()), argv.data());
            } catch (const std::exception & error) {
                OH_LOG_ERROR(LOG_APP, "llama_server exception: %{public}s", error.what());
            } catch (...) {
                OH_LOG_ERROR(LOG_APP, "llama_server unknown exception");
            }
            g_serverExitCode.store(result);
            backendExitCode.store(result);
            backendRunning.store(false);
            g_serverThreadRunning.store(false);
            g_modelReady.store(false);
            OH_LOG_INFO(LOG_APP, "llama_server exited ret=%{public}d", result);
        });

        const auto deadline = started + std::chrono::minutes(10);
        while (Clock::now() < deadline) {
            if (options.distFollower &&
                (g_serverFollowerReady.load() || localPortListening(30001))) {
                g_serverFollowerReady.store(true);
                g_modelReady.store(true);
                break;
            }
            if (!options.distFollower) {
                const HttpResponse health = requestHealth();
                if (health.status == 200 && health.body.find("\"status\":\"ok\"") != std::string::npos) {
                    g_modelReady.store(true);
                    break;
                }
            }
            if (!backendRunning.load()) {
                const int32_t result = backendExitCode.load();
                setStatus(result == 0 ? "llama-server stopped during startup" : "llama-server startup failed");
                g_modelLoading.store(false);
                return false;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(350));
        }
        if (!g_modelReady.load()) {
            setStatus("llama-server startup timed out");
            g_modelLoading.store(false);
            return false;
        }

        loadedPath = modelPath;
        loadedContext = contextSize;
        loadedRuntimeKey = runtimeKey;
        loadedFollower = options.distFollower;
        g_statusContext.store(contextSize);
        g_modelLoading.store(false);
        setStatus("", modelPath);
        loadMs = elapsedMs(started);
        OH_LOG_INFO(LOG_APP, "llama-server ready loadMs=%{public}lld", loadMs);
        return true;
    }

    bool backendAlive() const {
        return backendRunning.load();
    }

    std::string backendFailureMessage() const {
        return "llama-server 后端已退出（code " +
            std::to_string(backendExitCode.load()) + "），本次推理已中断。";
    }

    void release() {
        if (serverThread.joinable()) {
            if (backendRunning.load() && !loadedFollower) {
                llama_server_terminate();
            }
            serverThread.join();
        }
        loadedPath.clear();
        loadedRuntimeKey.clear();
        loadedContext = 0;
        loadedFollower = false;
        g_serverFollowerReady.store(false);
        g_serverThreadRunning.store(false);
        backendRunning.store(false);
        g_statusContext.store(0);
        g_statusDistRank.store(-1);
        g_statusDistRanks.store(1);
        g_statusDistFollower.store(false);
        g_statusExpertRamBytes.store(0);
        g_statusDiskBytes.store(0);
        g_statusHitPct.store(-1);
        g_modelReady.store(false);
        g_modelLoading.store(false);
    }

private:
    std::thread serverThread;
    std::atomic<bool> backendRunning{false};
    std::atomic<int32_t> backendExitCode{1};
    std::string loadedPath;
    std::string loadedRuntimeKey;
    int32_t loadedContext = 0;
    bool loadedFollower = false;
};

json usageFor(const json & object, long long loadMs, long long elapsed) {
    json usage = {
        {"model_load_latency", loadMs},
        {"prefill_latency", elapsed},
        {"decode_latency", 0},
        {"prompt_tokens", 0},
        {"completion_tokens", 0}
    };
    if (object.contains("timings") && object["timings"].is_object()) {
        const json & timings = object["timings"];
        if (timings.contains("prompt_ms") && timings["prompt_ms"].is_number()) {
            usage["prefill_latency"] = timings["prompt_ms"].get<double>();
        }
        if (timings.contains("predicted_ms") && timings["predicted_ms"].is_number()) {
            usage["decode_latency"] = timings["predicted_ms"].get<double>();
        }
    }
    if (object.contains("usage") && object["usage"].is_object()) {
        const json & reported = object["usage"];
        if (reported.contains("prompt_tokens") && reported["prompt_tokens"].is_number_integer()) {
            usage["prompt_tokens"] = reported["prompt_tokens"].get<int64_t>();
        }
        if (reported.contains("completion_tokens") && reported["completion_tokens"].is_number_integer()) {
            usage["completion_tokens"] = reported["completion_tokens"].get<int64_t>();
        }
    }
    return usage;
}

void executeServer(ServerEngine & engine, const Job & job) {
    const auto started = Clock::now();
    const auto deadline = job.waitSeconds > 0 ?
        started + std::chrono::seconds(job.waitSeconds) : Clock::time_point::max();

    InferenceRequest request;
    std::string parseError;
    if (!parseRequest(job.requestJson, request, parseError)) {
        pushEvent(job.id, "create", "invalid-request");
        pushError(job.id, parseError, elapsedMs(started));
        pushEvent(job.id, "end", "error", elapsedMs(started));
        return;
    }

    long long loadMs = 0;
    if (!engine.prepare(job.modelPath, job.contextSize, job.runtimeOptions,
        job.runtimeOptionsJson, loadMs)) {
        std::string message;
        {
            std::lock_guard<std::mutex> lock(g_statusMutex);
            message = g_statusError;
        }
        pushEvent(job.id, "file_error", "1");
        pushError(job.id, message.empty() ? "llama-server model load failed" : message,
            elapsedMs(started));
        pushEvent(job.id, "end", "load_failed", elapsedMs(started));
        return;
    }
    if (g_cancelCurrent.load()) {
        engine.release();
        pushEvent(job.id, "end", "cancelled", elapsedMs(started));
        return;
    }

    json payload;
    try {
        payload = json::parse(job.requestJson);
        payload["stream"] = true;
        payload["cache_prompt"] = false;
    } catch (const std::exception & error) {
        pushError(job.id, std::string("request JSON error: ") + error.what(), elapsedMs(started));
        pushEvent(job.id, "end", "error", elapsedMs(started));
        return;
    }
    const std::string body = dumpJson(payload);
    const std::string requestText =
        "POST /v1/chat/completions HTTP/1.1\r\n"
        "Host: 127.0.0.1\r\n"
        "Content-Type: application/json\r\n"
        "Accept: text/event-stream\r\n"
        "Connection: close\r\n"
        "Content-Length: " + std::to_string(body.size()) + "\r\n\r\n" + body;
    const int descriptor = connectLocalServer();
    if (descriptor < 0 || !sendAll(descriptor, requestText)) {
        if (descriptor >= 0) close(descriptor);
        pushError(job.id, "llama-server local HTTP connection failed", elapsedMs(started));
        pushEvent(job.id, "end", "connection_failed", elapsedMs(started));
        return;
    }
    pushEvent(job.id, "create", "0", elapsedMs(started));
    pushEvent(job.id, "submit", "0", elapsedMs(started));

    std::string raw;
    std::string headers;
    bool haveHeaders = false;
    bool chunked = false;
    bool complete = false;
    bool finishSeen = false;
    bool protocolError = false;
    int status = 0;
    std::string answer;
    std::string finishReason;
    std::string errorMessage;
    std::string sseRemainder;
    json reportedUsage = {
        {"model_load_latency", loadMs},
        {"prefill_latency", 0},
        {"decode_latency", 0},
        {"prompt_tokens", 0},
        {"completion_tokens", 0}
    };
    ChunkedDecoder decoder;

    auto consumeSse = [&](const std::string & decoded) {
        sseRemainder += decoded;
        for (;;) {
            const size_t newline = sseRemainder.find('\n');
            if (newline == std::string::npos) break;
            std::string line = sseRemainder.substr(0, newline);
            sseRemainder.erase(0, newline + 1);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (line.compare(0, 5, "data:") != 0) continue;
            std::string data = line.substr(5);
            if (!data.empty() && data.front() == ' ') data.erase(0, 1);
            if (data == "[DONE]") {
                complete = true;
                continue;
            }
            try {
                const json event = json::parse(data);
                if (event.contains("error")) {
                    protocolError = true;
                    const json & error = event["error"];
                    errorMessage = error.is_object() && error.contains("message") &&
                        error["message"].is_string() ? error["message"].get<std::string>() :
                        dumpJson(error);
                }
                if (event.contains("choices") && event["choices"].is_array() &&
                    !event["choices"].empty()) {
                    const json & choice = event["choices"][0];
                    if (choice.contains("delta") && choice["delta"].is_object()) {
                        const json & delta = choice["delta"];
                        if (delta.contains("content") && delta["content"].is_string()) {
                            const std::string content = delta["content"].get<std::string>();
                            if (!content.empty()) {
                                answer += content;
                                if (request.stream) {
                                    json response = {
                                        {"message", {{"role", "assistant"}, {"content", content}}},
                                        {"finish_reason", nullptr},
                                        {"usage", usageFor(event, loadMs, elapsedMs(started))}
                                    };
                                    pushEvent(job.id, "response", dumpJson(response), elapsedMs(started));
                                }
                            }
                        }
                    }
                    if (choice.contains("finish_reason") && choice["finish_reason"].is_string()) {
                        finishReason = choice["finish_reason"].get<std::string>();
                        finishSeen = true;
                    }
                }
                if (event.contains("usage") || event.contains("timings")) {
                    reportedUsage = usageFor(event, loadMs, elapsedMs(started));
                }
            } catch (const std::exception & error) {
                protocolError = true;
                errorMessage = std::string("invalid server SSE JSON: ") + error.what();
            }
        }
    };

    char buffer[16384];
    while (!complete && !protocolError) {
        if (g_cancelCurrent.load()) {
            finishReason = "cancelled";
            break;
        }
        if (deadline != Clock::time_point::max() && Clock::now() >= deadline) {
            finishReason = "timeout";
            break;
        }
        struct pollfd item = {descriptor, POLLIN, 0};
        const int ready = poll(&item, 1, 300);
        if (ready == 0) {
            if (!engine.backendAlive()) {
                protocolError = true;
                errorMessage = engine.backendFailureMessage();
                break;
            }
            continue;
        }
        if (ready < 0) {
            if (errno == EINTR) continue;
            protocolError = true;
            errorMessage = "llama-server response poll failed";
            break;
        }
        const ssize_t count = recv(descriptor, buffer, sizeof(buffer), 0);
        if (count == 0) {
            if (!finishSeen && !complete) {
                protocolError = true;
                errorMessage = engine.backendAlive() ?
                    "llama-server 在响应完成前关闭了连接。" : engine.backendFailureMessage();
            }
            break;
        }
        if (count < 0) {
            if (errno == EINTR) continue;
            protocolError = true;
            errorMessage = "llama-server response read failed";
            break;
        }
        if (!haveHeaders) {
            raw.append(buffer, static_cast<size_t>(count));
            bool crlf = false;
            const size_t split = headerEnd(raw, crlf);
            if (split == std::string::npos) continue;
            headers = raw.substr(0, split);
            status = responseStatus(headers);
            chunked = responseIsChunked(headers);
            const std::string initial = raw.substr(split);
            raw.clear();
            haveHeaders = true;
            if (status < 200 || status >= 300) {
                if (chunked) {
                    std::string decoded;
                    bool chunkDone = false;
                    decoder.feed(initial.data(), initial.size(), decoded, chunkDone);
                    errorMessage += decoded;
                } else {
                    errorMessage += initial;
                }
                protocolError = true;
                break;
            }
            if (chunked) {
                std::string decoded;
                bool chunkDone = false;
                decoder.feed(initial.data(), initial.size(), decoded, chunkDone);
                if (!decoded.empty()) consumeSse(decoded);
                if (chunkDone) complete = true;
            } else if (!initial.empty()) {
                consumeSse(initial);
            }
            continue;
        }
        if (chunked) {
            std::string decoded;
            bool chunkDone = false;
            decoder.feed(buffer, static_cast<size_t>(count), decoded, chunkDone);
            if (!decoded.empty()) consumeSse(decoded);
            if (chunkDone) complete = true;
        } else {
            consumeSse(std::string(buffer, static_cast<size_t>(count)));
        }
    }
    close(descriptor);
    if (g_cancelCurrent.load()) finishReason = "cancelled";
    if (finishReason.empty() && !protocolError) finishReason = answer.empty() ? "empty" : "stop";
    if (protocolError) {
        json error = json::parse(errorMessage.empty() ? "{\"message\":\"llama-server request failed\"}" :
            errorMessage, nullptr, false);
        std::string message = errorMessage;
        if (error.is_object() && error.contains("error") && error["error"].is_object() &&
            error["error"].contains("message") && error["error"]["message"].is_string()) {
            message = error["error"]["message"].get<std::string>();
        }
        pushError(job.id, message.empty() ? "llama-server request failed" : message, elapsedMs(started));
        pushEvent(job.id, "end", "error", elapsedMs(started));
    } else {
        if (reportedUsage["decode_latency"].get<double>() == 0.0 &&
            reportedUsage["completion_tokens"].get<int64_t>() > 0) {
            reportedUsage["decode_latency"] = elapsedMs(started);
        }
        json response = {
            {"message", {{"role", "assistant"}, {"content", request.stream ? "" : answer}}},
            {"finish_reason", finishReason},
            {"usage", reportedUsage}
        };
        pushEvent(job.id, "response", dumpJson(response), elapsedMs(started));
        pushEvent(job.id, "end", finishReason, elapsedMs(started));
    }
    if (finishReason == "cancelled" || finishReason == "timeout") engine.release();
}

class Engine {
public:
    ~Engine() { release(); }

    bool prepare(const std::string & modelPath, int32_t contextSize, const RuntimeOptions & options,
        const std::string & runtimeKey, long long & loadMs) {
        if (model != nullptr && modelPath == loadedPath && context != nullptr &&
            llama_n_ctx(context) == contextSize && runtimeKey == loadedRuntimeKey) {
            loadMs = 0;
            setStatus("", modelPath);
            g_modelReady.store(true);
            return true;
        }
        release();

        configureDistributed(options);
        g_statusExpertRamBytes.store(0);
        g_statusDiskBytes.store(0);
        g_statusHitPct.store(-1);
        const int32_t nBatch = std::clamp(options.nBatch, 1, contextSize);
        const int32_t nUbatch = std::clamp(options.nUbatch, 1, nBatch);
        llama_set_bisect_params(options.moeSkipK1, options.moeSkipK2);
        if (!options.kvDir.empty()) {
            setenv("LLAMA_HC_KV_DIR", options.kvDir.c_str(), 1);
        }
        g_statusDistRank.store(options.distRanks > 1 ? options.distRank : -1);
        g_statusDistRanks.store(options.distRanks);
        g_statusDistFollower.store(options.distFollower);
        if (options.ffnHotCold) {
            setenv("LLAMA_POOL_DEBUG", "1", 1);
        }
        size_t availableMiB = 0;
        const size_t effectiveBudget = safeMemoryBudgetMiB(options.memoryBudgetMb, availableMiB);
        OH_LOG_INFO(LOG_APP,
            "runtime budgetMiB=%{public}zu requestedMiB=%{public}zu availableMiB=%{public}zu "
            "hotCold=%{public}d extraBufts=%{public}d prefetch=%{public}d "
            "skip=%{public}d:%{public}d batch=%{public}d/%{public}d seq=%{public}d kvDir=%{public}s",
            effectiveBudget, options.memoryBudgetMb, availableMiB,
            options.ffnHotCold ? 1 : 0, options.useExtraBufts ? 1 : 0, options.prefetch ? 1 : 0,
            options.moeSkipK1, options.moeSkipK2, nBatch, nUbatch, options.nSeqMax,
            options.kvDir.c_str());

        const auto loadStart = Clock::now();
        llama_model_params modelParams = llama_model_default_params();
        modelParams.n_gpu_layers = 0;
        modelParams.load_mode = LLAMA_LOAD_MODE_MMAP;
        modelParams.memory_budget = effectiveBudget * 1024ULL * 1024ULL;
        modelParams.kv_reserve_pct = options.kvReservePct;
        modelParams.hot_alpha = options.hotAlpha;
        modelParams.ffn_hot_cold = options.ffnHotCold;
        modelParams.prefetch = options.prefetch;
        modelParams.use_extra_bufts = options.useExtraBufts;
        modelParams.placement_n_ctx = static_cast<uint32_t>(contextSize);
        modelParams.placement_n_batch = static_cast<uint32_t>(nUbatch);
        modelParams.placement_n_seq_max = static_cast<uint32_t>(options.nSeqMax);
        model = llama_model_load_from_file(modelPath.c_str(), modelParams);
        if (model == nullptr) {
            g_modelReady.store(false);
            setStatus("GGUF model load failed");
            OH_LOG_ERROR(LOG_APP, "load failed: %{public}s", modelPath.c_str());
            return false;
        }
        g_statusDiskBytes.store(llama_model_size(model));

        llama_context_params params = llama_context_default_params();
        params.n_ctx = static_cast<uint32_t>(std::clamp(contextSize, 512, 32768));
        params.n_batch = static_cast<uint32_t>(nBatch);
        params.n_ubatch = static_cast<uint32_t>(nUbatch);
        params.n_seq_max = static_cast<uint32_t>(options.nSeqMax);
        params.n_outputs_max_per_seq = 1;
        params.moe_skip_k1 = options.moeSkipK1;
        params.moe_skip_k2 = options.moeSkipK2;
        const int32_t threads = std::max<int32_t>(1, static_cast<int32_t>(std::thread::hardware_concurrency()));
        params.n_threads = std::min<int32_t>(threads, 8);
        params.n_threads_batch = params.n_threads;
        params.no_perf = false;
        params.abort_callback = [](void *) -> bool { return g_cancelCurrent.load(); };
        params.abort_callback_data = nullptr;
        context = llama_init_from_model(model, params);
        if (context == nullptr) {
            OH_LOG_ERROR(LOG_APP, "context create failed");
            g_modelReady.store(false);
            setStatus("llama context create failed");
            release();
            return false;
        }

        loadedPath = modelPath;
        loadedRuntimeKey = runtimeKey;
        loadMs = elapsedMs(loadStart);
        setStatus("", modelPath);
        g_statusContext.store(static_cast<int32_t>(llama_n_ctx(context)));
        g_modelReady.store(true);
        return true;
    }

    llama_model * modelPtr() const { return model; }
    llama_context * contextPtr() const { return context; }

    void release() {
        if (context != nullptr) {
            llama_free(context);
            context = nullptr;
        }
        if (model != nullptr) {
            llama_model_free(model);
            model = nullptr;
        }
        loadedPath.clear();
        loadedRuntimeKey.clear();
        g_statusContext.store(0);
        g_statusDistRank.store(-1);
        g_statusDistRanks.store(1);
        g_statusDistFollower.store(false);
        g_statusExpertRamBytes.store(0);
        g_statusDiskBytes.store(0);
        g_statusHitPct.store(-1);
        g_modelReady.store(false);
    }

private:
    llama_model * model = nullptr;
    llama_context * context = nullptr;
    std::string loadedPath;
    std::string loadedRuntimeKey;
};

void execute(Engine & engine, const Job & job) {
    const auto started = Clock::now();
    const auto deadline = job.waitSeconds > 0 ? started + std::chrono::seconds(job.waitSeconds) : Clock::time_point::max();

    InferenceRequest request;
    std::string error;
    if (!parseRequest(job.requestJson, request, error)) {
        pushEvent(job.id, "create", "invalid-request");
        pushError(job.id, error, elapsedMs(started));
        pushEvent(job.id, "end", "error", elapsedMs(started));
        return;
    }

    long long loadMs = 0;
    if (!engine.prepare(job.modelPath, job.contextSize, job.runtimeOptions,
        job.runtimeOptionsJson, loadMs)) {
        pushEvent(job.id, "file_error", "1");
        pushError(job.id, "GGUF 模型加载失败。", elapsedMs(started));
        pushEvent(job.id, "end", "load_failed", elapsedMs(started));
        return;
    }

    llama_model * model = engine.modelPtr();
    llama_context * context = engine.contextPtr();
    const llama_vocab * vocab = llama_model_get_vocab(model);
    const std::string prompt = formatMessages(model, request);
    const int32_t promptCapacity = -llama_tokenize(vocab, prompt.c_str(), prompt.size(), nullptr, 0, true, true);
    if (promptCapacity <= 0) {
        pushError(job.id, "提示词分词失败。", elapsedMs(started));
        pushEvent(job.id, "end", "tokenize_failed", elapsedMs(started));
        return;
    }

    std::vector<llama_token> promptTokens(static_cast<size_t>(promptCapacity));
    const int32_t tokenized = llama_tokenize(
        vocab, prompt.c_str(), prompt.size(), promptTokens.data(), promptCapacity, true, true);
    if (tokenized <= 0) {
        pushError(job.id, "提示词分词失败。", elapsedMs(started));
        pushEvent(job.id, "end", "tokenize_failed", elapsedMs(started));
        return;
    }
    promptTokens.resize(static_cast<size_t>(tokenized));

    const int32_t contextSize = static_cast<int32_t>(llama_n_ctx(context));
    const int32_t outputLimit = std::min(request.maxTokens, contextSize - tokenized - 1);
    if (outputLimit <= 0) {
        pushError(job.id, "提示词超过模型上下文长度。", elapsedMs(started));
        pushEvent(job.id, "end", "context_exceeded", elapsedMs(started));
        return;
    }

    if (llama_dist_n_ranks(context) > 1) {
        if (llama_dist_rank(context) != 0 || !llama_dist_begin_request(context)) {
            pushError(job.id, "分布式推理会话不可用。", elapsedMs(started));
            pushEvent(job.id, "end", "distributed_unavailable", elapsedMs(started));
            return;
        }
    }
    llama_memory_clear(llama_get_memory(context), true);
    llama_perf_context_reset(context);
    llama_sampler * sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05f, 1));
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.8f));
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    pushEvent(job.id, "create", "0", elapsedMs(started));
    const auto prefillStart = Clock::now();
    llama_batch batch = llama_batch_get_one(promptTokens.data(), static_cast<int32_t>(promptTokens.size()));
    int32_t decodeResult = llama_decode(context, batch);
    const long long prefillMs = elapsedMs(prefillStart);
    if (decodeResult != 0) {
        llama_sampler_free(sampler);
        const bool cancelled = g_cancelCurrent.load();
        const std::string reason = cancelled ? "cancelled" : "prefill_failed";
        pushError(job.id, cancelled ? "已停止生成。" : "模型预填充失败。", elapsedMs(started));
        pushEvent(job.id, "end", reason, elapsedMs(started));
        return;
    }
    pushEvent(job.id, "submit", "0", elapsedMs(started));

    std::string answer;
    std::string pendingUtf8;
    int32_t generated = 0;
    std::string finishReason = "length";
    const auto decodeStart = Clock::now();
    while (generated < outputLimit) {
        if (g_cancelCurrent.load() || (deadline != Clock::time_point::max() && Clock::now() >= deadline)) {
            finishReason = g_cancelCurrent.load() ? "cancelled" : "timeout";
            break;
        }

        const llama_token token = llama_sampler_sample(sampler, context, -1);
        if (llama_vocab_is_eog(vocab, token)) {
            finishReason = "stop";
            break;
        }
        const std::string piece = tokenPiece(vocab, token);
        pendingUtf8 += piece;
        generated += 1;

        std::string content = takeCompleteUtf8(pendingUtf8);
        answer += content;
        if (request.stream && !content.empty()) {
            json usage = {
                {"model_load_latency", loadMs},
                {"prefill_latency", prefillMs},
                {"decode_latency", elapsedMs(decodeStart)},
                {"prompt_tokens", tokenized},
                {"completion_tokens", generated}
            };
            json response = {
                {"message", {{"role", "assistant"}, {"content", content}}},
                {"finish_reason", nullptr},
                {"usage", usage}
            };
            pushEvent(job.id, "response", dumpJson(response), elapsedMs(started));
        }

        batch = llama_batch_get_one(const_cast<llama_token *>(&token), 1);
        decodeResult = llama_decode(context, batch);
        if (decodeResult != 0) {
            const bool cancelled = g_cancelCurrent.load();
            finishReason = cancelled ? "cancelled" : "decode_failed";
            break;
        }
    }

    const std::string tail = flushUtf8(pendingUtf8);
    answer += tail;
    const long long decodeMs = elapsedMs(decodeStart);
    json finalUsage = {
        {"model_load_latency", loadMs},
        {"prefill_latency", prefillMs},
        {"decode_latency", decodeMs},
        {"prompt_tokens", tokenized},
        {"completion_tokens", generated}
    };
    json finalResponse = {
        {"message", {{"role", "assistant"}, {"content", request.stream ? tail : answer}}},
        {"finish_reason", finishReason},
        {"usage", finalUsage}
    };
    pushEvent(job.id, "response", dumpJson(finalResponse), elapsedMs(started));
    if (finishReason == "decode_failed") {
        pushError(job.id, "模型解码失败。", elapsedMs(started));
    }
    llama_sampler_free(sampler);
    // The start of the next request clears the KV cache. A distributed clear is
    // mirrored to the follower, and doing it again here can leave rank 0 busy
    // after the final response has already been delivered.
    if (llama_dist_n_ranks(context) <= 1) {
        llama_memory_clear(llama_get_memory(context), false);
    }
    pushEvent(job.id, "end", finishReason, elapsedMs(started));
}

void followerLoop(Engine & engine) {
    llama_context * context = engine.contextPtr();
    if (context == nullptr || llama_dist_n_ranks(context) < 2 || llama_dist_rank(context) == 0) {
        setStatus("分布式 follower 上下文无效");
        return;
    }
    OH_LOG_INFO(LOG_APP, "follower ready rank=%{public}d/%{public}d",
        llama_dist_rank(context), llama_dist_n_ranks(context));
    llama_batch batch = llama_batch_init(
        static_cast<int32_t>(std::max(llama_n_ubatch(context), llama_n_batch(context))),
        0, static_cast<int32_t>(llama_n_seq_max(context)));
    int32_t linkErrors = 0;
    while (true) {
        const int32_t nTokens = llama_dist_follower_next_batch(context, &batch);
        if (nTokens == -2) {
            llama_memory_clear(llama_get_memory(context), true);
            linkErrors = 0;
            if (!llama_dist_mark_follower_ready(context)) {
                std::this_thread::sleep_for(std::chrono::milliseconds(250));
            }
            continue;
        }
        if (nTokens == 0) {
            OH_LOG_INFO(LOG_APP, "distributed rank 0 finished; follower waiting for next session");
            break;
        }
        if (nTokens < 0) {
            if (linkErrors == 0) llama_memory_clear(llama_get_memory(context), true);
            if (linkErrors == 0 || linkErrors % 20 == 0) {
                OH_LOG_WARN(LOG_APP, "distributed link unavailable; follower remains alive");
            }
            ++linkErrors;
            std::this_thread::sleep_for(std::chrono::milliseconds(250));
            continue;
        }
        linkErrors = 0;
        const int32_t result = llama_decode(context, batch);
        if (result != 0) {
            llama_memory_clear(llama_get_memory(context), true);
            if (linkErrors == 0 || linkErrors % 20 == 0) {
                OH_LOG_WARN(LOG_APP, "follower decode failed ret=%{public}d", result);
            }
            ++linkErrors;
            std::this_thread::sleep_for(std::chrono::milliseconds(250));
        }
    }
    llama_batch_free(batch);
}

void workerMain() {
    llama_log_set(llamaLogCallback, nullptr);
    ServerEngine engine;
    for (;;) {
        Job job;
        {
            std::unique_lock<std::mutex> lock(g_queueMutex);
            g_queueCv.wait(lock, [] { return !g_jobs.empty(); });
            job = std::move(g_jobs.front());
            g_jobs.pop_front();
        }
        if (job.unload) {
            engine.release();
            setStatus("");
            continue;
        }
        if (job.preload) {
            g_runningJobId.store(job.id);
            g_modelLoading.store(true);
            long long loadMs = 0;
            if (!engine.prepare(job.modelPath, job.contextSize, job.runtimeOptions,
                job.runtimeOptionsJson, loadMs)) {
                setStatus("GGUF model load failed");
            }
            g_modelLoading.store(false);
            g_runningJobId.store(0);
            continue;
        }
        g_runningJobId.store(job.id);
        g_cancelCurrent.store(false);
        if (!g_modelReady.load()) {
            g_modelLoading.store(true);
        }
        try {
            executeServer(engine, job);
        } catch (const std::exception & e) {
            pushError(job.id, std::string("Native 推理异常: ") + e.what(), 0);
            pushEvent(job.id, "end", "exception", 0);
        } catch (...) {
            pushError(job.id, "Native 推理发生未知异常。", 0);
            pushEvent(job.id, "end", "exception", 0);
        }
        g_modelLoading.store(false);
        g_runningJobId.store(0);
        g_cancelCurrent.store(false);
        if (g_unloadAfterJob.exchange(false)) {
            engine.release();
        }
    }
}

void ensureWorker() {
    std::lock_guard<std::mutex> lock(g_queueMutex);
    if (!g_workerStarted) {
        g_workerStarted = true;
        std::thread(workerMain).detach();
    }
}

void logRejectedStart(const char * reason, int64_t running, size_t queued) {
    OH_LOG_WARN(LOG_APP, "start rejected: %{public}s running=%{public}lld queued=%{public}zu",
        reason, running, queued);
}

std::string getString(napi_env env, napi_value value) {
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        return std::string();
    }
    std::vector<char> buffer(length + 1, '\0');
    napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length);
    return std::string(buffer.data(), length);
}

std::string interfaceIp(const std::string & name) {
    struct ifaddrs * addresses = nullptr;
    if (getifaddrs(&addresses) != 0) return std::string();
    std::string result;
    for (struct ifaddrs * item = addresses; item != nullptr; item = item->ifa_next) {
        if (item->ifa_addr == nullptr || item->ifa_addr->sa_family != AF_INET || name != item->ifa_name) continue;
        char buffer[INET_ADDRSTRLEN] = {};
        inet_ntop(AF_INET, &reinterpret_cast<struct sockaddr_in *>(item->ifa_addr)->sin_addr,
            buffer, sizeof(buffer));
        result = buffer;
        break;
    }
    freeifaddrs(addresses);
    return result;
}

napi_value NetworkIps(napi_env env, napi_callback_info info) {
    std::string wifi = interfaceIp("wlan0");
    std::string usb;
    for (const char * name : {"usb0", "rndis0", "ncm0", "usb1"}) {
        usb = interfaceIp(name);
        if (!usb.empty()) break;
    }
    std::string eth = interfaceIp("eth0");
    json value = {{"wifi", wifi}, {"usb", usb}, {"eth", eth}};
    const std::string output = dumpJson(value);
    napi_value result;
    napi_create_string_utf8(env, output.c_str(), output.size(), &result);
    return result;
}

napi_value NetworkNeighbors(napi_env env, napi_callback_info info) {
    nlohmann::json result = nlohmann::json::array();
    int descriptor = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
    if (descriptor < 0) {
        napi_value output;
        const std::string empty = "[]";
        napi_create_string_utf8(env, empty.c_str(), empty.size(), &output);
        return output;
    }
    struct {
        struct nlmsghdr header;
        struct ndmsg message;
    } request = {};
    request.header.nlmsg_len = NLMSG_LENGTH(sizeof(struct ndmsg));
    request.header.nlmsg_type = RTM_GETNEIGH;
    request.header.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
    request.header.nlmsg_seq = 1;
    request.message.ndm_family = AF_INET;
    struct sockaddr_nl kernel = {};
    kernel.nl_family = AF_NETLINK;
    if (sendto(descriptor, &request, request.header.nlmsg_len, 0,
        reinterpret_cast<struct sockaddr *>(&kernel), sizeof(kernel)) >= 0) {
        char buffer[8192];
        bool done = false;
        while (!done) {
            ssize_t length = recv(descriptor, buffer, sizeof(buffer), 0);
            if (length <= 0) break;
            for (struct nlmsghdr * header = reinterpret_cast<struct nlmsghdr *>(buffer);
                 NLMSG_OK(header, length); header = NLMSG_NEXT(header, length)) {
                if (header->nlmsg_type == NLMSG_DONE) {
                    done = true;
                    break;
                }
                if (header->nlmsg_type != RTM_NEWNEIGH) continue;
                struct ndmsg * neighbor = reinterpret_cast<struct ndmsg *>(NLMSG_DATA(header));
                const int valid = NUD_REACHABLE | NUD_STALE | NUD_DELAY | NUD_PROBE |
                    NUD_NOARP | NUD_PERMANENT;
                if (neighbor->ndm_family != AF_INET || (neighbor->ndm_state & valid) == 0) continue;
                char ip[INET_ADDRSTRLEN] = {};
                char mac[32] = {};
                char interface[IF_NAMESIZE] = {};
                int attributes = RTM_PAYLOAD(header);
                for (struct rtattr * attribute = RTM_RTA(neighbor); RTA_OK(attribute, attributes);
                     attribute = RTA_NEXT(attribute, attributes)) {
                    if (attribute->rta_type == NDA_DST) {
                        inet_ntop(AF_INET, RTA_DATA(attribute), ip, sizeof(ip));
                    } else if (attribute->rta_type == NDA_LLADDR && RTA_PAYLOAD(attribute) >= 6) {
                        const unsigned char * bytes =
                            reinterpret_cast<const unsigned char *>(RTA_DATA(attribute));
                        snprintf(mac, sizeof(mac), "%02x:%02x:%02x:%02x:%02x:%02x",
                            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]);
                    }
                }
                if (ip[0] == '\0' || mac[0] == '\0') continue;
                if_indextoname(neighbor->ndm_ifindex, interface);
                result.push_back({{"ip", ip}, {"mac", mac}, {"iface", interface}});
            }
        }
    }
    close(descriptor);
    const std::string output = dumpJson(result);
    napi_value value;
    napi_create_string_utf8(env, output.c_str(), output.size(), &value);
    return value;
}

napi_value Start(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) {
        napi_value invalid;
        napi_create_int64(env, -1, &invalid);
        return invalid;
    }

    int32_t waitSeconds = 0;
    int32_t contextSize = 8192;
    napi_get_value_int32(env, args[2], &waitSeconds);
    napi_get_value_int32(env, args[3], &contextSize);
    Job job;
    job.modelPath = getString(env, args[0]);
    job.requestJson = getString(env, args[1]);
    job.waitSeconds = waitSeconds;
    job.contextSize = contextSize;
    if (argc >= 5) {
        job.runtimeOptionsJson = getString(env, args[4]);
        job.runtimeOptions = parseRuntimeOptions(job.runtimeOptionsJson);
    }

    ensureWorker();
    int64_t jobId = 0;
    {
        std::lock_guard<std::mutex> lock(g_queueMutex);
        if (job.modelPath.empty()) {
            logRejectedStart("empty model path", g_runningJobId.load(), g_jobs.size());
            napi_value invalid;
            napi_create_int64(env, -2, &invalid);
            return invalid;
        }
        if (g_runningJobId.load() != 0 || !g_jobs.empty()) {
            logRejectedStart("worker busy", g_runningJobId.load(), g_jobs.size());
            napi_value busy;
            napi_create_int64(env, -1, &busy);
            return busy;
        }
        jobId = ++g_nextJobId;
        job.id = jobId;
        g_jobs.push_back(std::move(job));
    }
    g_queueCv.notify_one();

    napi_value result;
    napi_create_int64(env, jobId, &result);
    return result;
}

napi_value Preload(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_value invalid;
        napi_create_int64(env, -1, &invalid);
        return invalid;
    }
    int32_t contextSize = 8192;
    napi_get_value_int32(env, args[1], &contextSize);
    Job job;
    job.preload = true;
    job.modelPath = getString(env, args[0]);
    job.contextSize = contextSize;
    if (argc >= 3) {
        job.runtimeOptionsJson = getString(env, args[2]);
        job.runtimeOptions = parseRuntimeOptions(job.runtimeOptionsJson);
    }
    ensureWorker();
    int64_t jobId = 0;
    {
        std::lock_guard<std::mutex> lock(g_queueMutex);
        if (g_runningJobId.load() != 0 || !g_jobs.empty() || job.modelPath.empty()) {
            napi_value busy;
            napi_create_int64(env, -1, &busy);
            return busy;
        }
        jobId = ++g_nextJobId;
        job.id = jobId;
        g_modelLoading.store(true);
        g_jobs.push_back(std::move(job));
    }
    g_queueCv.notify_one();
    napi_value result;
    napi_create_int64(env, jobId, &result);
    return result;
}

napi_value Status(napi_env env, napi_callback_info info) {
    std::string model;
    std::string error;
    {
        std::lock_guard<std::mutex> lock(g_statusMutex);
        model = g_statusModel;
        error = g_statusError;
    }
    const bool ready = g_modelReady.load();
    const bool loading = g_modelLoading.load();
    const bool busy = g_runningJobId.load() != 0;
    const char * state = error.empty() ? (loading ? "loading" : (ready ? (busy ? "busy" : "ready") : "idle")) : "error";
    json value = {
        {"state", state},
        {"model", model},
        {"context", g_statusContext.load()},
        {"error", error},
        {"rss", processRssBytes()},
        {"expertRam", g_statusExpertRamBytes.load()},
        {"hit", g_statusHitPct.load()},
        {"disk", g_statusDiskBytes.load()},
        {"distRank", -1},
        {"distRanks", g_statusDistRanks.load()},
        {"distFollower", g_statusDistFollower.load()}
    };
    value["distRank"] = g_statusDistRank.load();
    const std::string output = dumpJson(value);
    napi_value result;
    napi_create_string_utf8(env, output.c_str(), output.size(), &result);
    return result;
}

napi_value SetDistConfig(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t rank = 0;
    int32_t ranks = 1;
    if (argc >= 1) napi_get_value_int32(env, args[0], &rank);
    if (argc >= 2) napi_get_value_int32(env, args[1], &ranks);
    RuntimeOptions options;
    options.distRank = rank;
    options.distRanks = ranks;
    options.distEndpoints = argc >= 3 ? getString(env, args[2]) : std::string();
    options.distSplit = argc >= 4 ? getString(env, args[3]) : std::string();
    options.distFollower = ranks > 1 && rank > 0;
    configureDistributed(options);
    napi_value result;
    napi_create_int32(env, 0, &result);
    return result;
}

napi_value TakeEvents(napi_env env, napi_callback_info info) {
    std::vector<std::string> events;
    {
        std::lock_guard<std::mutex> lock(g_eventMutex);
        events.swap(g_events);
    }
    napi_value array;
    napi_create_array_with_length(env, events.size(), &array);
    for (size_t i = 0; i < events.size(); ++i) {
        napi_value value;
        napi_create_string_utf8(env, events[i].c_str(), events[i].size(), &value);
        napi_set_element(env, array, static_cast<uint32_t>(i), value);
    }
    return array;
}

napi_value Cancel(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t id = -1;
    if (argc > 0) {
        napi_get_value_int64(env, args[0], &id);
    }
    if (id <= 0 || id == g_runningJobId.load()) {
        g_cancelCurrent.store(true);
    }
    return nullptr;
}

napi_value Release(napi_env env, napi_callback_info info) {
    g_cancelCurrent.store(true);
    ensureWorker();
    bool queued = false;
    {
        std::lock_guard<std::mutex> lock(g_queueMutex);
        if (g_runningJobId.load() == 0 && g_jobs.empty()) {
            Job job;
            job.unload = true;
            g_jobs.push_back(std::move(job));
            queued = true;
        } else {
            g_unloadAfterJob.store(true);
        }
    }
    if (queued) {
        g_queueCv.notify_one();
    }
    return nullptr;
}

napi_value Complete(napi_env env, napi_callback_info info) {
    return nullptr;
}

} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"preload", nullptr, Preload, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"status", nullptr, Status, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setdistconfig", nullptr, SetDistConfig, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getnetworkips", nullptr, NetworkIps, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getnetworkneighbors", nullptr, NetworkNeighbors, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"takeEvents", nullptr, TakeEvents, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancel", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"complete", nullptr, Complete, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"release", nullptr, Release, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module llamaProbeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "llama_probe",
    .nm_priv = nullptr,
    .reserved = {0}
};

extern "C" __attribute__((constructor)) void RegisterLlamaProbeModule(void) {
    napi_module_register(&llamaProbeModule);
}
