#include "http.hpp"
#include "index_html.hpp"
#include "monitor.hpp"
#include "render.hpp"

#include <arpa/inet.h>
#include <cerrno>
#include <cmath>
#include <csignal>
#include <cstring>
#include <deque>
#include <iostream>
#include <netinet/in.h>
#include <stdexcept>
#include <string>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;
volatile std::sig_atomic_t stopped = 0;
void stop(int) { stopped = 1; }
constexpr std::size_t history_length = 120;

// Samples per-core counters on a fixed cadence and keeps a rolling busy-% history per core.
struct Sampler {
    std::vector<monitor::CoreTopology> topology;
    std::vector<monitor::CpuCore> previous;
    std::vector<std::optional<monitor::CoreUsage>> current;
    std::vector<std::deque<std::optional<double>>> history;
    std::uint64_t samples = 0;

    void sample() {
        auto cores = monitor::collect_cpu_cores();
        current.assign(cores.size(), std::nullopt);
        history.resize(cores.size());
        for (std::size_t i = 0; i < cores.size(); ++i) {
            if (i < previous.size())
                current[i] = monitor::core_usage(previous[i], cores[i]);
            history[i].push_back(current[i] ? std::optional<double>(current[i]->busy)
                                            : std::nullopt);
            if (history[i].size() > history_length)
                history[i].pop_front();
        }
        previous = std::move(cores);
        ++samples;
    }
};

std::string number(std::optional<double> value) {
    return value ? render::fixed(*value) : "null";
}

std::string stats_json(const Sampler &sampler, double interval) {
    std::string out = "{\"interval\":" + render::fixed(interval, 2) +
                      ",\"samples\":" + std::to_string(sampler.samples) +
                      ",\"capacity\":" + std::to_string(history_length) + ",\"cores\":[";
    for (std::size_t i = 0; i < sampler.previous.size(); ++i) {
        const auto id = sampler.previous[i].id;
        char type = '?';
        int cluster = -1;
        for (const auto &t : sampler.topology)
            if (t.id == id) {
                type = t.type;
                cluster = t.cluster;
            }
        const auto &usage = sampler.current[i];
        const auto field = [&](double monitor::CoreUsage::*member) {
            return number(usage ? std::optional<double>((*usage).*member) : std::nullopt);
        };
        out += std::string(i ? "," : "") + "{\"id\":" + std::to_string(id) + ",\"type\":" +
               (type == '?' ? "null" : std::string("\"") + type + "\"") +
               ",\"cluster\":" + (cluster < 0 ? "null" : std::to_string(cluster)) +
               ",\"busy\":" + field(&monitor::CoreUsage::busy) +
               ",\"user\":" + field(&monitor::CoreUsage::user) +
               ",\"system\":" + field(&monitor::CoreUsage::system) +
               ",\"nice\":" + field(&monitor::CoreUsage::nice) +
               ",\"idle\":" + field(&monitor::CoreUsage::idle) + "}";
    }
    out += "],\"history\":[";
    for (std::size_t i = 0; i < sampler.history.size(); ++i) {
        out += i ? ",[" : "[";
        for (std::size_t j = 0; j < sampler.history[i].size(); ++j)
            out += (j ? "," : "") + number(sampler.history[i][j]);
        out += "]";
    }
    return out + "]}";
}

void send_all(int socket, const std::string &data) {
    std::size_t offset = 0;
    while (offset < data.size()) {
        const auto sent = ::send(socket, data.data() + offset, data.size() - offset, 0);
        if (sent < 0) {
            if (errno == EINTR)
                continue;
            return;
        }
        offset += static_cast<std::size_t>(sent);
    }
}

void serve(int client, const Sampler &sampler, double interval) {
    // Bound how long one slow client can stall the single-threaded loop.
    timeval timeout{1, 0};
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int one = 1;
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    std::string request;
    char buffer[2048];
    while (request.find("\r\n\r\n") == std::string::npos && request.size() < 8192) {
        const auto received = recv(client, buffer, sizeof(buffer), 0);
        if (received <= 0)
            break;
        request.append(buffer, static_cast<std::size_t>(received));
    }
    const auto path = http::get_path(request);
    if (path == "/" || path == "/index.html")
        send_all(client, http::response("200 OK", "text/html; charset=utf-8", web::index_html));
    else if (path == "/api/stats")
        send_all(client, http::response("200 OK", "application/json", stats_json(sampler, interval)));
    else
        send_all(client, http::response("404 Not Found", "text/plain", "Not found\n"));
}

Clock::duration seconds(double value) {
    return std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(value));
}
} // namespace

int main(int argc, char **argv) {
    int server = -1;
    try {
        double interval = 1;
        int port = 8765;
        for (int i = 1; i < argc; ++i) {
            const std::string flag = argv[i];
            if (flag == "--help") {
                std::cout << "Usage: resource-web [--port N] [--interval SECONDS]\n"
                             "Serves a live per-core CPU dashboard on http://127.0.0.1:PORT\n"
                             "Defaults: port 8765, interval 1 (0.25-10).\n";
                return 0;
            }
            if (i + 1 == argc)
                throw std::invalid_argument("Missing value for " + flag);
            const std::string value = argv[++i];
            std::size_t end;
            if (flag == "--interval") {
                interval = std::stod(value, &end);
                if (end != value.size() || !std::isfinite(interval) || interval < 0.25 ||
                    interval > 10)
                    throw std::invalid_argument("Interval must be between 0.25 and 10 seconds");
            } else if (flag == "--port") {
                const long parsed = std::stol(value, &end);
                if (end != value.size() || parsed < 1 || parsed > 65535)
                    throw std::invalid_argument("Port must be between 1 and 65535");
                port = static_cast<int>(parsed);
            } else
                throw std::invalid_argument("Unknown option: " + flag);
        }
        // No SA_RESTART, so Ctrl+C interrupts select() immediately.
        struct sigaction action {};
        action.sa_handler = stop;
        sigaction(SIGINT, &action, nullptr);
        sigaction(SIGTERM, &action, nullptr);
        std::signal(SIGPIPE, SIG_IGN);

        Sampler sampler;
        sampler.topology = monitor::collect_core_topology();
        sampler.sample();

        server = socket(AF_INET, SOCK_STREAM, 0);
        if (server < 0)
            throw std::runtime_error(std::string("socket: ") + std::strerror(errno));
        int one = 1;
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_port = htons(static_cast<std::uint16_t>(port));
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // never exposed beyond this machine
        if (bind(server, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0)
            throw std::runtime_error("Cannot listen on port " + std::to_string(port) + ": " +
                                     std::strerror(errno));
        if (listen(server, 16) != 0)
            throw std::runtime_error(std::string("listen: ") + std::strerror(errno));
        std::cout << "Serving http://127.0.0.1:" << port << " (Ctrl+C to stop)" << std::endl;

        auto next = Clock::now() + seconds(interval);
        while (!stopped) {
            const auto now = Clock::now();
            const auto remaining = std::chrono::duration_cast<std::chrono::microseconds>(
                                       std::max(next - now, Clock::duration::zero()))
                                       .count();
            timeval timeout{static_cast<time_t>(remaining / 1000000),
                            static_cast<suseconds_t>(remaining % 1000000)};
            fd_set ready;
            FD_ZERO(&ready);
            FD_SET(server, &ready);
            if (select(server + 1, &ready, nullptr, nullptr, &timeout) > 0) {
                const int client = accept(server, nullptr, nullptr);
                if (client >= 0) {
                    serve(client, sampler, interval);
                    close(client);
                }
            }
            if (Clock::now() >= next) {
                sampler.sample();
                next += seconds(interval);
                if (next < Clock::now()) // fell behind; don't burst-sample to catch up
                    next = Clock::now() + seconds(interval);
            }
        }
        close(server);
        return 0;
    } catch (const std::exception &error) {
        if (server >= 0)
            close(server);
        std::cerr << "resource-web: " << error.what() << '\n';
        return 1;
    }
}
