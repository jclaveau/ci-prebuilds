// Fatal-signal reporter for the PGO corpus run, LD_PRELOADed into MiniBrowser
// and inherited by every WebKit process it spawns.
//
// Run 36242656232's instrumented WebProcess died in WTFCrashWithInfo (a
// RELEASE_ASSERT) on the first Speedometer test page, and a release build says
// nothing when that happens: the profile only showed that it crashed, not
// where. On SIGILL (ud2, which is what WTFCrash compiles to), SIGSEGV, SIGBUS,
// SIGFPE, SIGTRAP or SIGABRT this writes $PGO_CRASH_DIR/crash-<pid>.txt with
// the registers, the top of the stack, any register or stack word that points
// at a printable string (RELEASE_ASSERT passes __FILE__ and the function name),
// and /proc/self/maps, so pgo-symbolize-crash.py can map every code address
// back to the instrumented libraries before Phase 0 deletes them.
//
// Installed from a constructor, so it runs before JSC's own handlers. JSC
// saves the handler it replaces and forwards the signals it does not own, so
// its wasm and VM-trap faults never reach this one.
#define _GNU_SOURCE
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <ucontext.h>
#include <unistd.h>

#define STACK_WORDS 512
#define MAPS_BYTES (1 << 20)
#define MAX_RANGES 8192

static char maps_buffer[MAPS_BYTES];
static size_t maps_length;
static uintptr_t range_starts[MAX_RANGES];
static uintptr_t range_ends[MAX_RANGES];
static int range_count;
static int report_fd = -1;

static void write_text(const char *text) {
    size_t length = strlen(text);
    while (length > 0) {
        ssize_t written = write(report_fd, text, length);
        if (written <= 0)
            return;
        text += written;
        length -= (size_t)written;
    }
}

static void write_hex(uintptr_t value) {
    char digits[19] = "0x";
    for (int index = 0; index < 16; index++)
        digits[2 + index] = "0123456789abcdef"[(value >> (60 - 4 * index)) & 0xf];
    digits[18] = 0;
    write_text(digits);
}

static void write_decimal(long value) {
    char digits[24];
    int position = 23;
    int negative = value < 0;
    unsigned long magnitude = negative ? -(unsigned long)value : (unsigned long)value;
    digits[position] = 0;
    do {
        digits[--position] = (char)('0' + magnitude % 10);
        magnitude /= 10;
    } while (magnitude && position > 1);
    if (negative)
        digits[--position] = '-';
    write_text(digits + position);
}

static uintptr_t parse_hex(const char **cursor) {
    uintptr_t value = 0;
    for (;;) {
        char digit = **cursor;
        if (digit >= '0' && digit <= '9')
            value = value * 16 + (uintptr_t)(digit - '0');
        else if (digit >= 'a' && digit <= 'f')
            value = value * 16 + (uintptr_t)(digit - 'a' + 10);
        else
            return value;
        (*cursor)++;
    }
}

// Reads /proc/self/maps and keeps the readable ranges, so the string probe
// below never dereferences an unmapped address.
static void load_maps(void) {
    int maps_fd = open("/proc/self/maps", O_RDONLY | O_CLOEXEC);
    if (maps_fd < 0)
        return;
    ssize_t chunk;
    while (maps_length < MAPS_BYTES - 1
        && (chunk = read(maps_fd, maps_buffer + maps_length, MAPS_BYTES - 1 - maps_length)) > 0)
        maps_length += (size_t)chunk;
    close(maps_fd);
    maps_buffer[maps_length] = 0;

    const char *cursor = maps_buffer;
    while (*cursor && range_count < MAX_RANGES) {
        uintptr_t range_start = parse_hex(&cursor);
        cursor++;
        uintptr_t range_end = parse_hex(&cursor);
        cursor++;
        if (cursor[0] == 'r') {
            range_starts[range_count] = range_start;
            range_ends[range_count] = range_end;
            range_count++;
        }
        while (*cursor && *cursor != '\n')
            cursor++;
        if (*cursor)
            cursor++;
    }
}

static int is_readable(uintptr_t address, size_t length) {
    for (int index = 0; index < range_count; index++) {
        if (address >= range_starts[index] && address + length <= range_ends[index])
            return 1;
    }
    return 0;
}

// Prints the string at `address` when it looks like one: at least 4 printable
// bytes, then a NUL, all inside one readable mapping.
static void probe_string(uintptr_t address) {
    if (!is_readable(address, 1))
        return;
    const char *text = (const char *)address;
    size_t length = 0;
    while (length < 200 && is_readable(address + length, 1)
        && text[length] >= 0x20 && text[length] < 0x7f)
        length++;
    if (length < 4 || length == 200 || !is_readable(address + length, 1) || text[length])
        return;
    write_text(" str=\"");
    write_text(text);
    write_text("\"");
}

static void report_word(const char *label, long index, uintptr_t value) {
    write_text(label);
    if (index >= 0)
        write_decimal(index);
    write_text(" ");
    write_hex(value);
    probe_string(value);
    write_text("\n");
}

static void fatal_signal_handler(int signal_number, siginfo_t *signal_info, void *context) {
    const char *crash_dir = getenv("PGO_CRASH_DIR");
    if (crash_dir && strlen(crash_dir) < 200) {
        char report_path[256] = "";
        char pid_text[24];
        char *pid_cursor = pid_text + sizeof pid_text - 1;
        unsigned long pid_value = (unsigned long)getpid();
        *pid_cursor = 0;
        do {
            *--pid_cursor = (char)('0' + pid_value % 10);
            pid_value /= 10;
        } while (pid_value);
        strcat(report_path, crash_dir);
        strcat(report_path, "/crash-");
        strcat(report_path, pid_cursor);
        strcat(report_path, ".txt");
        report_fd = open(report_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    }
    if (report_fd < 0)
        report_fd = 2;

    load_maps();
    write_text("signal ");
    write_decimal(signal_number);
    write_text(" pid ");
    write_decimal((long)getpid());
    write_text(" fault_addr ");
    write_hex((uintptr_t)signal_info->si_addr);
    write_text("\n");

#if defined(__x86_64__)
    static const struct { const char *name; int index; } registers[] = {
        { "rip", REG_RIP }, { "rsp", REG_RSP }, { "rbp", REG_RBP },
        { "rax", REG_RAX }, { "rbx", REG_RBX }, { "rcx", REG_RCX },
        { "rdx", REG_RDX }, { "rsi", REG_RSI }, { "rdi", REG_RDI },
        { "r8", REG_R8 }, { "r9", REG_R9 }, { "r10", REG_R10 },
        { "r11", REG_R11 }, { "r12", REG_R12 }, { "r13", REG_R13 },
        { "r14", REG_R14 }, { "r15", REG_R15 },
    };
    const greg_t *saved_registers = ((ucontext_t *)context)->uc_mcontext.gregs;
    for (size_t index = 0; index < sizeof registers / sizeof registers[0]; index++) {
        write_text("reg ");
        report_word(registers[index].name, -1, (uintptr_t)saved_registers[registers[index].index]);
    }
    const uintptr_t *stack_words = (const uintptr_t *)saved_registers[REG_RSP];
    for (long index = 0; index < STACK_WORDS; index++) {
        if (!is_readable((uintptr_t)(stack_words + index), sizeof(uintptr_t)))
            break;
        report_word("stack ", index, stack_words[index]);
    }
#else
    (void)context;
#endif

    write_text("--- maps\n");
    write_text(maps_buffer);
    if (report_fd != 2)
        close(report_fd);

    // Back to the default action: returning re-runs the faulting instruction,
    // and SIGABRT, which has none, is raised again.
    signal(signal_number, SIG_DFL);
    if (signal_number == SIGABRT)
        raise(SIGABRT);
}

__attribute__((constructor)) static void install_crash_report(void) {
    static const int fatal_signals[] = { SIGILL, SIGSEGV, SIGBUS, SIGFPE, SIGTRAP, SIGABRT };
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_sigaction = fatal_signal_handler;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    for (size_t index = 0; index < sizeof fatal_signals / sizeof fatal_signals[0]; index++)
        sigaction(fatal_signals[index], &action, NULL);
}
