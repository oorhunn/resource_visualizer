#include "monitor.hpp"
#include "render.hpp"

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <csignal>
#include <iostream>
#include <stdexcept>
#include <string>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <termios.h>
#include <unistd.h>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;
volatile std::sig_atomic_t stopped = 0;
volatile std::sig_atomic_t resized = 0;
void stop(int) { stopped = 1; }
void resize(int) { resized = 1; }

const std::string reset = "\x1b[0m";
const std::string dim = "\x1b[2m";
const std::string bold = "\x1b[1m";
const std::string inverse = "\x1b[7m";
const std::string track = "\x1b[48;5;236m"; // dark grey background behind bars
const double intervals[] = {0.25, 0.5, 1, 2, 5, 10};

std::string gauge(double percent, int width) {
    static const char *const colors[] = {"\x1b[32m", "\x1b[33m", "\x1b[31m"};
    return colors[render::level(percent)] + track + render::bar(percent, width) + reset;
}
// Marks the first match of `query`; `text` must already be fitted to its column.
std::string highlight(const std::string &text, const std::string &query) {
    const auto at = query.empty() ? std::string::npos : render::find_ci(text, query);
    if (at == std::string::npos)
        return text;
    return text.substr(0, at) + "\x1b[1;30;43m" + text.substr(at, query.size()) + reset +
           text.substr(at + query.size());
}
std::string percent_text(std::optional<double> value) {
    return value ? render::fixed(*value) + "%" : "N/A";
}

void write_all(const std::string &text) {
    std::size_t offset = 0;
    while (offset < text.size()) {
        const auto written = ::write(STDOUT_FILENO, text.data() + offset, text.size() - offset);
        if (written < 0) {
            if (errno == EINTR)
                continue;
            return;
        }
        offset += static_cast<std::size_t>(written);
    }
}

// Raw, non-echoing input on the alternate screen; the destructor restores the shell.
class Terminal {
  public:
    Terminal() {
        if (tcgetattr(STDIN_FILENO, &original_) == 0) {
            termios raw = original_;
            raw.c_lflag &= ~static_cast<tcflag_t>(ICANON | ECHO);
            raw.c_cc[VMIN] = 0;
            raw.c_cc[VTIME] = 0;
            raw_ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0;
        }
        // Alternate screen, hidden cursor, no autowrap so long lines clip instead of scrolling.
        write_all("\x1b[?1049h\x1b[?25l\x1b[?7l");
    }
    ~Terminal() {
        write_all("\x1b[?7h\x1b[?25h\x1b[?1049l");
        if (raw_)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original_);
    }
    Terminal(const Terminal &) = delete;
    Terminal &operator=(const Terminal &) = delete;
    static std::pair<int, int> size() {
        winsize window{};
        if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0 && window.ws_col && window.ws_row)
            return {window.ws_col, window.ws_row};
        return {100, 40};
    }

  private:
    termios original_{};
    bool raw_ = false;
};

// Returns a pressed key, or 0 once the deadline passes or a signal arrives.
int wait_key(Clock::time_point deadline) {
    while (!stopped && !resized) {
        const auto now = Clock::now();
        if (now >= deadline)
            return 0;
        const auto remaining =
            std::chrono::duration_cast<std::chrono::microseconds>(deadline - now).count();
        timeval timeout{static_cast<time_t>(remaining / 1000000),
                        static_cast<suseconds_t>(remaining % 1000000)};
        fd_set input;
        FD_ZERO(&input);
        FD_SET(STDIN_FILENO, &input);
        if (select(STDIN_FILENO + 1, &input, nullptr, nullptr, &timeout) > 0) {
            char key = 0;
            if (read(STDIN_FILENO, &key, 1) != 1)
                continue;
            if (key != 27)
                return static_cast<unsigned char>(key);
            // Arrow and function keys arrive as ESC-prefixed sequences; swallow those so only
            // a lone Esc is reported.
            timeval brief{0, 10000};
            FD_ZERO(&input);
            FD_SET(STDIN_FILENO, &input);
            if (select(STDIN_FILENO + 1, &input, nullptr, nullptr, &brief) <= 0)
                return 27;
            char sequence[32];
            (void)read(STDIN_FILENO, sequence, sizeof(sequence));
            return 0;
        }
    }
    return 0;
}

struct State {
    double interval = 1;
    std::string sort = "cpu";
    std::uint64_t ram = 0;
    monitor::Snapshot before, after;
    std::vector<monitor::CpuCore> cores_before, cores_after;
    std::vector<monitor::Gpu> gpus;
    monitor::Memory memory;
    std::string filter;   // case-insensitive name or PID substring
    bool editing = false; // keystrokes go to the filter instead of commands
};

void sample(State &state) {
    state.before = std::move(state.after);
    state.cores_before = std::move(state.cores_after);
    state.after = monitor::collect_processes();
    state.cores_after = monitor::collect_cpu_cores();
    state.memory = monitor::collect_memory();
    state.gpus = monitor::collect_gpus();
}

void add_cpu(std::vector<std::string> &lines, const State &state, int width) {
    std::vector<std::optional<monitor::CoreUsage>> usages;
    double busy = 0;
    int counted = 0;
    for (const auto &core : state.cores_after) {
        const auto previous =
            std::find_if(state.cores_before.begin(), state.cores_before.end(),
                         [&](const auto &p) { return p.id == core.id; });
        usages.push_back(previous == state.cores_before.end()
                             ? std::nullopt
                             : monitor::core_usage(*previous, core));
        if (usages.back()) {
            busy += usages.back()->busy;
            ++counted;
        }
    }
    const auto total = counted ? std::optional<double>(busy / counted) : std::nullopt;
    lines.push_back(bold + " CPU  " + reset + gauge(total.value_or(0), std::max(10, width - 16)) +
                    " " + render::pad_left(percent_text(total), 6));
    const int cols = std::max(1, (width - 1) / 30);
    const int bar_width = std::max(4, (width - 1) / cols - 12);
    std::string line;
    for (std::size_t i = 0; i < usages.size(); ++i) {
        const auto value = usages[i] ? std::optional<double>(usages[i]->busy) : std::nullopt;
        line += " " + dim + render::pad_left(std::to_string(state.cores_after[i].id), 3) + reset +
                " " + gauge(value.value_or(0), bar_width) + " " +
                render::pad_left(percent_text(value), 6);
        if ((i + 1) % static_cast<std::size_t>(cols) == 0 || i + 1 == usages.size()) {
            lines.push_back(line);
            line.clear();
        }
    }
}

void add_memory(std::vector<std::string> &lines, const State &state, int width) {
    const auto &m = state.memory;
    const double used = m.total ? 100.0 * m.used / m.total : 0;
    lines.push_back(bold + " MEM  " + reset + gauge(used, std::max(10, width - 30)) + " " +
                    render::human(m.used) + " / " + render::human(m.total));
    std::string detail = "      app " + render::human(m.app) + " · wired " +
                         render::human(m.wired) + " · compressed " + render::human(m.compressed) +
                         " · cached " + render::human(m.cached);
    if (m.swap_total)
        detail += " · swap " + render::human(m.swap_used) + " / " + render::human(m.swap_total);
    lines.push_back(dim + detail + reset);
}

void add_gpus(std::vector<std::string> &lines, const State &state, int width) {
    if (state.gpus.empty())
        lines.push_back(bold + " GPU  " + reset + dim + "N/A (driver statistics unavailable)" +
                        reset);
    for (const auto &gpu : state.gpus) {
        std::string detail = render::printable(gpu.name);
        if (gpu.core_count)
            detail += " · " + render::fixed(*gpu.core_count, 0) + " cores";
        detail += " · renderer " + percent_text(gpu.renderer) + " · tiler " +
                  percent_text(gpu.tiler);
        if (gpu.used_bytes)
            detail += " · mem " + render::human(*gpu.used_bytes);
        lines.push_back(bold + " GPU  " + reset +
                        gauge(gpu.utilization.value_or(0), std::max(10, width - 16)) + " " +
                        render::pad_left(percent_text(gpu.utilization), 6));
        lines.push_back(dim + "      " + detail + reset);
    }
}

void add_processes(std::vector<std::string> &lines, const State &state, int width, int rows) {
    struct Row {
        const monitor::Process *process;
        std::optional<double> cpu;
    };
    std::unordered_map<int, const monitor::Process *> previous;
    for (const auto &p : state.before.processes)
        previous.emplace(p.pid, &p);
    std::vector<Row> table;
    for (const auto &p : state.after.processes) {
        if (!render::matches(p.name, p.pid, state.filter))
            continue;
        const auto it = previous.find(p.pid);
        table.push_back(
            {&p, it == previous.end() ? std::nullopt : monitor::cpu_percent(*it->second, p)});
    }
    std::sort(table.begin(), table.end(), [&](const Row &a, const Row &b) {
        if (state.sort == "mem" && a.process->resident_bytes != b.process->resident_bytes)
            return a.process->resident_bytes > b.process->resident_bytes;
        if (state.sort == "cpu" && a.cpu.value_or(-1) != b.cpu.value_or(-1))
            return a.cpu.value_or(-1) > b.cpu.value_or(-1);
        return a.process->pid < b.process->pid;
    });
    constexpr int fixed_width = 44;
    const auto name_width = static_cast<std::size_t>(std::max(0, width - fixed_width));
    const std::string header = render::pad_left("PID", 7) + " " + render::pad_left("CPU%", 6) +
                               " " + render::fit("", 10) + " " + render::pad_left("RAM MiB", 9) +
                               " " + render::pad_left("RAM%", 6) + "  NAME";
    lines.push_back(inverse + render::fit(header, static_cast<std::size_t>(width)) + reset);
    if (table.empty() && !state.filter.empty())
        lines.push_back(dim + "  no processes match \"" + render::printable(state.filter) + "\"" +
                        reset);
    constexpr double mib = 1024.0 * 1024.0;
    for (int i = 0; i < rows - 1 && i < static_cast<int>(table.size()); ++i) {
        const auto &row = table[static_cast<std::size_t>(i)];
        const auto &p = *row.process;
        const double ram = state.ram ? 100.0 * p.resident_bytes / state.ram : 0;
        lines.push_back(render::pad_left(std::to_string(p.pid), 7) + " " +
                        render::pad_left(percent_text(row.cpu), 6) + " " +
                        gauge(row.cpu.value_or(0), 10) + " " +
                        render::pad_left(render::fixed(p.resident_bytes / mib), 9) + " " +
                        render::pad_left(render::fixed(ram) + "%", 6) + "  " +
                        highlight(render::fit(render::printable(p.name), name_width),
                                  state.filter));
    }
}

std::string draw(const State &state) {
    const auto [width, height] = Terminal::size();
    std::vector<std::string> lines;
    std::string count = std::to_string(state.after.processes.size()) + " processes";
    if (!state.filter.empty()) {
        const auto shown = std::count_if(
            state.after.processes.begin(), state.after.processes.end(),
            [&](const auto &p) { return render::matches(p.name, p.pid, state.filter); });
        count = std::to_string(shown) + "/" + count;
    }
    lines.push_back(bold + " resource-visualizer" + reset + dim + "  " +
                    std::to_string(state.cores_after.size()) + " cores · " +
                    render::human(static_cast<double>(state.ram)) + " RAM · every " +
                    render::fixed(state.interval, 2) + "s · sort " + state.sort + " · " + count +
                    reset);
    const auto query = render::printable(state.filter);
    if (state.editing)
        lines.push_back(bold + " Filter: " + reset + query + inverse + " " + reset + dim +
                        "  Enter keep · Esc clear · Ctrl+U erase" + reset);
    else if (!state.filter.empty())
        lines.push_back(" Filter: " + bold + query + reset + dim +
                        "  / edit · Esc clear · q quit · c/m/p sort · +/- interval" + reset);
    else
        lines.push_back(dim + " q quit · / filter · c/m/p sort by cpu/mem/pid · +/- interval" +
                        reset);
    lines.emplace_back();
    add_cpu(lines, state, width);
    lines.emplace_back();
    add_memory(lines, state, width);
    add_gpus(lines, state, width);
    lines.emplace_back();
    add_processes(lines, state, width, height - static_cast<int>(lines.size()));
    std::string frame = "\x1b[H";
    for (int i = 0; i < height && i < static_cast<int>(lines.size()); ++i)
        frame += (i ? "\r\n" : "") + lines[static_cast<std::size_t>(i)] + "\x1b[K";
    return frame + "\x1b[J";
}

// Returns true when the refresh interval changed.
bool handle_key(State &state, int key) {
    if (state.editing) {
        if (key == '\n' || key == '\r')
            state.editing = false;
        else if (key == 27) {
            state.editing = false;
            state.filter.clear();
        } else if (key == 127 || key == 8)
            render::pop_char(state.filter);
        else if (key == 21) // Ctrl+U
            state.filter.clear();
        else if (key >= 32) // printable ASCII and UTF-8 bytes
            state.filter += static_cast<char>(key);
        return false;
    }
    switch (key) {
    case '/':
        state.editing = true;
        return false;
    case 27:
        state.filter.clear();
        return false;
    case 'q':
    case 'Q':
        stopped = 1;
        return false;
    case 'c':
        state.sort = "cpu";
        return false;
    case 'm':
        state.sort = "mem";
        return false;
    case 'p':
        state.sort = "pid";
        return false;
    case '+':
    case '=':
        for (double step : intervals)
            if (step > state.interval) {
                state.interval = step;
                return true;
            }
        return false;
    case '-':
        for (auto it = std::rbegin(intervals); it != std::rend(intervals); ++it)
            if (*it < state.interval) {
                state.interval = *it;
                return true;
            }
        return false;
    default:
        return false;
    }
}

Clock::duration seconds(double value) {
    return std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(value));
}
} // namespace

int main(int argc, char **argv) {
    try {
        State state;
        for (int i = 1; i < argc; ++i) {
            const std::string flag = argv[i];
            if (flag == "--help") {
                std::cout << "Usage: resource-visualizer [--interval SECONDS] [--sort cpu|mem|pid]\n"
                             "Live terminal view of CPU cores, memory, GPU, and processes.\n"
                             "Keys: q quit, c/m/p sort, +/- change interval.\n";
                return 0;
            }
            if (i + 1 == argc)
                throw std::invalid_argument("Missing value for " + flag);
            const std::string value = argv[++i];
            if (flag == "--interval") {
                std::size_t end;
                state.interval = std::stod(value, &end);
                if (end != value.size() || !std::isfinite(state.interval) ||
                    state.interval < 0.1 || state.interval > 3600)
                    throw std::invalid_argument("Interval must be between 0.1 and 3600 seconds");
            } else if (flag == "--sort") {
                if (value != "cpu" && value != "mem" && value != "pid")
                    throw std::invalid_argument("Sort must be cpu, mem, or pid");
                state.sort = value;
            } else
                throw std::invalid_argument("Unknown option: " + flag);
        }
        if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO))
            throw std::runtime_error("An interactive terminal is required");
        // No SA_RESTART, so signals interrupt select() and the loop reacts immediately.
        struct sigaction action {};
        action.sa_handler = stop;
        sigaction(SIGINT, &action, nullptr);
        sigaction(SIGTERM, &action, nullptr);
        action.sa_handler = resize;
        sigaction(SIGWINCH, &action, nullptr);

        state.ram = monitor::physical_memory();
        sample(state);
        state.before = state.after;
        state.cores_before = state.cores_after;
        Terminal terminal;
        write_all(draw(state));
        auto next = Clock::now() + seconds(state.interval);
        while (!stopped) {
            const int key = wait_key(next);
            if (stopped)
                break;
            bool redraw = resized != 0;
            resized = 0;
            if (key) {
                if (handle_key(state, key))
                    next = Clock::now() + seconds(state.interval);
                redraw = true;
            }
            if (Clock::now() >= next) {
                sample(state);
                next += seconds(state.interval);
                if (next < Clock::now()) // fell behind; don't burst-sample to catch up
                    next = Clock::now() + seconds(state.interval);
                redraw = true;
            }
            if (redraw && !stopped)
                write_all(draw(state));
        }
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "resource-visualizer: " << error.what() << '\n';
        return 1;
    }
}
