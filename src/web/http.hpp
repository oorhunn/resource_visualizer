#pragma once

#include <string>

// Minimal HTTP/1.1 helpers for the local dashboard server; kept pure for unit tests.
namespace http {
// Path of a GET request line without its query string; empty for anything else.
inline std::string get_path(const std::string &request) {
    const std::string line = request.substr(0, request.find("\r\n"));
    if (line.rfind("GET ", 0) != 0)
        return {};
    const auto space = line.find(' ', 4);
    if (space == std::string::npos)
        return {};
    auto path = line.substr(4, space - 4);
    const auto query = path.find('?');
    if (query != std::string::npos)
        path.resize(query);
    return path;
}

inline std::string response(const std::string &status, const std::string &type,
                            const std::string &body) {
    return "HTTP/1.1 " + status + "\r\nContent-Type: " + type +
           "\r\nContent-Length: " + std::to_string(body.size()) +
           "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" + body;
}
} // namespace http
