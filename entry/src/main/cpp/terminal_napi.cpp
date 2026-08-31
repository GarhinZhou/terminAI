// terminAI - PTY session manager (NAPI native module)
//
// Spawns interactive /bin/sh on a real PTY inside the app sandbox.
// PTY creation follows the pattern proven by the PtyDiagnostic demo:
//   posix_openpt -> grantpt -> unlockpt -> ptsname_r
//   fork -> child: setsid + open slave + dup2 x3 + execve
// Output is streamed to ArkTS through a per-session threadsafe function.

#include <cerrno>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <map>
#include <mutex>
#include <poll.h>
#include <signal.h>
#include <pthread.h>
#include <cctype>
#include <chrono>
#include <deque>
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
constexpr size_t kReadBurstLimit = 512 * 1024;
constexpr size_t kTsfnQueueLimit = 64;
constexpr size_t kPendingWriteLimit = 4 * 1024 * 1024;
constexpr int kCwdPollIntervalMs = 300;
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

struct PendingWrite {
    std::string data;
    size_t offset = 0;
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
    bool readerStarted = false;
    bool waiterStarted = false;
    std::atomic<bool> closing { false };
    bool childReaped = false;
    bool trackLocalCwd = true;
    int wakeReadFd = -1;
    int wakeWriteFd = -1;
    std::mutex writeMutex;
    std::deque<PendingWrite> pendingWrites;
    size_t pendingWriteBytes = 0;
    std::string cwd;   // last known working directory
    std::string startCwd;
    // SSH password or private-key passphrase. It is never placed in a command
    // line/environment variable and is erased immediately after first use.
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
    if (kind != kKindOutput) {
        LOGI("push event session=%{public}d kind=%{public}s", s->id, kind.c_str());
    }
    SessionEvent* ev = new SessionEvent{ s->id, kind, data, exitCode };
    // A blocking TSFN call cannot be interrupted. If ArkUI destroys a session
    // while this bounded queue is full, the UI thread waits for ReaderMain and
    // ReaderMain waits for that same UI thread to drain the queue. Retry the
    // nonblocking call instead so closing the session always breaks the wait.
    for (;;) {
        napi_status st = napi_call_threadsafe_function(s->tsfn, ev, napi_tsfn_nonblocking);
        if (st == napi_ok) {
            return;
        }
        if (st != napi_queue_full) {
            delete ev;
            return;
        }
        bool closing = false;
        {
            std::lock_guard<std::mutex> lk(g_mutex);
            closing = s->closing;
        }
        if (closing) {
            delete ev;
            return;
        }
        usleep(1000);
    }
}

std::string LowerAscii(const std::string& value) {
    std::string lower = value;
    for (char& character : lower) {
        character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    }
    return lower;
}

void AppendUtf8Replacement(std::string& output) {
    output.append("\xEF\xBF\xBD", 3);
}

/**
 * PTY reads are byte-oriented and can split one UTF-8 code point between two
 * reads. N-API strings must be valid UTF-8, so preserve an incomplete suffix
 * and replace genuinely invalid bytes without touching ANSI control bytes.
 */
std::string SanitizeUtf8Chunk(const char* bytes, size_t length,
    std::string& incompleteTail, bool finalChunk) {
    std::string input = incompleteTail;
    if (bytes != nullptr && length > 0) {
        input.append(bytes, length);
    }
    incompleteTail.clear();
    std::string output;
    output.reserve(input.size());
    size_t index = 0;
    while (index < input.size()) {
        const unsigned char first = static_cast<unsigned char>(input[index]);
        if (first <= 0x7F) {
            output.push_back(input[index]);
            index++;
            continue;
        }

        size_t sequenceLength = 0;
        if (first >= 0xC2 && first <= 0xDF) sequenceLength = 2;
        else if (first >= 0xE0 && first <= 0xEF) sequenceLength = 3;
        else if (first >= 0xF0 && first <= 0xF4) sequenceLength = 4;
        else {
            AppendUtf8Replacement(output);
            index++;
            continue;
        }

        if (index + sequenceLength > input.size()) {
            if (finalChunk) AppendUtf8Replacement(output);
            else incompleteTail.assign(input, index, input.size() - index);
            break;
        }

        bool valid = true;
        for (size_t offset = 1; offset < sequenceLength; ++offset) {
            const unsigned char continuation = static_cast<unsigned char>(input[index + offset]);
            if ((continuation & 0xC0) != 0x80) {
                valid = false;
                break;
            }
        }
        if (valid && sequenceLength == 3) {
            const unsigned char second = static_cast<unsigned char>(input[index + 1]);
            valid = !((first == 0xE0 && second < 0xA0) || (first == 0xED && second > 0x9F));
        } else if (valid && sequenceLength == 4) {
            const unsigned char second = static_cast<unsigned char>(input[index + 1]);
            valid = !((first == 0xF0 && second < 0x90) || (first == 0xF4 && second > 0x8F));
        }
        if (!valid) {
            AppendUtf8Replacement(output);
            index++;
            continue;
        }
        output.append(input, index, sequenceLength);
        index += sequenceLength;
    }
    return output;
}

void WakeReader(PtySession* s) {
    if (s->wakeWriteFd < 0) return;
    const char value = 'w';
    ssize_t result = write(s->wakeWriteFd, &value, 1);
    (void)result;
}

bool EnqueueSessionWrite(PtySession* s, std::string data, bool highPriority) {
    if (data.empty()) return true;
    {
        std::lock_guard<std::mutex> lk(s->writeMutex);
        if (s->closing || data.size() > kPendingWriteLimit -
            std::min(kPendingWriteLimit, s->pendingWriteBytes)) {
            SecureErase(data);
            return false;
        }
        PendingWrite item;
        item.data.swap(data);
        s->pendingWriteBytes += item.data.size();
        if (highPriority) s->pendingWrites.push_front(std::move(item));
        else s->pendingWrites.push_back(std::move(item));
    }
    WakeReader(s);
    return true;
}

bool HasPendingWrites(PtySession* s) {
    std::lock_guard<std::mutex> lk(s->writeMutex);
    return !s->pendingWrites.empty();
}

void DrainWakePipe(PtySession* s) {
    if (s->wakeReadFd < 0) return;
    char buffer[64];
    for (;;) {
        ssize_t count = read(s->wakeReadFd, buffer, sizeof(buffer));
        if (count > 0) continue;
        if (count < 0 && errno == EINTR) continue;
        break;
    }
}

void DrainPendingWrites(PtySession* s, int masterFd) {
    std::lock_guard<std::mutex> lk(s->writeMutex);
    while (!s->pendingWrites.empty()) {
        PendingWrite& item = s->pendingWrites.front();
        const char* cursor = item.data.data() + item.offset;
        const size_t remaining = item.data.size() - item.offset;
        ssize_t count = write(masterFd, cursor, remaining);
        if (count > 0) {
            item.offset += static_cast<size_t>(count);
            s->pendingWriteBytes -= static_cast<size_t>(count);
            if (item.offset >= item.data.size()) {
                SecureErase(item.data);
                s->pendingWrites.pop_front();
            }
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        // The PTY is no longer writable. Drop queued input; the reader/waiter
        // path will deliver the authoritative exit event.
        for (PendingWrite& pending : s->pendingWrites) {
            SecureErase(pending.data);
        }
        s->pendingWrites.clear();
        s->pendingWriteBytes = 0;
        return;
    }
}

void ClearPendingWrites(PtySession* s) {
    std::lock_guard<std::mutex> lk(s->writeMutex);
    for (PendingWrite& pending : s->pendingWrites) {
        SecureErase(pending.data);
    }
    s->pendingWrites.clear();
    s->pendingWriteBytes = 0;
}

void HandleStoredSshCredential(PtySession* s, const std::string& output) {
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
    const bool passwordPrompt = lower.find("password:") != std::string::npos;
    const bool keyPassphrasePrompt = lower.find("enter passphrase for key") != std::string::npos ||
        lower.find("passphrase:") != std::string::npos;
    if (s->authSecretSent || (!passwordPrompt && !keyPassphrasePrompt)) return;

    std::string input = s->authSecret + "\n";
    const bool written = EnqueueSessionWrite(s, std::move(input), true);
    s->authSecretSent = true;
    SecureErase(s->authSecret);
    s->authTail.clear();
    LOGI("session %{public}d handled stored SSH credential written=%{public}d", s->id, written ? 1 : 0);
}

// ── Reader / waiter threads ─────────────────────────────────────────

void* ReaderMain(void* arg) {
    PtySession* s = static_cast<PtySession*>(arg);
    const int masterFd = s->masterFd;
    char buf[kReadChunk];
    std::string utf8Tail;
    auto nextCwdPoll = std::chrono::steady_clock::now();
    for (;;) {
        const bool wantsWrite = HasPendingWrites(s);
        struct pollfd pfds[2] = {
            { masterFd, static_cast<short>(POLLIN | (wantsWrite ? POLLOUT : 0)), 0 },
            { s->wakeReadFd, POLLIN, 0 }
        };
        int pr = poll(pfds, s->wakeReadFd >= 0 ? 2 : 1, 500);
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
        if (s->wakeReadFd >= 0 && (pfds[1].revents & POLLIN)) {
            DrainWakePipe(s);
        }
        {
            std::lock_guard<std::mutex> lk(g_mutex);
            if (s->closing) break;
        }
        if ((pfds[0].revents & POLLOUT) || HasPendingWrites(s)) {
            DrainPendingWrites(s, masterFd);
        }

        bool reachedEnd = false;
        if (pfds[0].revents & (POLLIN | POLLERR | POLLHUP)) {
            // Drain every byte before reporting exit. POLLIN and POLLHUP are
            // commonly delivered together; reading only once loses the final
            // screen when a short-lived shell or SSH process terminates.
            size_t burstBytes = 0;
            for (;;) {
                ssize_t n = read(masterFd, buf, sizeof(buf));
                if (n > 0) {
                    burstBytes += static_cast<size_t>(n);
                    const std::string rawOutput(buf, n);
                    HandleStoredSshCredential(s, rawOutput);
                    const std::string output = SanitizeUtf8Chunk(
                        buf, static_cast<size_t>(n), utf8Tail, false);
                    if (!output.empty()) {
                        PushEvent(s, kKindOutput, output, -1);
                    }
                    if (burstBytes >= kReadBurstLimit) break;
                    continue;
                }
                if (n == 0) {
                    reachedEnd = true;
                    break;
                }
                if (errno == EINTR) continue;
                if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                reachedEnd = true;
                break;
            }

            // Track cwd changes (shell cd) after the output burst. Doing this
            // once per poll wakeup avoids holding the global session mutex for
            // every individual PTY read.
            const auto now = std::chrono::steady_clock::now();
            if (s->trackLocalCwd && now >= nextCwdPoll && !reachedEnd &&
                !(pfds[0].revents & (POLLERR | POLLHUP))) {
                nextCwdPoll = now + std::chrono::milliseconds(kCwdPollIntervalMs);
                char linkBuf[1024] = {};
                char procPath[64];
                snprintf(procPath, sizeof(procPath), "/proc/%d/cwd", s->childPid);
                ssize_t len = readlink(procPath, linkBuf, sizeof(linkBuf) - 1);
                if (len > 0) {
                    linkBuf[len] = '\0';
                    bool cwdChanged = false;
                    {
                        std::lock_guard<std::mutex> lk(g_mutex);
                        if (s->cwd != linkBuf) {
                            s->cwd = linkBuf;
                            cwdChanged = true;
                        }
                    }
                    if (cwdChanged) {
                        PushEvent(s, kKindCwd, linkBuf, -1);
                    }
                }
            }
        }
        if (reachedEnd || (pfds[0].revents & (POLLERR | POLLHUP | POLLNVAL))) {
            break;
        }
        if (pfds[0].revents & POLLIN) {
            // The nonblocking drain above consumed all currently available
            // data. Keep polling for the next output burst.
            continue;
        }
        if (pfds[0].revents & POLLNVAL) {
            break;
        }
    }
    const std::string finalOutput = SanitizeUtf8Chunk(nullptr, 0, utf8Tail, true);
    if (!finalOutput.empty()) {
        PushEvent(s, kKindOutput, finalOutput, -1);
    }
    SecureErase(s->authSecret);
    return nullptr;
}

void* WaiterMain(void* arg) {
    PtySession* s = static_cast<PtySession*>(arg);
    const pid_t childPid = s->childPid;
    int status = 0;
    pid_t w = -1;
    do {
        w = waitpid(childPid, &status, 0);
    } while (w < 0 && errno == EINTR);
    const bool childConsumed = w == childPid || (w < 0 && errno == ECHILD);
    int code = -1;
    if (w == childPid) {
        if (WIFEXITED(status)) code = WEXITSTATUS(status);
        else if (WIFSIGNALED(status)) code = 128 + WTERMSIG(status);
    }
    // waitpid() has already consumed the child. Publish that fact before the
    // potentially long reader drain/join so a concurrent close cannot signal
    // an unrelated process if the kernel reuses the PID in the meantime.
    {
        std::lock_guard<std::mutex> lk(g_mutex);
        s->childReaped = childConsumed;
    }
    LOGI("session %{public}d child %{public}d exited code=%{public}d", s->id, childPid, code);
    // ReaderMain owns the ordering of PTY output. Wait until it has drained the
    // slave side completely, then enqueue exit after every output event.
    if (s->readerStarted) {
        pthread_join(s->readerThread, nullptr);
    }
    bool shouldNotify = true;
    {
        std::lock_guard<std::mutex> lk(g_mutex);
        s->alive = false;
        shouldNotify = !s->closing;
    }
    if (shouldNotify) {
        PushEvent(s, kKindExit, "", code);
    }
    return nullptr;
}

// ── Session lifecycle ───────────────────────────────────────────────

bool SessionChildNeedsSignal(PtySession* s, pid_t childPid) {
    std::lock_guard<std::mutex> lk(g_mutex);
    return childPid > 0 && s->childPid == childPid && !s->childReaped;
}

void DestroySessionProcess(PtySession* s) {
    // The session has already been removed and marked dead under g_mutex.
    // Never join while holding that mutex: reader/waiter callbacks may need it.
    const pid_t childPid = s->childPid;
    if (SessionChildNeedsSignal(s, childPid)) {
        kill(-childPid, SIGHUP);
        kill(childPid, SIGHUP);
        kill(-childPid, SIGTERM);
        kill(childPid, SIGTERM);
    }
    WakeReader(s);
    if (s->masterFd >= 0) {
        close(s->masterFd);
        s->masterFd = -1;
    }

    // A shell or one of its descendants can ignore SIGHUP/SIGTERM. Bound the
    // close path so killSession can never freeze the ArkUI thread forever.
    if (SessionChildNeedsSignal(s, childPid)) {
        for (int attempt = 0; attempt < 10; ++attempt) {
            if (!SessionChildNeedsSignal(s, childPid) ||
                (kill(childPid, 0) != 0 && errno == ESRCH)) break;
            usleep(10 * 1000);
        }
        if (SessionChildNeedsSignal(s, childPid) && kill(childPid, 0) == 0) {
            kill(-childPid, SIGKILL);
            kill(childPid, SIGKILL);
        }
    }
    if (s->waiterStarted) {
        pthread_join(s->waiterThread, nullptr);
        s->waiterStarted = false;
    } else if (s->readerStarted) {
        pthread_join(s->readerThread, nullptr);
        s->readerStarted = false;
    }
    if (s->wakeReadFd >= 0) {
        close(s->wakeReadFd);
        s->wakeReadFd = -1;
    }
    if (s->wakeWriteFd >= 0) {
        close(s->wakeWriteFd);
        s->wakeWriteFd = -1;
    }
    ClearPendingWrites(s);
}

void ReleaseSessionNapi(PtySession* s) {
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

void DestroySession(PtySession* s) {
    DestroySessionProcess(s);
    ReleaseSessionNapi(s);
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
    if (cols < 2 || cols > 1000) cols = 80;
    if (rows < 2 || rows > 1000) rows = 24;

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
        env, jsCallback, nullptr, resName, kTsfnQueueLimit, 1,
        nullptr, nullptr, nullptr, CallJs, &s->tsfn);
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
    if (grantpt(master) != 0 || unlockpt(master) != 0) {
        const int setupError = errno;
        LOGE("session create: grantpt/unlockpt failed errno=%{public}d", setupError);
        close(master);
        napi_release_threadsafe_function(s->tsfn, napi_tsfn_abort);
        napi_delete_reference(env, s->jsCallbackRef);
        delete s;
        napi_throw_error(env, nullptr, "grantpt/unlockpt failed");
        return nullptr;
    }
    char slavePath[256] = {};
    if (ptsname_r(master, slavePath, sizeof(slavePath)) != 0 || slavePath[0] == '\0') {
        const int setupError = errno;
        LOGE("session create: ptsname_r failed errno=%{public}d", setupError);
        close(master);
        napi_release_threadsafe_function(s->tsfn, napi_tsfn_abort);
        napi_delete_reference(env, s->jsCallbackRef);
        delete s;
        napi_throw_error(env, nullptr, "ptsname_r failed");
        return nullptr;
    }

    // Keep the master nonblocking for its whole lifetime. Toggling O_NONBLOCK
    // on dup(master) also changes the original open file description and races
    // the reader/password writer.
    const int masterFlags = fcntl(master, F_GETFL, 0);
    if (masterFlags < 0 || fcntl(master, F_SETFL, masterFlags | O_NONBLOCK) != 0) {
        const int setupError = errno;
        LOGE("session create: fcntl O_NONBLOCK failed errno=%{public}d", setupError);
        close(master);
        napi_release_threadsafe_function(s->tsfn, napi_tsfn_abort);
        napi_delete_reference(env, s->jsCallbackRef);
        delete s;
        napi_throw_error(env, nullptr, "configure PTY failed");
        return nullptr;
    }

    int wakePipe[2] = { -1, -1 };
    if (pipe(wakePipe) != 0) {
        const int setupError = errno;
        LOGE("session create: wake pipe failed errno=%{public}d", setupError);
        close(master);
        napi_release_threadsafe_function(s->tsfn, napi_tsfn_abort);
        napi_delete_reference(env, s->jsCallbackRef);
        delete s;
        napi_throw_error(env, nullptr, "configure terminal input queue failed");
        return nullptr;
    }
    for (int fd : wakePipe) {
        const int flags = fcntl(fd, F_GETFL, 0);
        const int descriptorFlags = fcntl(fd, F_GETFD, 0);
        if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        if (descriptorFlags >= 0) fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC);
    }
    s->wakeReadFd = wakePipe[0];
    s->wakeWriteFd = wakePipe[1];

    struct winsize ws { (unsigned short)rows, (unsigned short)cols, 0, 0 };
    ioctl(master, TIOCSWINSZ, &ws);

    pid_t child = fork();
    if (child < 0) {
        LOGE("fork failed errno=%d", errno);
        close(master);
        close(s->wakeReadFd);
        close(s->wakeWriteFd);
        s->wakeReadFd = -1;
        s->wakeWriteFd = -1;
        napi_throw_error(env, nullptr, "fork failed");
        napi_release_threadsafe_function(s->tsfn, napi_tsfn_abort);
        napi_delete_reference(env, s->jsCallbackRef);
        delete s;
        return nullptr;
    }
    if (child == 0) {
        // ── child: attach slave as controlling terminal ──
        close(wakePipe[0]);
        close(wakePipe[1]);
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
    s->trackLocalCwd = startCmd.rfind("/usr/bin/ssh", 0) != 0;
    {
        std::lock_guard<std::mutex> lk(g_mutex);
        g_sessions[s->id] = s;
    }

    int threadResult = pthread_create(&s->readerThread, nullptr, ReaderMain, s);
    if (threadResult == 0) {
        s->readerStarted = true;
        threadResult = pthread_create(&s->waiterThread, nullptr, WaiterMain, s);
        s->waiterStarted = threadResult == 0;
    }
    if (!s->readerStarted || !s->waiterStarted) {
        LOGE("session %{public}d thread creation failed result=%{public}d", s->id, threadResult);
        {
            std::lock_guard<std::mutex> lk(g_mutex);
            s->closing = true;
            s->alive = false;
            g_sessions.erase(s->id);
        }
        kill(-child, SIGKILL);
        kill(child, SIGKILL);
        close(master);
        s->masterFd = -1;
        WakeReader(s);
        if (s->readerStarted) {
            pthread_join(s->readerThread, nullptr);
        }
        if (s->wakeReadFd >= 0) close(s->wakeReadFd);
        if (s->wakeWriteFd >= 0) close(s->wakeWriteFd);
        s->wakeReadFd = -1;
        s->wakeWriteFd = -1;
        int childStatus = 0;
        waitpid(child, &childStatus, 0);
        napi_release_threadsafe_function(s->tsfn, napi_tsfn_abort);
        napi_delete_reference(env, s->jsCallbackRef);
        delete s;
        napi_throw_error(env, nullptr, "create terminal worker failed");
        return nullptr;
    }

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
    const bool validData = ReadUtf8String(env, args[1], kPendingWriteLimit, data);
    bool ok = false;
    {
        std::lock_guard<std::mutex> lk(g_mutex);
        auto it = g_sessions.find(id);
        if (validData && it != g_sessions.end() && it->second->alive &&
            it->second->masterFd >= 0) {
            // Keep the registry lock until the write has been copied into the
            // session-owned queue. Async close removes the entry before it can
            // destroy the session, so the raw pointer cannot become stale.
            ok = EnqueueSessionWrite(it->second, std::move(data), false);
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
            victim->closing = true;
            victim->alive = false;
            g_sessions.erase(it);
        }
    }
    if (victim != nullptr) {
        DestroySession(victim);
        LOGI("session %d killed", id);
    }
    napi_value ret;
    napi_get_boolean(env, victim != nullptr, &ret);
    return ret;
}

struct KillSessionAsyncWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    PtySession* session = nullptr;
    bool previousAlive = false;
    bool previousClosing = false;
};

void ExecuteKillSession(napi_env /*env*/, void* data) {
    KillSessionAsyncWork* request = static_cast<KillSessionAsyncWork*>(data);
    DestroySessionProcess(request->session);
}

void CompleteKillSession(napi_env env, napi_status status, void* data) {
    KillSessionAsyncWork* request = static_cast<KillSessionAsyncWork*>(data);
    ReleaseSessionNapi(request->session);
    if (status == napi_ok) {
        napi_value result;
        napi_get_boolean(env, true, &result);
        napi_resolve_deferred(env, request->deferred, result);
    } else {
        napi_value message;
        napi_create_string_utf8(env, "terminal cleanup worker failed", NAPI_AUTO_LENGTH, &message);
        napi_value error;
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, request->deferred, error);
    }
    napi_delete_async_work(env, request->work);
    delete request;
}

// ── NAPI: killSessionAsync(id) -> Promise<boolean> ──────────────────

napi_value KillSessionAsync(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = -1;
    napi_get_value_int32(env, args[0], &id);

    KillSessionAsyncWork* request = new KillSessionAsyncWork();
    napi_value promise;
    napi_create_promise(env, &request->deferred, &promise);
    {
        std::lock_guard<std::mutex> lk(g_mutex);
        auto it = g_sessions.find(id);
        if (it != g_sessions.end()) {
            request->session = it->second;
            request->previousAlive = request->session->alive;
            request->previousClosing = request->session->closing;
            request->session->closing = true;
            request->session->alive = false;
            g_sessions.erase(it);
        }
    }
    if (request->session == nullptr) {
        napi_value result;
        napi_get_boolean(env, false, &result);
        napi_resolve_deferred(env, request->deferred, result);
        delete request;
        return promise;
    }

    napi_value resourceName;
    napi_create_string_utf8(env, "terminai_kill_session", NAPI_AUTO_LENGTH, &resourceName);
    napi_status status = napi_create_async_work(env, nullptr, resourceName, ExecuteKillSession,
        CompleteKillSession, request, &request->work);
    if (status != napi_ok || napi_queue_async_work(env, request->work) != napi_ok) {
        // Restore a usable session entry if the worker could not be queued. The
        // caller can retry without paying a synchronous UI-thread join here.
        {
            std::lock_guard<std::mutex> lk(g_mutex);
            request->session->closing = request->previousClosing;
            request->session->alive = request->previousAlive;
            g_sessions[id] = request->session;
        }
        napi_value message;
        napi_create_string_utf8(env, "unable to queue terminal cleanup", NAPI_AUTO_LENGTH, &message);
        napi_value error;
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, request->deferred, error);
        if (request->work != nullptr) {
            napi_delete_async_work(env, request->work);
        }
        delete request;
    }
    return promise;
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

std::vector<pid_t> ProcessChildren(pid_t pid) {
    char path[96];
    snprintf(path, sizeof(path), "/proc/%d/task/%d/children", pid, pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return {};
    char buffer[4096] = {};
    ssize_t count = read(fd, buffer, sizeof(buffer) - 1);
    close(fd);
    std::vector<pid_t> children;
    if (count <= 0) return children;
    std::istringstream values(buffer);
    pid_t child = -1;
    while (values >> child) {
        if (child > 0) children.push_back(child);
    }
    return children;
}

pid_t RepresentativeProcess(pid_t foregroundGroup, pid_t fallback) {
    if (foregroundGroup <= 0) return fallback;
    // In normal job-control sessions the process-group leader is the agent.
    // Avoid inspecting any descendants in that common case.
    const std::string leaderCommand = ProcessCommand(foregroundGroup);
    if (!leaderCommand.empty() && !IsShellCommand(leaderCommand)) {
        return foregroundGroup;
    }

    // The app can reliably inspect its own descendants even without the
    // system-only readproc group. Follow this session's process tree instead of
    // scanning every process on the machine while the ArkUI thread waits.
    std::vector<pid_t> pending;
    std::vector<pid_t> visited;
    pending.push_back(fallback);
    size_t cursor = 0;
    while (cursor < pending.size() && visited.size() < 128) {
        const pid_t parent = pending[cursor++];
        const std::vector<pid_t> children = ProcessChildren(parent);
        for (pid_t child : children) {
            bool alreadyVisited = false;
            for (pid_t known : visited) {
                if (known == child) {
                    alreadyVisited = true;
                    break;
                }
            }
            if (alreadyVisited) continue;
            visited.push_back(child);
            pending.push_back(child);
            if (ProcessGroupOf(child) != foregroundGroup) continue;
            const std::string command = ProcessCommand(child);
            if (!command.empty() && !IsShellCommand(command)) {
                return child;
            }
        }
    }
    return !leaderCommand.empty() ? foregroundGroup : fallback;
}

struct SessionProcessSnapshot {
    bool alive = false;
    pid_t shellPid = -1;
    pid_t foregroundPid = -1;
    std::string command;
    std::string processState;
    unsigned long long cpuTicks = 0;
};

SessionProcessSnapshot CollectSessionProcessSnapshot(int32_t id) {
    SessionProcessSnapshot snapshot;
    int inspectFd = -1;
    {
        std::lock_guard<std::mutex> lk(g_mutex);
        auto it = g_sessions.find(id);
        if (it != g_sessions.end()) {
            PtySession* session = it->second;
            snapshot.alive = session->alive;
            snapshot.shellPid = session->childPid;
            if (snapshot.alive && session->masterFd >= 0) {
                inspectFd = dup(session->masterFd);
            }
        }
    }
    if (inspectFd >= 0) {
        const pid_t group = tcgetpgrp(inspectFd);
        close(inspectFd);
        snapshot.foregroundPid = RepresentativeProcess(group, snapshot.shellPid);
        snapshot.command = ProcessCommand(snapshot.foregroundPid);
        ProcessRuntimeStats stats;
        if (ReadProcessRuntimeStats(snapshot.foregroundPid, stats)) {
            snapshot.processState.assign(1, stats.state);
            snapshot.cpuTicks = stats.cpuTicks;
        }
    }
    return snapshot;
}

napi_value SessionProcessSnapshotObject(napi_env env, const SessionProcessSnapshot& snapshot) {
    napi_value object;
    napi_create_object(env, &object);
    napi_value value;
    napi_get_boolean(env, snapshot.alive, &value);
    napi_set_named_property(env, object, "alive", value);
    napi_create_int32(env, snapshot.shellPid, &value);
    napi_set_named_property(env, object, "shellPid", value);
    napi_create_int32(env, snapshot.foregroundPid, &value);
    napi_set_named_property(env, object, "foregroundPid", value);
    napi_create_string_utf8(env, snapshot.command.c_str(), NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, object, "foregroundCommand", value);
    napi_get_boolean(env, IsShellCommand(snapshot.command), &value);
    napi_set_named_property(env, object, "foregroundIsShell", value);
    napi_create_string_utf8(env, snapshot.processState.c_str(), NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, object, "foregroundState", value);
    napi_create_int64(env, static_cast<int64_t>(snapshot.cpuTicks), &value);
    napi_set_named_property(env, object, "cpuTimeTicks", value);
    return object;
}

// ── NAPI: inspectSession(id) -> foreground process signal ──────────
napi_value InspectSession(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = -1;
    napi_get_value_int32(env, args[0], &id);
    return SessionProcessSnapshotObject(env, CollectSessionProcessSnapshot(id));
}

struct InspectSessionAsyncWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    int32_t id = -1;
    SessionProcessSnapshot snapshot;
};

void ExecuteInspectSession(napi_env /*env*/, void* data) {
    InspectSessionAsyncWork* request = static_cast<InspectSessionAsyncWork*>(data);
    request->snapshot = CollectSessionProcessSnapshot(request->id);
}

void CompleteInspectSession(napi_env env, napi_status status, void* data) {
    InspectSessionAsyncWork* request = static_cast<InspectSessionAsyncWork*>(data);
    if (status == napi_ok) {
        napi_value result = SessionProcessSnapshotObject(env, request->snapshot);
        napi_resolve_deferred(env, request->deferred, result);
    } else {
        napi_value message;
        napi_create_string_utf8(env, "inspect session async work failed", NAPI_AUTO_LENGTH, &message);
        napi_value error;
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, request->deferred, error);
    }
    napi_delete_async_work(env, request->work);
    delete request;
}

napi_value InspectSessionAsync(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    InspectSessionAsyncWork* request = new InspectSessionAsyncWork();
    napi_get_value_int32(env, args[0], &request->id);

    napi_value promise;
    napi_create_promise(env, &request->deferred, &promise);
    napi_value resourceName;
    napi_create_string_utf8(env, "terminai_inspect_session", NAPI_AUTO_LENGTH, &resourceName);
    napi_status status = napi_create_async_work(env, nullptr, resourceName, ExecuteInspectSession,
        CompleteInspectSession, request, &request->work);
    if (status != napi_ok || napi_queue_async_work(env, request->work) != napi_ok) {
        napi_value message;
        napi_create_string_utf8(env, "unable to queue session inspection", NAPI_AUTO_LENGTH, &message);
        napi_value error;
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, request->deferred, error);
        if (request->work != nullptr) {
            napi_delete_async_work(env, request->work);
        }
        delete request;
    }
    return promise;
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

// OpenSSH refuses private keys that are readable by other users. Picker files
// are copied into the app sandbox first, then restricted to owner read/write.
napi_value SecurePrivateFile(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string path;
    if (argc < 1 || !ReadUtf8String(env, args[0], 4095, path) || path.empty() || path[0] != '/') {
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }

    struct stat st {};
    const bool secured = lstat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode) &&
        chmod(path.c_str(), S_IRUSR | S_IWUSR) == 0;
    napi_value result;
    napi_get_boolean(env, secured, &result);
    return result;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        { "createSession", nullptr, CreateSession, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "createSessionWithSecret", nullptr, CreateSession, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "writeSession", nullptr, WriteSession, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "resizeSession", nullptr, ResizeSession, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "killSession", nullptr, KillSession, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "killSessionAsync", nullptr, KillSessionAsync, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "listSessions", nullptr, ListSessions, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "inspectSession", nullptr, InspectSession, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "inspectSessionAsync", nullptr, InspectSessionAsync, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "listPrograms", nullptr, ListPrograms, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "listDirs", nullptr, ListDirs, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "securePrivateFile", nullptr, SecurePrivateFile, nullptr, nullptr, nullptr, napi_default, nullptr },
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
