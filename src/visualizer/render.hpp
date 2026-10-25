#pragma once

#include <cstdio>
#include <string>

// Pure text helpers, kept free of terminal I/O so they can be unit tested.
namespace render {
// Horizontal bar exactly `width` cells wide; eighth-block glyphs give sub-cell resolution.
inline std::string bar(double percent, int width) {
    static const char *const partial[] = {"", "▏", "▎", "▍", "▌", "▋", "▊", "▉"};
    if (width <= 0)
        return {};
    if (!(percent > 0)) // also rejects NaN
        percent = 0;
    if (percent > 100)
        percent = 100;
    const int eighths = static_cast<int>(percent / 100.0 * width * 8 + 0.5);
    std::string out;
    int cells = 0;
    for (; cells < eighths / 8; ++cells)
        out += "█";
    if (eighths % 8 && cells < width) {
        out += partial[eighths % 8];
        ++cells;
    }
    out.append(static_cast<std::size_t>(width - cells), ' ');
    return out;
}

// 0 = normal, 1 = elevated, 2 = high.
inline int level(double percent) { return percent >= 80 ? 2 : percent >= 50 ? 1 : 0; }

inline std::size_t columns(const std::string &text) {
    std::size_t count = 0;
    for (unsigned char c : text)
        if ((c & 0xC0) != 0x80)
            ++count;
    return count;
}

// Truncates or pads to `width` code points without splitting a UTF-8 sequence.
inline std::string fit(const std::string &text, std::size_t width) {
    std::string out;
    std::size_t count = 0;
    for (std::size_t i = 0; i < text.size(); ++i) {
        const auto c = static_cast<unsigned char>(text[i]);
        if ((c & 0xC0) != 0x80) {
            if (count == width)
                break;
            ++count;
        }
        out += text[i];
    }
    out.append(width - count, ' ');
    return out;
}

inline std::string pad_left(const std::string &text, std::size_t width) {
    const auto used = columns(text);
    return used >= width ? text : std::string(width - used, ' ') + text;
}

inline std::string fixed(double value, int precision = 1) {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.*f", precision, value);
    return buffer;
}

inline std::string human(double bytes) {
    constexpr double mib = 1024.0 * 1024.0;
    if (bytes >= 1024 * mib)
        return fixed(bytes / (1024 * mib)) + " GiB";
    return fixed(bytes / mib, 0) + " MiB";
}

// Byte offset of `needle` in `haystack`, ignoring ASCII case; npos when absent.
inline std::size_t find_ci(const std::string &haystack, const std::string &needle) {
    const auto lower = [](unsigned char c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; };
    if (needle.size() > haystack.size())
        return std::string::npos;
    for (std::size_t i = 0; i + needle.size() <= haystack.size(); ++i) {
        std::size_t j = 0;
        while (j < needle.size() && lower(static_cast<unsigned char>(haystack[i + j])) ==
                                        lower(static_cast<unsigned char>(needle[j])))
            ++j;
        if (j == needle.size())
            return i;
    }
    return std::string::npos;
}

// A process matches when the query appears in its name or its PID.
inline bool matches(const std::string &name, int pid, const std::string &query) {
    return query.empty() || find_ci(name, query) != std::string::npos ||
           std::to_string(pid).find(query) != std::string::npos;
}

// Removes the last UTF-8 character, not just its final byte.
inline void pop_char(std::string &text) {
    while (!text.empty() && (static_cast<unsigned char>(text.back()) & 0xC0) == 0x80)
        text.pop_back();
    if (!text.empty())
        text.pop_back();
}

// Replaces control characters so process names cannot inject escape sequences.
inline std::string printable(std::string text) {
    for (char &c : text)
        if (static_cast<unsigned char>(c) < 32 || static_cast<unsigned char>(c) == 127)
            c = '?';
    return text;
}
} // namespace render
