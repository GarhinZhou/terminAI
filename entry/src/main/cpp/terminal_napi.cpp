// terminAI - PTY session manager (NAPI native module)
//
// Spawns interactive /bin/sh on a real PTY inside the app sandbox.
// PTY creation follows the pattern proven by the PtyDiagnostic demo:
//   posix_openpt -> grantpt -> unlockpt -> ptsname_r
//   fork -> child: setsid + open slave + dup2 x3 + execve
// Output is streamed to ArkTS through a per-session threadsafe function.

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <map>
#include <mutex>
#include <poll.h>
#include <pthread.h>
#include <cctype>
#include <sstream>
#include <string>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <vector>

#include <hilog/log.h>
#include <napi/native_api.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "TERMINAI"
#define LOGI(...) OH_LOG_INFO(LOG_APP, LOG_TAG ": " __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, LOG_TAG ": " __VA_ARGS__)

namespace {

constexpr int kReadChunk = 64 * 1024;
constexpr const char* kFallbackHome = "/storage/Users/currentUser";

std::string UserHomeDirectory() {
    const char* home = std::getenv("HOME");
    if (home != nullptr && home[0] == '/') {
        return std::string(home);
    }
    return std::string(kFallbackHome);
}

std::string ExpandHomePath(const std::string& path, const std::string& home) {
    if (path.empty() || path == "~") {
        return home;
    }
    if (path.rfind("~/", 0) == 0) {
        return home + path.substr(1);
    }
    return path;
}

// Event kinds pushed to ArkTS.
constexpr const char* kKindOutput = "output";
constexpr const char* kKindExit = "exit";
constexpr const char* kKindCwd = "cwd";

void SecureErase(std::string& value) {
    if (!value.empty()) {
        volatile char* bytes = &value[0];
        for (size_t index = 0; index < value.size(); ++index) {
            bytes[index] = 0;
        }
    }
    value.clear();
}

struct SessionEvent {
    int id;
    std::string kind;     // kKindOutput | kKindExit
    std::string data;     // output bytes (kind == output)
    int exitCode = -1;    // exit status (kind == exit)
};

struct PtySession {
    int id = -1;
    int masterFd = -1;
    pid_t childPid = -1;
    bool alive = false;
    napi_threadsafe_function tsfn = nullptr;
    napi_ref jsCallbackRef = nullptr;
    napi_env env = nullptr;
    pthread_t readerThread{};
    pthread_t waiterThread{};
    std::string cwd;   // last known working directory
    std::string startCwd;
    // Used only by the hidden SSH master session. It is never placed in a
    // command line or environment variable and is erased after first use.
    std::string authSecret;
    std::string authTail;
    bool authSecretSent = false;

    ~PtySession() {
        SecureErase(authSecret);
    }
};

std::mutex g_mutex;
std::map<int, PtySession*> g_sessions;
int g_nextSessionId = 1;

// ── TSFN → JS bridge ────────────────────────────────────────────────

void CallJs(napi_env env, napi_value jsCb, void* /*context*/, void* data) {
    SessionEvent* ev = static_cast<SessionEvent*>(data);
    if (env == nullptr || jsCb == nullptr) {
        delete ev;
        return;
    }
    napi_value global;
    napi_get_global(env, &global);

    napi_value obj;
    napi_create_object(env, &obj);

    napi_value v;
    napi_create_int32(env, ev->id, &v);
    napi_set_named_property(env, obj, "id", v);
    napi_create_string_utf8(env, ev->kind.c_str(), NAPI_AUTO_LENGTH, &v);
    napi_set_named_property(env, obj, "kind", v);
    // data may contain arbitrary bytes from the PTY; use latin1-safe path:
    // create string from UTF-8, invalid sequences become U+FFFD (acceptable for v1)
    napi_create_string_utf8(env, ev->data.c_str(), ev->data.size(), &v);
    napi_set_named_property(env, obj, "data", v);
    napi_create_int32(env, ev->exitCode, &v);
    napi_set_named_property(env, obj, "exitCode", v);

    napi_value argv[] = { obj };
    napi_call_function(env, global, jsCb, 1, argv, nullptr);
    delete ev;
}

void PushEvent(PtySession* s, const std::string& kind, const std::string& data, int exitCode) {
    if (s->tsfn == nullptr) return;
    LOGI("push event session=%{public}d kind=%{public}s bytes=%{public}zu", s->id, kind.c_str(), data.size());
    SessionEvent* ev = new SessionEvent{ s->id, kind, data, exitCode };
    napi_status st = napi_call_threadsafe_function(s->tsfn, ev, napi_tsfn_blocking);
    if (st != napi_ok) {
        delete ev;
    }
}

std::string LowerAscii(const std::string& value) {
    std::string lower = value;
    for (char& character : lower) {
        character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    }
    return lower;
}

void HandleStoredSshPassword(PtySession* s, const std::string& output) {
    if (s->authSecret.empty()) return;
    s->authTail += output;
    if (s->authTail.size() > 1024) {
        s->authTail.erase(0, s->authTail.size() - 1024);
    }
    if (s->authTail.find("__TERMINAI_SSH_CONNECTED__") != std::string::npos) {
        SecureErase(s->authSecret);
        s->authTail.clear();
        return;
    }
    const std::string lower = LowerAscii(s->authTail);
    if (s->authSecretSent || lower.find("password:") == std::string::npos) return;

    std::string input = s->authSecret + "\n";
    const char* cursor = input.data();
    size_t left = input.size();
    bool written = true;
    while (left > 0) {
        ssize_t count = write(s->masterFd, cursor, left);
        if (count < 0) {
            if (errno == EINTR) continue;
            written = false;
            break;
        }
        cursor += count;
        left -= static_cast<size_t>(count);
    }
    s->authSecretSent = true;
    SecureErase(s->authSecret);
    SecureErase(input);
    s->authTail.clear();
    LOGI("session %{public}d handled stored SSH password written=%{public}d", s->id, written ? 1 : 0);
}

// ── Reader / waiter threads ─────────────────────────────────────────

void* ReaderMain(void* arg) {
    PtySession* s = static_cast<PtySession*>(arg);
    char buf[kReadChunk];
    for (;;) {
        struct pollfd pfd { s->masterFd, POLLIN, 0 };
        int pr = poll(&pfd, 1, 500);
        if (pr < 0) {
            if (errno == EINTR) continue;
            LOGE("session %d poll error errno=%d", s->id, errno);
            break;
        }
        if (pr == 0) {
            // timeout: check whether fd got closed by killSession
            std::lock_guard<std::mutex> lk(g_mutex);
            if (!s->alive) return nullptr;
            continue;
        }
        if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
            // drain whatever remains, then stop
            ssize_t n = read(s->masterFd, buf, sizeof(buf));
            if (n > 0) {
                const std::string output(buf, n);
                HandleStoredSshPassword(s, output);
                PushEvent(s, kKindOutput, output, -1);
            }
            break;
        }
        if (pfd.revents & POLLIN) {
            ssize_t n = read(s->masterFd, buf, sizeof(buf));
            if (n > 0) {
                const std::string output(buf, n);
                HandleStoredSshPassword(s, output);
                PushEvent(s, kKindOutput, output, -1);
                // Track cwd changes (shell cd) by reading the child's /proc link.
                char linkBuf[1024] = {};
                char procPath[64];
                snprintf(procPath, sizeof(procPath), "/proc/%d/cwd", s->childPid);
                ssize_t len = readlink(procPath, linkBuf, sizeof(linkBuf) - 1);
                if (len > 0) {
                    linkBuf[len] = '\0';
                    std::lock_guard<std::mutex> lk(g_mutex);
                    // log first successful read to prove /proc works in sandbox
                    static bool loggedOnce = false;
                    if (!loggedOnce) {
                        loggedOnce = true;
                        LOGI("cwd read OK: %{public}s", linkBuf);
                    }
                    if (s->cwd != linkBuf) {
                        s->cwd = linkBuf;
                        PushEvent(s, kKindCwd, linkBuf, -1);
                    }
                } else {
                    // log once per poll cycle is too noisy; log only first failure
                    static bool warned = false;
                    if (!warned) {
                        warned = true;
                        LOGI("cwd readlink failed errno=%{public}d", errno);
                    }
                }
            } else if (n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN)) {
                break;
            }
        }
    }
    SecureErase(s->authSecret);
    return nullptr;
}

void* WaiterMain(void* arg) {
    PtySession* s = static_cast<PtySession*>(arg);
    int status = 0;
    pid_t w = waitpid(s->childPid, &status, 0);
    int code = -1;
    if (w == s->childPid) {
        if (WIFEXITED(status)) code = WEXITSTATUS(status);
        else if (WIFSIGNALED(status)) code = 128 + WTERMSIG(status);
    }
    LOGI("session %{public}d child %{public}d exited code=%{public}d", s->id, s->childPid, code);
    PushEvent(s, kKindExit, "", code);
    return nullptr;
}

// ── Session lifecycle ───────────────────────────────────────────────

void DestroySessionLocked(PtySession* s) {
    // caller holds g_mutex; session already removed from g_sessions.
    // Order matters: waiter exits once the child is reaped (SIGHUP makes the
    // shell die quickly); reader exits on closed fd or the alive flag.
    s->alive = false;
    if (s->childPid > 0) {
        kill(-s->childPid, SIGHUP);  // process group
        kill(s->childPid, SIGHUP);
    }
    // Release the mutex while joining so PushEvent/reader can lock it.
    g_mutex.unlock();
    pthread_join(s->waiterThread, nullptr);
    if (s->masterFd >= 0) {
        close(s->masterFd);
        s->masterFd = -1;
    }
    pthread_join(s->readerThread, nullptr);
    g_mutex.lock();

    if (s->tsfn != nullptr) {
        napi_release_threadsafe_function(s->tsfn, napi_tsfn_abort);
        s->tsfn = nullptr;
    }
    if (s->jsCallbackRef != nullptr && s->env != nullptr) {
        napi_delete_reference(s->env, s->jsCallbackRef);
        s->jsCallbackRef = nullptr;
    }
    delete s;
}

bool ReadUtf8String(napi_env env, napi_value value, size_t maximumLength, std::string& output) {
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok ||
        length > maximumLength) {
        return false;
    }
    if (length == 0) {
        output.clear();
        return true;
    }
    std::vector<char> buffer(length + 1, 0);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &copied) != napi_ok) {
        return false;
    }
    output.assign(buffer.data(), copied);
    return true;
}

// ── NAPI: createSession(cols, rows, cwd, command, [secret], callback) → id ──

napi_value CreateSession(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t cols = 80, rows = 24;
    napi_get_value_int32(env, args[0], &cols);
    napi_get_value_int32(env, args[1], &rows);

    // args[2] is either the cwd string, or (if only 3 args) the callback;
    // args[3] is either the command string or (if 4 args) the callback.
    std::string startCwd;
    std::string startCmd;
    std::string startSecret;
    napi_value jsCallback = args[2];
    if (argc >= 6) {
        ReadUtf8String(env, args[2], 4096, startCwd);
        ReadUtf8String(env, args[3], 4096, startCmd);
        ReadUtf8String(env, args[4], 4096, startSecret);
        jsCallback = args[5];
    } else if (argc >= 5) {
        ReadUtf8String(env, args[2], 4096, startCwd);
        ReadUtf8String(env, args[3], 4096, startCmd);
        jsCallback = args[4];
    } else if (argc >= 4) {
        ReadUtf8String(env, args[2], 4096, startCwd);
        jsCallback = args[3];
    }
    const std::string homeDir = UserHomeDirectory();
    startCwd = ExpandHomePath(startCwd, homeDir);

    PtySession* s = new PtySession();
    s->env = env;
    s->authSecret.swap(startSecret);
    {
        std::lock_guard<std::mutex> lk(g_mutex);
        s->id = g_nextSessionId++;
    }

    // TSFN wrapping the JS callback
    napi_create_reference(env, jsCallback, 1, &s->jsCallbackRef);
    napi_value resName;
    napi_create_string_utf8(env, "terminai_session", NAPI_AUTO_LENGTH, &resName);
    napi_status st = napi_create_threadsafe_function(
        env, jsCallback, nullptr, resName, 0, 1, nullptr, nullptr, nullptr, CallJs, &s->tsfn);
    if (st != napi_ok) {
        LOGE("create tsfn failed st=%d", st);
        napi_delete_reference(env, s->jsCallbackRef);
        delete s;
        napi_throw_error(env, nullptr, "create_threadsafe_function failed");
        return nullptr;
    }

    // ── PTY setup (proven demo pattern) ──
    errno = 0;
    int master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (master < 0) {
        LOGE("session create: posix_openpt failed errno=%{public}d", errno);
        napi_throw_error(env, nullptr, "posix_openpt failed");
        napi_release_threadsafe_function(s->tsfn, napi_tsfn_abort);
        napi_delete_reference(env, s->jsCallbackRef);
        delete s;
        return nullptr;
    }
    grantpt(master);
    unlockpt(master);
    char slavePath[256] = {};
    ptsname_r(master, slavePath, sizeof(slavePath));

    struct winsize ws { (unsigned short)rows, (unsigned short)cols, 0, 0 };
    ioctl(master, TIOCSWINSZ, &ws);

    pid_t child = fork();
    if (child < 0) {
        LOGE("fork failed errno=%d", errno);
        close(master);
        napi_throw_error(env, nullptr, "fork failed");
        napi_release_threadsafe_function(s->tsfn, napi_tsfn_abort);
        napi_delete_reference(env, s->jsCallbackRef);
        delete s;
        return nullptr;
    }
    if (child == 0) {
        // ── child: attach slave as controlling terminal ──
        setsid();
        int slave = open(slavePath, O_RDWR);
        if (slave < 0) _exit(1);
        ioctl(slave, TIOCSCTTY, 0);
        dup2(slave, STDIN_FILENO);
        dup2(slave, STDOUT_FILENO);
        dup2(slave, STDERR_FILENO);
        if (slave > STDERR_FILENO) close(slave);

        setenv("TERM", "xterm-256color", 1);
        setenv("LS_COLORS",
            "rs=0:di=01;34:ln=01;36:mh=00:pi=40;33:so=01;35:do=01;35:"
            "bd=40;33;01:cd=40;33;01:or=40;31;01:mi=00:su=37;41:sg=30;43:"
            "ca=30;41:tw=30;42:ow=34;42:st=37;44:ex=01;32:"
            "*.tar=01;31:*.tgz=01;31:*.arj=01;31:*.taz=01;31:*.lzh=01;31:"
            "*.flac=01;35:*.mp3=01;35:*.mp4=01;35:*.ogg=01;35:*.avi=01;35:"
            "*.mov=01;35:*.png=01;35:*.jpg=01;35:*.jpeg=01;35:*.gif=01;35:"
            "*.svg=01;35:*.webp=01;35:*.zip=01;31:*.gz=01;31:*.bz2=01;31:"
            "*.xz=01;31:*.zst=01;31:*.7z=01;31:*.rar=01;31", 1);
        const std::string commandPath = homeDir + "/.harmonybrew/bin:"
            "/usr/local/bin:/usr/bin:/bin:"
            "/data/app/bin:/data/service/hnp/bin:/vendor/bin";
        setenv("PATH", commandPath.c_str(), 1);
        setenv("HOME", homeDir.c_str(), 1);
        setenv("LANG", "zh_CN.UTF-8", 1);
        setenv("SHELL", "/usr/bin/zsh", 1);

        // Start in the requested working directory (fall back to home if
        // the sandbox cannot chdir there; root `/` is not writable).
        if (chdir(startCwd.c_str()) != 0) {
            LOGI("session chdir %{public}s failed, using home", startCwd.c_str());
            chdir(homeDir.c_str());
        }

        // If a specific command was requested, run it through sh -c so the
        // PATH lookup and arguments work as on a real shell. Fall back to a
        // login zsh, then toybox sh, if exec fails.
        if (!startCmd.empty()) {
            char* cmdArgv[] = { (char*)"/bin/sh", (char*)"-c", (char*)startCmd.c_str(), nullptr };
            execv("/bin/sh", cmdArgv);
            LOGE("execv cmd failed errno=%{public}d, falling back to zsh", errno);
        }
        // Prefer zsh (same as hishell); fall back to toybox sh if the
        // sandbox refuses to exec system binaries.
        char* zshArgv[] = { (char*)"/usr/bin/zsh", (char*)"-l", nullptr };
        execv("/usr/bin/zsh", zshArgv);
        LOGE("execv zsh failed errno=%{public}d, falling back to /bin/sh", errno);
        char* shArgv[] = { (char*)"/bin/sh", (char*)"-l", nullptr };
        execv("/bin/sh", shArgv);
        _exit(127);
    }

    s->masterFd = master;
    s->childPid = child;
    s->alive = true;
    s->cwd = startCwd;
    s->startCwd = startCwd;
    {
        std::lock_guard<std::mutex> lk(g_mutex);
        g_sessions[s->id] = s;
    }

    pthread_create(&s->readerThread, nullptr, ReaderMain, s);
    pthread_create(&s->waiterThread, nullptr, WaiterMain, s);

    LOGI("session %d created pid=%d slave=%s %dx%d", s->id, child, slavePath, cols, rows);

    napi_value ret;
    napi_create_int32(env, s->id, &ret);
    return ret;
}

// ── NAPI: writeSession(id, data) → bool ─────────────────────────────

napi_value WriteSession(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id;
    napi_get_value_int32(env, args[0], &id);
    std::string data;
    ReadUtf8String(env, args[1], 1024 * 1024, data);
    std::lock_guard<std::mutex> lk(g_mutex);
    auto it = g_sessions.find(id);
    bool ok = false;
    if (it != g_sessions.end() && it->second->alive && it->second->masterFd >= 0) {
        const char* p = data.data();
        size_t left = data.size();
        ok = true;
        LOGI("write session=%{public}d bytes=%{public}zu", id, data.size());
        while (left > 0) {
            ssize_t n = write(it->second->masterFd, p, left);
            if (n < 0) {
                if (errno == EINTR) continue;
                ok = false;
                break;
            }
            p += n;
            left -= n;
        }
    }
    napi_value ret;
    napi_get_boolean(env, ok, &ret);
    return ret;
}

// ── NAPI: resizeSession(id, cols, rows) → bool ─────────────────────

napi_value ResizeSession(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id, cols, rows;
    napi_get_value_int32(env, args[0], &id);
    napi_get_value_int32(env, args[1], &cols);
    napi_get_value_int32(env, args[2], &rows);

    std::lock_guard<std::mutex> lk(g_mutex);
    auto it = g_sessions.find(id);
    bool ok = false;
    if (it != g_sessions.end() && it->second->masterFd >= 0) {
        struct winsize ws { (unsigned short)rows, (unsigned short)cols, 0, 0 };
        ok = (ioctl(it->second->masterFd, TIOCSWINSZ, &ws) == 0);
    }
    napi_value ret;
    napi_get_boolean(env, ok, &ret);
    return ret;
}

// ── NAPI: killSession(id) → bool ────────────────────────────────────

napi_value KillSession(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id;
    napi_get_value_int32(env, args[0], &id);

    PtySession* victim = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mutex);
        auto it = g_sessions.find(id);
        if (it != g_sessions.end()) {
            victim = it->second;
            g_sessions.erase(it);
        }
    }
    if (victim != nullptr) {
        std::lock_guard<std::mutex> lk(g_mutex);
        DestroySessionLocked(victim);
        LOGI("session %d killed", id);
    }
    napi_value ret;
    napi_get_boolean(env, victim != nullptr, &ret);
    return ret;
}

// ── NAPI: listSessions() → [{id, pid, alive}] ──────────────────────

napi_value ListSessions(napi_env env, napi_callback_info /*info*/) {
    napi_value arr;
    napi_create_array(env, &arr);
    std::lock_guard<std::mutex> lk(g_mutex);
    uint32_t i = 0;
    for (auto& kv : g_sessions) {
        napi_value obj;
        napi_create_object(env, &obj);
        napi_value v;
        napi_create_int32(env, kv.second->id, &v);
        napi_set_named_property(env, obj, "id", v);
        napi_create_int32(env, kv.second->childPid, &v);
        napi_set_named_property(env, obj, "pid", v);
        napi_get_boolean(env, kv.second->alive, &v);
        napi_set_named_property(env, obj, "alive", v);
        napi_create_string_utf8(env, kv.second->cwd.c_str(), NAPI_AUTO_LENGTH, &v);
        napi_set_named_property(env, obj, "cwd", v);
        napi_set_element(env, arr, i++, obj);
    }
    return arr;
}

std::string ProcessCommand(pid_t pid) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/cmdline", pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return "";
    char buf[1024] = {};
    ssize_t count = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (count <= 0) return "";
    std::string command(buf);
    size_t slash = command.find_last_of('/');
    return slash == std::string::npos ? command : command.substr(slash + 1);
}

bool IsShellCommand(const std::string& command) {
    return command == "sh" || command == "zsh" || command == "bash" ||
        command == "dash" || command == "fish" || command == "ksh";
}

struct ProcessRuntimeStats {
    pid_t group = -1;
    char state = '?';
    unsigned long long cpuTicks = 0;
};

bool ReadProcessRuntimeStats(pid_t pid, ProcessRuntimeStats& stats) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/stat", pid);
    FILE* file = fopen(path, "r");
    if (file == nullptr) return false;
    char line[2048] = {};
    char* result = fgets(line, sizeof(line), file);
    fclose(file);
    if (result == nullptr) return false;
    char* closeParen = strrchr(line, ')');
    if (closeParen == nullptr) return false;

    int parent = 0;
    int group = 0;
    int session = 0;
    int tty = 0;
    int terminalGroup = 0;
    unsigned long long flags = 0;
    unsigned long long minorFaults = 0;
    unsigned long long childMinorFaults = 0;
    unsigned long long majorFaults = 0;
    unsigned long long childMajorFaults = 0;
    unsigned long long userTicks = 0;
    unsigned long long systemTicks = 0;
    std::istringstream fields(closeParen + 2);
    fields >> stats.state >> parent >> group >> session >> tty >> terminalGroup >> flags >>
        minorFaults >> childMinorFaults >> majorFaults >> childMajorFaults >> userTicks >> systemTicks;
    if (fields.fail()) return false;
    stats.group = static_cast<pid_t>(group);
    stats.cpuTicks = userTicks + systemTicks;
    return true;
}

pid_t ProcessGroupOf(pid_t pid) {
    ProcessRuntimeStats stats;
    return ReadProcessRuntimeStats(pid, stats) ? stats.group : -1;
}

pid_t RepresentativeProcess(pid_t foregroundGroup, pid_t fallback) {
    if (foregroundGroup <= 0) return fallback;
    // In normal job-control sessions the process-group leader is the agent.
    // Avoid scanning all of /proc on every 400 ms sample in that common case.
    const std::string leaderCommand = ProcessCommand(foregroundGroup);
    if (!leaderCommand.empty() && !IsShellCommand(leaderCommand)) {
        return foregroundGroup;
    }
    DIR* proc = opendir("/proc");
    if (proc == nullptr) return fallback;
    pid_t selected = fallback;
    struct dirent* entry;
    while ((entry = readdir(proc)) != nullptr) {
        if (!std::isdigit(static_cast<unsigned char>(entry->d_name[0]))) continue;
        pid_t pid = static_cast<pid_t>(atoi(entry->d_name));
        if (ProcessGroupOf(pid) != foregroundGroup) continue;
        std::string command = ProcessCommand(pid);
        if (!command.empty() && !IsShellCommand(command)) {
            selected = pid;
            break;
        }
        if (selected <= 0) selected = pid;
    }
    closedir(proc);
    return selected;
}

// ── NAPI: inspectSession(id) -> foreground process signal ──────────
napi_value InspectSession(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = -1;
    napi_get_value_int32(env, args[0], &id);

    bool alive = false;
    pid_t shellPid = -1;
    pid_t foregroundPid = -1;
    std::string command;
    std::string processState;
    unsigned long long cpuTicks = 0;
    {
        std::lock_guard<std::mutex> lk(g_mutex);
        auto it = g_sessions.find(id);
        if (it != g_sessions.end()) {
            PtySession* session = it->second;
            alive = session->alive;
            shellPid = session->childPid;
            pid_t group = tcgetpgrp(session->masterFd);
            foregroundPid = RepresentativeProcess(group, shellPid);
            command = ProcessCommand(foregroundPid);
            ProcessRuntimeStats stats;
            if (ReadProcessRuntimeStats(foregroundPid, stats)) {
                processState.assign(1, stats.state);
                cpuTicks = stats.cpuTicks;
            }
        }
    }

    napi_value object;
    napi_create_object(env, &object);
    napi_value value;
    napi_get_boolean(env, alive, &value);
    napi_set_named_property(env, object, "alive", value);
    napi_create_int32(env, shellPid, &value);
    napi_set_named_property(env, object, "shellPid", value);
    napi_create_int32(env, foregroundPid, &value);
    napi_set_named_property(env, object, "foregroundPid", value);
    napi_create_string_utf8(env, command.c_str(), NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, object, "foregroundCommand", value);
    napi_get_boolean(env, IsShellCommand(command), &value);
    napi_set_named_property(env, object, "foregroundIsShell", value);
    napi_create_string_utf8(env, processState.c_str(), NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, object, "foregroundState", value);
    napi_create_int64(env, static_cast<int64_t>(cpuTicks), &value);
    napi_set_named_property(env, object, "cpuTimeTicks", value);
    return object;
}

// ── NAPI: listPrograms() -> [{name, path}] ──────────────────────────
// Probe well-known directories for shells and coding-agent CLIs the way
// herdrm's New Agent picker does (advertised binaries found on PATH).

napi_value ListPrograms(napi_env env, napi_callback_info info) {
    (void)info;
    static const char* kDirs[] = {
        "/usr/bin", "/usr/local/bin",
        "/storage/Users/currentUser/.harmonybrew/bin",
        "/storage/Users/currentUser/.local/bin",
        "/data/app/bin",
    };
    // Display order: shells first, then agents, then extras.
    static const char* kNames[] = {
        "zsh", "sh",
        "claude", "codex", "kimi", "gemini", "grok", "opencode",
        "node", "python3",
    };
    napi_value arr;
    napi_create_array(env, &arr);
    uint32_t i = 0;
    for (const char* name : kNames) {
        for (const char* dir : kDirs) {
            char path[512];
            snprintf(path, sizeof(path), "%s/%s", dir, name);
            if (access(path, X_OK) == 0) {
                napi_value obj;
                napi_create_object(env, &obj);
                napi_value v;
                napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &v);
                napi_set_named_property(env, obj, "name", v);
                napi_create_string_utf8(env, path, NAPI_AUTO_LENGTH, &v);
                napi_set_named_property(env, obj, "path", v);
                napi_set_element(env, arr, i++, obj);
                break;  // first match wins
            }
        }
    }
    return arr;
}

// ── NAPI: listDirs(path) -> [names] ─────────────────────────────────
// Inline directory browser for the New Space sheet (herdrm
// DirectoryPickerField). Returns subdirectory names of the given path.

napi_value ListDirs(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string path;
    if (argc >= 1) {
        size_t len = 0;
        napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
        if (len > 0 && len < 4096) {
            path.resize(len);
            napi_get_value_string_utf8(env, args[0], &path[0], len + 1, &len);
        }
    }
    path = ExpandHomePath(path, UserHomeDirectory());

    napi_value arr;
    napi_create_array(env, &arr);

    DIR* dir = opendir(path.c_str());
    if (dir == nullptr) {
        return arr;
    }
    uint32_t i = 0;
    struct dirent* ent;
    while ((ent = readdir(dir)) != nullptr) {
        if (ent->d_name[0] == '.') continue;
        // Subdirectories only, like the herdrm folder browser.
        std::string full = path;
        if (full.back() != '/') full += '/';
        full += ent->d_name;
        struct stat st;
        if (stat(full.c_str(), &st) != 0) continue;
        if (!S_ISDIR(st.st_mode)) continue;
        napi_value v;
        napi_create_string_utf8(env, ent->d_name, NAPI_AUTO_LENGTH, &v);
        napi_set_element(env, arr, i++, v);
    }
    closedir(dir);
    return arr;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        { "createSession", nullptr, CreateSession, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "createSessionWithSecret", nullptr, CreateSession, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "writeSession", nullptr, WriteSession, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "resizeSession", nullptr, ResizeSession, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "killSession", nullptr, KillSession, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "listSessions", nullptr, ListSessions, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "inspectSession", nullptr, InspectSession, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "listPrograms", nullptr, ListPrograms, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "listDirs", nullptr, ListDirs, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

}  // namespace

static napi_module terminalModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "terminal",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterTerminalModule() {
    napi_module_register(&terminalModule);
}
