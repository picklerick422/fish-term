// crash_handler.cpp — Native signal handler for SIGSEGV, SIGABRT, SIGBUS, SIGFPE.
// Uses ONLY async-signal-safe APIs (open, write, close, backtrace_symbols_fd).
// No malloc, no printf, no locks (except a single CAS for thread safety).

#include <csignal>
#include <cstdio>
#include <atomic>
#include <cstring>
#include <ctime>
#include <unistd.h>
#include <fcntl.h>
#include <execinfo.h>
#include <sys/stat.h>

namespace {

// Signal names for readable output.
const char* signal_name(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGABRT: return "SIGABRT";
        case SIGBUS:  return "SIGBUS";
        case SIGFPE:  return "SIGFPE";
        case SIGILL:  return "SIGILL";
        default:      return "UNKNOWN";
    }
}

// Timestamp string in YYYYMMDD_HHmmss format (safe to call in signal handler).
void write_timestamp(int fd) {
    time_t now = time(nullptr);
    struct tm tm_buf;
    char buf[32];
    if (localtime_r(&now, &tm_buf) != nullptr) {
        int len = snprintf(buf, sizeof(buf), "%04d%02d%02d_%02d%02d%02d",
                           tm_buf.tm_year + 1900, tm_buf.tm_mon + 1, tm_buf.tm_mday,
                           tm_buf.tm_hour, tm_buf.tm_min, tm_buf.tm_sec);
        if (len > 0 && len < static_cast<int>(sizeof(buf))) {
            write(fd, buf, len);
            return;
        }
    }
    // Fallback: raw unix timestamp
    int len = snprintf(buf, sizeof(buf), "%ld", static_cast<long>(now));
    if (len > 0 && len < static_cast<int>(sizeof(buf))) {
        write(fd, buf, len);
    }
}

// The signal handler itself — minimal, safe, no allocation.
std::atomic<int> g_crash_handling{0};
struct sigaction g_prev_segv;
struct sigaction g_prev_abrt;
struct sigaction g_prev_bus;
struct sigaction g_prev_fpe;
struct sigaction g_prev_ill;

void crash_signal_handler(int sig, siginfo_t* info, void* /* ucontext */) {
    // CAS lock: first thread to arrive handles the crash; others spin-wait then exit.
    int expected = 0;
    if (!g_crash_handling.compare_exchange_strong(expected, 1)) {
        // Another thread is already writing the crash log — spin briefly then die.
        for (volatile int i = 0; i < 1000000; ++i) { }
        _exit(128 + sig);
    }

    // Try to open a file. Best-effort: try several candidate paths.
    // The crash_logs directory under the app sandbox.
    const char* paths[] = {
        "crash_logs/native_crash.log",
        nullptr
    };

    int fd = -1;
    // Ensure directory exists (best-effort, ignore errors)
    mkdir("crash_logs", 0755);
    for (int i = 0; paths[i] != nullptr; ++i) {
        fd = open(paths[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            break;
        }
    }

    if (fd >= 0) {
        // Write header
        const char* sig_str = signal_name(sig);
        write(fd, "=== Native Crash ===\n", 21);
        write(fd, "Signal: ", 8);
        write(fd, sig_str, strlen(sig_str));
        write(fd, "\nTimestamp: ", 12);
        write_timestamp(fd);

        // Write fault address if available
        if (info != nullptr && sig == SIGSEGV) {
            char addr_buf[64];
            int addr_len = snprintf(addr_buf, sizeof(addr_buf), "\nFaultAddr: %p", info->si_addr);
            if (addr_len > 0 && addr_len < static_cast<int>(sizeof(addr_buf))) {
                write(fd, addr_buf, addr_len);
            }
        }
        write(fd, "\n\nStack trace:\n", 15);

        // Capture backtrace using async-signal-safe API
        void* bt[64];
        int count = backtrace(bt, 64);
        if (count > 0) {
            backtrace_symbols_fd(bt, count, fd);
        } else {
            write(fd, "  (backtrace unavailable)\n", 26);
        }

        write(fd, "\n", 1);
        close(fd);
    }

    // Restore default handler and re-raise so the system gets the crash too.
    struct sigaction* prev = nullptr;
    switch (sig) {
        case SIGSEGV: prev = &g_prev_segv; break;
        case SIGABRT: prev = &g_prev_abrt; break;
        case SIGBUS:  prev = &g_prev_bus;  break;
        case SIGFPE:  prev = &g_prev_fpe;  break;
        case SIGILL:  prev = &g_prev_ill;  break;
        default: break;
    }
    if (prev && prev->sa_handler != SIG_IGN && prev->sa_handler != SIG_DFL) {
        sigaction(sig, prev, nullptr);
    } else {
        signal(sig, SIG_DFL);
    }
    raise(sig);
    _exit(128 + sig);
}

void install_signal(int sig, struct sigaction* prev_out) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = crash_signal_handler;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    sigaction(sig, &sa, prev_out);
}

} // anonymous namespace

// Public entry point — called from napi_init or module register.
extern "C" void InstallNativeCrashHandler() {
    install_signal(SIGSEGV, &g_prev_segv);
    install_signal(SIGABRT, &g_prev_abrt);
    install_signal(SIGBUS,  &g_prev_bus);
    install_signal(SIGFPE,  &g_prev_fpe);
    install_signal(SIGILL,  &g_prev_ill);
}
