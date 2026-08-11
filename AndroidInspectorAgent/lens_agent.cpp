#include <jni.h>
#include <jvmti.h>

#include <android/log.h>
#include <arpa/inet.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_set>
#include <utility>
#include <vector>

namespace {

constexpr char kTag[] = "LensJVMTI";
constexpr size_t kMaximumEvents = 1000;
constexpr jint kMaximumFrames = 64;

JavaVM* g_vm = nullptr;
jvmtiEnv* g_jvmti = nullptr;
std::string g_socket_name;
std::string g_token;
std::atomic<bool> g_running{false};
std::atomic<bool> g_saw_okhttp{false};
std::atomic<uint64_t> g_sequence{0};
std::atomic<uint64_t> g_breakpoint_callbacks{0};
std::mutex g_queue_mutex;
std::condition_variable g_queue_condition;
std::deque<std::string> g_events;
std::mutex g_breakpoint_mutex;
std::mutex g_attach_mutex;
std::mutex g_request_mutex;
std::unordered_set<jmethodID> g_instrumented_methods;
std::vector<std::pair<jmethodID, jlocation>> g_breakpoints;
std::unordered_set<int> g_recent_request_identities;
std::deque<int> g_recent_request_order;
std::thread g_server_thread;
int g_server_fd = -1;
int g_client_fd = -1;

void Log(const std::string& message) {
    __android_log_print(ANDROID_LOG_WARN, kTag, "%s", message.c_str());
}

std::string EscapeJSON(const std::string& input) {
    std::ostringstream output;
    for (unsigned char character : input) {
        switch (character) {
            case '\"': output << "\\\""; break;
            case '\\': output << "\\\\"; break;
            case '\b': output << "\\b"; break;
            case '\f': output << "\\f"; break;
            case '\n': output << "\\n"; break;
            case '\r': output << "\\r"; break;
            case '\t': output << "\\t"; break;
            default:
                if (character < 0x20) {
                    char buffer[7];
                    std::snprintf(buffer, sizeof(buffer), "\\u%04x", character);
                    output << buffer;
                } else {
                    output << character;
                }
        }
    }
    return output.str();
}

std::string JavaString(JNIEnv* env, jstring value) {
    if (value == nullptr) return {};
    const char* characters = env->GetStringUTFChars(value, nullptr);
    if (characters == nullptr) {
        env->ExceptionClear();
        return {};
    }
    std::string result(characters);
    env->ReleaseStringUTFChars(value, characters);
    return result;
}

void Deallocate(void* memory) {
    if (memory != nullptr) g_jvmti->Deallocate(reinterpret_cast<unsigned char*>(memory));
}

std::string NormalizeClassName(const char* signature) {
    if (signature == nullptr) return {};
    std::string result(signature);
    if (!result.empty() && result.front() == 'L') result.erase(result.begin());
    if (!result.empty() && result.back() == ';') result.pop_back();
    std::replace(result.begin(), result.end(), '/', '.');
    return result;
}

bool IsFramework(const std::string& class_name) {
    static constexpr const char* prefixes[] = {
        "android.", "androidx.", "java.", "javax.", "kotlin.", "kotlinx.",
        "okhttp3.", "okio.", "retrofit2.", "dalvik.", "sun.", "com.android."
    };
    for (const char* prefix : prefixes) {
        if (class_name.rfind(prefix, 0) == 0) return true;
    }
    return false;
}

int LineNumber(jmethodID method, jlocation location) {
    jint count = 0;
    jvmtiLineNumberEntry* entries = nullptr;
    if (g_jvmti->GetLineNumberTable(method, &count, &entries) != JVMTI_ERROR_NONE || entries == nullptr) return -1;
    int line = -1;
    for (jint index = 0; index < count; ++index) {
        if (entries[index].start_location > location) break;
        line = entries[index].line_number;
    }
    Deallocate(entries);
    return line;
}

std::string FrameJSON(const jvmtiFrameInfo& frame) {
    char* method_name = nullptr;
    char* method_signature = nullptr;
    char* class_signature = nullptr;
    char* source_file = nullptr;
    jclass declaring_class = nullptr;
    g_jvmti->GetMethodName(frame.method, &method_name, &method_signature, nullptr);
    g_jvmti->GetMethodDeclaringClass(frame.method, &declaring_class);
    if (declaring_class != nullptr) {
        g_jvmti->GetClassSignature(declaring_class, &class_signature, nullptr);
        if (g_jvmti->GetSourceFileName(declaring_class, &source_file) != JVMTI_ERROR_NONE) source_file = nullptr;
    }
    const std::string class_name = NormalizeClassName(class_signature);
    const int line = LineNumber(frame.method, frame.location);
    std::ostringstream json;
    json << "{\"className\":\"" << EscapeJSON(class_name)
         << "\",\"methodName\":\"" << EscapeJSON(method_name == nullptr ? "" : method_name)
         << "\",\"signature\":\"" << EscapeJSON(method_signature == nullptr ? "" : method_signature) << "\"";
    if (source_file != nullptr) json << ",\"sourceFile\":\"" << EscapeJSON(source_file) << "\"";
    else json << ",\"sourceFile\":null";
    if (line >= 0) json << ",\"lineNumber\":" << line;
    else json << ",\"lineNumber\":null";
    json << ",\"isFramework\":" << (IsFramework(class_name) ? "true" : "false") << "}";
    Deallocate(method_name);
    Deallocate(method_signature);
    Deallocate(class_signature);
    Deallocate(source_file);
    return json.str();
}

std::string ProcessName() {
    std::ifstream stream("/proc/self/cmdline", std::ios::binary);
    std::string result;
    std::getline(stream, result, '\0');
    return result;
}

std::string CorrelationHeadersJSON(JNIEnv* env, jobject request, jclass request_class) {
    jfieldID headers_field = env->GetFieldID(request_class, "headers", "Lokhttp3/Headers;");
    if (headers_field == nullptr) {
        env->ExceptionClear();
        return "{}";
    }
    jobject headers = env->GetObjectField(request, headers_field);
    if (headers == nullptr) return "{}";
    jclass headers_class = env->GetObjectClass(headers);
    jfieldID values_field = env->GetFieldID(headers_class, "namesAndValues", "[Ljava/lang/String;");
    if (values_field == nullptr) {
        env->ExceptionClear();
        env->DeleteLocalRef(headers_class);
        env->DeleteLocalRef(headers);
        return "{}";
    }
    auto values = static_cast<jobjectArray>(env->GetObjectField(headers, values_field));
    std::ostringstream json;
    json << "{";
    bool first = true;
    if (values != nullptr) {
        const jsize count = env->GetArrayLength(values);
        for (jsize index = 0; index + 1 < count; index += 2) {
            auto name_value = static_cast<jstring>(env->GetObjectArrayElement(values, index));
            auto header_value = static_cast<jstring>(env->GetObjectArrayElement(values, index + 1));
            std::string name = JavaString(env, name_value);
            std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return std::tolower(c); });
            if (name == "traceparent" || name == "x-request-id" || name == "x-correlation-id") {
                if (!first) json << ",";
                first = false;
                json << "\"" << EscapeJSON(name) << "\":\"" << EscapeJSON(JavaString(env, header_value)) << "\"";
            }
            env->DeleteLocalRef(name_value);
            env->DeleteLocalRef(header_value);
        }
        env->DeleteLocalRef(values);
    }
    json << "}";
    env->DeleteLocalRef(headers_class);
    env->DeleteLocalRef(headers);
    return json.str();
}

void Enqueue(std::string event) {
    {
        std::lock_guard lock(g_queue_mutex);
        if (g_events.size() >= kMaximumEvents) g_events.pop_front();
        g_events.push_back(std::move(event));
    }
    g_queue_condition.notify_one();
}

std::string Envelope(const std::string& type, const std::string& payload) {
    return "{\"protocolVersion\":1,\"type\":\"" + EscapeJSON(type) + "\",\"payload\":" + payload + ",\"error\":null}";
}

bool WriteAll(int descriptor, const void* bytes, size_t count) {
    const auto* cursor = static_cast<const uint8_t*>(bytes);
    while (count > 0) {
        const ssize_t written = send(descriptor, cursor, count, MSG_NOSIGNAL);
        if (written <= 0) return false;
        cursor += written;
        count -= static_cast<size_t>(written);
    }
    return true;
}

bool WriteFrame(int descriptor, const std::string& json) {
    const uint32_t length = htonl(static_cast<uint32_t>(json.size()));
    return WriteAll(descriptor, &length, sizeof(length)) && WriteAll(descriptor, json.data(), json.size());
}

bool ReadAll(int descriptor, void* bytes, size_t count) {
    auto* cursor = static_cast<uint8_t*>(bytes);
    while (count > 0) {
        const ssize_t read_count = recv(descriptor, cursor, count, 0);
        if (read_count <= 0) return false;
        cursor += read_count;
        count -= static_cast<size_t>(read_count);
    }
    return true;
}

bool ReadFrame(int descriptor, std::string* json) {
    uint32_t network_length = 0;
    if (!ReadAll(descriptor, &network_length, sizeof(network_length))) return false;
    const uint32_t length = ntohl(network_length);
    if (length > 4 * 1024 * 1024) return false;
    json->resize(length);
    return ReadAll(descriptor, json->data(), length);
}

bool Authenticated(const std::string& frame) {
    return frame.find("\"type\":\"authenticate\"") != std::string::npos &&
           frame.find("\"token\":\"" + g_token + "\"") != std::string::npos;
}

void DisableBreakpoints() {
    std::lock_guard lock(g_breakpoint_mutex);
    if (g_jvmti == nullptr) return;
    for (const auto& [method, location] : g_breakpoints) g_jvmti->ClearBreakpoint(method, location);
    g_breakpoints.clear();
    g_instrumented_methods.clear();
    g_jvmti->SetEventNotificationMode(JVMTI_DISABLE, JVMTI_EVENT_BREAKPOINT, nullptr);
    g_jvmti->SetEventNotificationMode(JVMTI_DISABLE, JVMTI_EVENT_CLASS_PREPARE, nullptr);
}

void ServeClient(int descriptor) {
    std::string frame;
    if (!ReadFrame(descriptor, &frame) || !Authenticated(frame)) {
        WriteFrame(descriptor, Envelope("error", "{\"message\":\"Authentication failed\"}"));
        return;
    }
    WriteFrame(descriptor, Envelope("authenticated", "{\"engine\":\"JVMTI\",\"protocolVersion\":1}"));
    while (g_running.load()) {
        pollfd event{descriptor, POLLIN, 0};
        const int poll_result = poll(&event, 1, 50);
        if (poll_result > 0 && (event.revents & POLLIN) != 0) {
            if (!ReadFrame(descriptor, &frame)) return;
            if (frame.find("\"type\":\"shutdown\"") != std::string::npos) {
                DisableBreakpoints();
                g_running.store(false);
                WriteFrame(descriptor, Envelope("stopped", "{}"));
                return;
            }
        }
        std::string event_json;
        {
            std::lock_guard lock(g_queue_mutex);
            if (!g_events.empty()) {
                event_json = std::move(g_events.front());
                g_events.pop_front();
            }
        }
        if (!event_json.empty() && !WriteFrame(descriptor, event_json)) return;
    }
}

void ServerLoop() {
    g_server_fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (g_server_fd < 0) return;
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    const size_t name_length = std::min(g_socket_name.size(), sizeof(address.sun_path) - 2);
    address.sun_path[0] = '\0';
    std::memcpy(address.sun_path + 1, g_socket_name.data(), name_length);
    const socklen_t address_length = static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) + 1 + name_length);
    if (bind(g_server_fd, reinterpret_cast<sockaddr*>(&address), address_length) != 0 || listen(g_server_fd, 1) != 0) {
        close(g_server_fd);
        g_server_fd = -1;
        return;
    }
    while (g_running.load()) {
        g_client_fd = accept4(g_server_fd, nullptr, nullptr, SOCK_CLOEXEC);
        if (g_client_fd < 0) continue;
        ServeClient(g_client_fd);
        close(g_client_fd);
        g_client_fd = -1;
        if (g_running.exchange(false)) DisableBreakpoints();
    }
    close(g_server_fd);
    g_server_fd = -1;
}

void InstallBreakpoints(jclass klass) {
    char* signature = nullptr;
    if (g_jvmti->GetClassSignature(klass, &signature, nullptr) != JVMTI_ERROR_NONE) return;
    const bool is_client = signature != nullptr && std::strcmp(signature, "Lokhttp3/OkHttpClient;") == 0;
    const bool is_real_call = signature != nullptr &&
        (std::strcmp(signature, "Lokhttp3/internal/connection/RealCall;") == 0 ||
         std::strcmp(signature, "Lokhttp3/RealCall;") == 0);
    Deallocate(signature);
    if (!is_client && !is_real_call) return;
    g_saw_okhttp.store(true);
    jint method_count = 0;
    jmethodID* methods = nullptr;
    if (g_jvmti->GetClassMethods(klass, &method_count, &methods) != JVMTI_ERROR_NONE) return;
    std::lock_guard lock(g_breakpoint_mutex);
    for (jint index = 0; index < method_count; ++index) {
        char* name = nullptr;
        char* descriptor = nullptr;
        g_jvmti->GetMethodName(methods[index], &name, &descriptor, nullptr);
        const bool target = name != nullptr && descriptor != nullptr &&
            ((is_client &&
              ((std::strcmp(name, "newCall") == 0 && std::strcmp(descriptor, "(Lokhttp3/Request;)Lokhttp3/Call;") == 0) ||
               (std::strcmp(name, "newWebSocket") == 0 && std::strncmp(descriptor, "(Lokhttp3/Request;", 18) == 0))) ||
             (is_real_call &&
              ((std::strcmp(name, "execute") == 0 && std::strcmp(descriptor, "()Lokhttp3/Response;") == 0) ||
               (std::strcmp(name, "enqueue") == 0 && std::strcmp(descriptor, "(Lokhttp3/Callback;)V") == 0))));
        if (target && !g_instrumented_methods.contains(methods[index])) {
            jlocation start = 0;
            jlocation end = 0;
            if (g_jvmti->GetMethodLocation(methods[index], &start, &end) == JVMTI_ERROR_NONE &&
                g_jvmti->SetBreakpoint(methods[index], start) == JVMTI_ERROR_NONE) {
                g_instrumented_methods.insert(methods[index]);
                g_breakpoints.emplace_back(methods[index], start);
            }
        }
        Deallocate(name);
        Deallocate(descriptor);
    }
    Deallocate(methods);
    if (!g_breakpoints.empty()) {
        Log("Installed OkHttp request breakpoints");
        Enqueue(Envelope("ready", "{\"okHttp\":true}"));
    }
}

void ScanLoadedClasses() {
    JNIEnv* env = nullptr;
    const bool attached_here = g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK;
    if (attached_here && g_vm->AttachCurrentThread(&env, nullptr) != JNI_OK) {
        Log("Could not attach the loaded-class scan worker to the VM");
        return;
    }
    jint class_count = 0;
    jclass* classes = nullptr;
    const jvmtiError classes_error = g_jvmti->GetLoadedClasses(&class_count, &classes);
    if (classes_error == JVMTI_ERROR_NONE) {
        for (jint index = 0; index < class_count && g_running.load(); ++index) {
            InstallBreakpoints(classes[index]);
        }
        Deallocate(classes);
    } else {
        Log("GetLoadedClasses failed: " + std::to_string(classes_error));
    }
    if (g_saw_okhttp.load() && g_breakpoints.empty()) {
        Enqueue(Envelope("unsupported", "{\"message\":\"Unsupported OkHttpClient method layout\"}"));
    }
    if (attached_here) g_vm->DetachCurrentThread();
}

void JNICALL OnClassPrepare(jvmtiEnv*, JNIEnv*, jthread, jclass klass) {
    InstallBreakpoints(klass);
}

void DeleteLocalIfPresent(JNIEnv* env, jobject value) {
    if (value != nullptr) env->DeleteLocalRef(value);
}

jobject RequestForBreakpoint(JNIEnv* env, jthread thread, jmethodID method, bool* used_real_call_fallback) {
    *used_real_call_fallback = false;
    jclass declaring_class = nullptr;
    char* signature = nullptr;
    if (g_jvmti->GetMethodDeclaringClass(method, &declaring_class) != JVMTI_ERROR_NONE || declaring_class == nullptr) return nullptr;
    g_jvmti->GetClassSignature(declaring_class, &signature, nullptr);
    const bool is_client = signature != nullptr && std::strcmp(signature, "Lokhttp3/OkHttpClient;") == 0;
    const bool is_real_call = signature != nullptr &&
        (std::strcmp(signature, "Lokhttp3/internal/connection/RealCall;") == 0 ||
         std::strcmp(signature, "Lokhttp3/RealCall;") == 0);
    Deallocate(signature);
    if (is_client) {
        jobject request = nullptr;
        g_jvmti->GetLocalObject(thread, 0, 1, &request);
        return request;
    }
    if (!is_real_call) return nullptr;
    *used_real_call_fallback = true;
    jobject real_call = nullptr;
    jvmtiError instance_error = g_jvmti->GetLocalInstance(thread, 0, &real_call);
    if (instance_error != JVMTI_ERROR_NONE || real_call == nullptr) {
        instance_error = g_jvmti->GetLocalObject(thread, 0, 0, &real_call);
    }
    if (instance_error != JVMTI_ERROR_NONE || real_call == nullptr) return nullptr;
    jclass real_call_class = env->GetObjectClass(real_call);
    jfieldID request_field = env->GetFieldID(real_call_class, "originalRequest", "Lokhttp3/Request;");
    if (request_field == nullptr) env->ExceptionClear();
    jobject request = request_field == nullptr ? nullptr : env->GetObjectField(real_call, request_field);
    DeleteLocalIfPresent(env, real_call_class);
    DeleteLocalIfPresent(env, real_call);
    return request;
}

int RequestIdentity(JNIEnv* env, jobject request) {
    jclass system_class = env->FindClass("java/lang/System");
    if (system_class == nullptr) {
        env->ExceptionClear();
        return 0;
    }
    jmethodID identity_method = env->GetStaticMethodID(system_class, "identityHashCode", "(Ljava/lang/Object;)I");
    if (identity_method == nullptr) {
        env->ExceptionClear();
        env->DeleteLocalRef(system_class);
        return 0;
    }
    const jint identity = env->CallStaticIntMethod(system_class, identity_method, request);
    if (env->ExceptionCheck()) env->ExceptionClear();
    env->DeleteLocalRef(system_class);
    return identity;
}

void JNICALL OnBreakpoint(jvmtiEnv*, JNIEnv* env, jthread thread, jmethodID method, jlocation) {
    const uint64_t callback_number = ++g_breakpoint_callbacks;
    if (callback_number == 1) Log("Received first OkHttp breakpoint callback");
    bool used_real_call_fallback = false;
    jobject request = RequestForBreakpoint(env, thread, method, &used_real_call_fallback);
    if (request == nullptr) {
        if (used_real_call_fallback) {
            Enqueue(Envelope("unsupported", "{\"message\":\"Android runtime did not expose the OkHttp Request argument\"}"));
        }
        return;
    }
    const int request_identity = RequestIdentity(env, request);
    if (request_identity != 0) {
        std::lock_guard request_lock(g_request_mutex);
        if (g_recent_request_identities.contains(request_identity)) {
            env->DeleteLocalRef(request);
            return;
        }
        g_recent_request_identities.insert(request_identity);
        g_recent_request_order.push_back(request_identity);
        if (g_recent_request_order.size() > kMaximumEvents) {
            g_recent_request_identities.erase(g_recent_request_order.front());
            g_recent_request_order.pop_front();
        }
    }
    jclass request_class = env->GetObjectClass(request);
    jfieldID method_field = env->GetFieldID(request_class, "method", "Ljava/lang/String;");
    jfieldID url_field = env->GetFieldID(request_class, "url", "Lokhttp3/HttpUrl;");
    if (method_field == nullptr || url_field == nullptr) {
        env->ExceptionClear();
        Enqueue(Envelope("unsupported", "{\"message\":\"Unsupported OkHttp Request layout\"}"));
        env->DeleteLocalRef(request_class);
        env->DeleteLocalRef(request);
        return;
    }
    auto method_value = static_cast<jstring>(env->GetObjectField(request, method_field));
    jobject url_object = env->GetObjectField(request, url_field);
    jclass url_class = url_object == nullptr ? nullptr : env->GetObjectClass(url_object);
    jfieldID canonical_field = url_class == nullptr ? nullptr : env->GetFieldID(url_class, "url", "Ljava/lang/String;");
    if (canonical_field == nullptr) env->ExceptionClear();
    auto url_value = canonical_field == nullptr ? nullptr : static_cast<jstring>(env->GetObjectField(url_object, canonical_field));

    jvmtiThreadInfo thread_info{};
    g_jvmti->GetThreadInfo(thread, &thread_info);
    jvmtiFrameInfo frames[kMaximumFrames];
    jint frame_count = 0;
    g_jvmti->GetStackTrace(thread, 0, kMaximumFrames, frames, &frame_count);
    const auto now = std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();
    std::ostringstream payload;
    payload << "{\"sequence\":" << ++g_sequence
            << ",\"requestIdentity\":" << request_identity
            << ",\"method\":\"" << EscapeJSON(JavaString(env, method_value))
            << "\",\"url\":\"" << EscapeJSON(JavaString(env, url_value))
            << "\",\"processName\":\"" << EscapeJSON(ProcessName())
            << "\",\"pid\":" << getpid()
            << ",\"threadName\":\"" << EscapeJSON(thread_info.name == nullptr ? "" : thread_info.name)
            << "\",\"capturedAt\":" << now
            << ",\"correlationHeaders\":" << CorrelationHeadersJSON(env, request, request_class)
            << ",\"stackFrames\":[";
    for (jint index = 0; index < frame_count; ++index) {
        if (index > 0) payload << ",";
        payload << FrameJSON(frames[index]);
    }
    payload << "]}";
    Enqueue(Envelope("trace", payload.str()));
    if (g_sequence.load() == 1) Log("Captured first OkHttp request stack");

    Deallocate(thread_info.name);
    if (url_value != nullptr) env->DeleteLocalRef(url_value);
    if (url_class != nullptr) env->DeleteLocalRef(url_class);
    if (url_object != nullptr) env->DeleteLocalRef(url_object);
    if (method_value != nullptr) env->DeleteLocalRef(method_value);
    env->DeleteLocalRef(request_class);
    env->DeleteLocalRef(request);
}

std::string Option(const std::string& options, const std::string& key) {
    const std::string prefix = key + "=";
    const size_t start = options.find(prefix);
    if (start == std::string::npos) return {};
    const size_t value_start = start + prefix.size();
    const size_t end = options.find(',', value_start);
    return options.substr(value_start, end == std::string::npos ? std::string::npos : end - value_start);
}

}  // namespace

extern "C" __attribute__((visibility("default"))) jint Agent_OnAttach(JavaVM* vm, char* options, void*) {
    std::lock_guard attach_lock(g_attach_mutex);
    Log("Agent_OnAttach invoked");
    if (g_running.load()) {
        Log("Rejected duplicate Lens Android inspector attachment");
        return JNI_ERR;
    }
    g_vm = vm;
    const jint get_env_result = vm->GetEnv(reinterpret_cast<void**>(&g_jvmti), JVMTI_VERSION_1_2);
    if (get_env_result != JNI_OK || g_jvmti == nullptr) {
        Log("JVMTI GetEnv failed: " + std::to_string(get_env_result));
        return JNI_ERR;
    }
    const std::string parsed_options = options == nullptr ? "" : options;
    g_socket_name = Option(parsed_options, "socket");
    g_token = Option(parsed_options, "token");
    if (g_socket_name.empty() || g_token.empty()) return JNI_ERR;
    g_saw_okhttp.store(false);
    g_sequence.store(0);
    g_breakpoint_callbacks.store(0);
    {
        std::lock_guard queue_lock(g_queue_mutex);
        g_events.clear();
    }
    {
        std::lock_guard request_lock(g_request_mutex);
        g_recent_request_identities.clear();
        g_recent_request_order.clear();
    }

    jvmtiCapabilities potential{};
    const jvmtiError potential_error = g_jvmti->GetPotentialCapabilities(&potential);
    if (potential_error != JVMTI_ERROR_NONE) {
        Log("GetPotentialCapabilities failed: " + std::to_string(potential_error));
        return JNI_ERR;
    }
    if (!potential.can_generate_breakpoint_events || !potential.can_access_local_variables) {
        Log("Required live breakpoint or local-variable capability is unavailable");
        return JNI_ERR;
    }
    jvmtiCapabilities capabilities{};
    capabilities.can_generate_breakpoint_events = potential.can_generate_breakpoint_events;
    capabilities.can_access_local_variables = potential.can_access_local_variables;
    capabilities.can_get_line_numbers = potential.can_get_line_numbers;
    capabilities.can_get_source_file_name = potential.can_get_source_file_name;
    const jvmtiError capabilities_error = g_jvmti->AddCapabilities(&capabilities);
    if (capabilities_error != JVMTI_ERROR_NONE) {
        Log("AddCapabilities failed: " + std::to_string(capabilities_error));
        return JNI_ERR;
    }
    jvmtiEventCallbacks callbacks{};
    callbacks.ClassPrepare = OnClassPrepare;
    callbacks.Breakpoint = OnBreakpoint;
    const jvmtiError callback_error = g_jvmti->SetEventCallbacks(&callbacks, sizeof(callbacks));
    if (callback_error != JVMTI_ERROR_NONE) {
        Log("SetEventCallbacks failed: " + std::to_string(callback_error));
        return JNI_ERR;
    }
    const jvmtiError class_prepare_error =
        g_jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_CLASS_PREPARE, nullptr);
    const jvmtiError breakpoint_error =
        g_jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_BREAKPOINT, nullptr);
    if (class_prepare_error != JVMTI_ERROR_NONE || breakpoint_error != JVMTI_ERROR_NONE) {
        Log(
            "Enabling JVMTI events failed: " + std::to_string(class_prepare_error) + "," +
            std::to_string(breakpoint_error)
        );
        return JNI_ERR;
    }

    g_running.store(true);
    if (g_server_thread.joinable()) g_server_thread.detach();
    g_server_thread = std::thread(ServerLoop);
    g_server_thread.detach();
    std::thread(ScanLoadedClasses).detach();
    Log("Lens Android inspector attached");
    return JNI_OK;
}
