#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>
#include <utility>
#include <cstdio>

using Image = std::vector<float>;
static size_t elements(int w, int h) {
    if (w <= 0 || h <= 0 || size_t(w) > std::numeric_limits<size_t>::max() / size_t(h) / 4 / sizeof(float))
        throw std::runtime_error("invalid image dimensions");
    return size_t(w) * size_t(h) * 4;
}
static uint32_t mix(uint32_t value) {
    value ^= value >> 16; value *= 0x7feb352dU;
    value ^= value >> 15; value *= 0x846ca68bU;
    return value ^ (value >> 16);
}
static Image generate(int w, int h, uint32_t seed, const std::string& kind) {
    Image out(elements(w, h), 0);
    if (kind != "random" && kind != "black" && kind != "constant" && kind != "center" && kind != "edge")
        throw std::runtime_error("case must be random, black, constant, center or edge");
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
        size_t i = (size_t(y) * w + x) * 4;
        out[i + 3] = 1;
        for (int c = 0; c < 3; ++c) {
            double v = 0;
            if (kind == "constant") v = std::array<double, 3>{2, 1, 0.5}[c];
            if ((kind == "center" && x == w / 2 && y == h / 2) || (kind == "edge" && x == 0 && y == 0))
                v = 8 - 2 * c;
            if (kind == "random") {
                double u = (x + 0.5) / w, t = (y + 0.5) / h;
                double noise = double(mix(seed ^ uint32_t(x) * 0x9e3779b9U ^ uint32_t(y) * 0x85ebca6bU ^ uint32_t(c) * 0xc2b2ae35U) & 0xffffU) / 65535;
                v = 0.04 + 0.38 * u + 0.18 * t + 0.08 * noise;
                for (uint32_t light = 0; light < 4; ++light) {
                    uint32_t a = mix(seed + light * 101 + 17), b = mix(a + 29);
                    double cx = 0.1 + 0.8 * double(a & 0xffffU) / 65535;
                    double cy = 0.1 + 0.8 * double(b & 0xffffU) / 65535;
                    double dx = u - cx, dy = t - cy;
                    v += (7.0 - 0.8 * c) * std::exp(-(dx * dx + dy * dy) / (0.002 + light * 0.001));
                }
            }
            out[i + c] = float(std::clamp(v, 0.0, 8.0));
        }
    }
    return out;
}
static Image reference(const Image& input, int w, int h) {
    std::array<double, 31> weights{};
    double sum = 0;
    for (int k = -15; k <= 15; ++k) sum += weights[k + 15] = std::exp(-double(k * k) / 50.0);
    for (auto& value : weights) value /= sum;
    Image horizontal(input.size(), 0), output(input.size(), 0);
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) for (int c = 0; c < 3; ++c) {
        double v = 0;
        for (int k = -15; k <= 15; ++k)
            v += weights[k + 15] * std::max(double(input[(size_t(y) * w + std::clamp(x + k, 0, w - 1)) * 4 + c]) - 1, 0.0);
        horizontal[(size_t(y) * w + x) * 4 + c] = float(v);
    }
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
        size_t i = (size_t(y) * w + x) * 4;
        for (int c = 0; c < 3; ++c) {
            double v = 0;
            for (int k = -15; k <= 15; ++k)
                v += weights[k + 15] * horizontal[(size_t(std::clamp(y + k, 0, h - 1)) * w + x) * 4 + c];
            double combined = input[i + c] + 0.8 * v;
            output[i + c] = float(combined / (1 + combined));
        }
        output[i + 3] = 1;
    }
    return output;
}
static Image read(const std::string& path, int w, int h) {
    Image image(elements(w, h));
    std::ifstream file(path, std::ios::binary);
    if (!file.read(reinterpret_cast<char*>(image.data()), std::streamsize(image.size() * sizeof(float))) || file.peek() != EOF)
        throw std::runtime_error("missing file or wrong RGBA32F byte count: " + path);
    for (float v : image) if (!std::isfinite(v)) throw std::runtime_error("NaN/Inf in " + path);
    return image;
}
static void write(const std::string& path, const Image& image) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file.write(reinterpret_cast<const char*>(image.data()), std::streamsize(image.size() * sizeof(float)));
    file.close();
    if (!file) throw std::runtime_error("cannot write " + path);
}
static void selftest() {
    for (auto size : {std::pair<int,int>{1,1}, {17,13}, {257,129}}) {
        auto [w,h] = size;
        for (auto kind : {"black", "constant"}) {
            auto input = generate(w,h,1,kind), result = reference(input,w,h);
            for (size_t i = 0; i < input.size(); ++i) {
                double c = input[i] + 0.8 * std::max(double(input[i]) - 1, 0.0);
                double expected = i % 4 == 3 ? 1 : c / (1 + c);
                if (std::abs(result[i] - expected) > 1e-6) throw std::runtime_error("analytical reference selftest failed");
            }
        }
        if (generate(w,h,3,"random") != generate(w,h,3,"random")) throw std::runtime_error("generator is not deterministic");
    }
    std::cout << "{\"public_tools_selftest\":\"pass\"}\n";
}
int main(int argc, char** argv) {
    try {
        if (argc == 2 && std::string(argv[1]) == "selftest") { selftest(); return 0; }
        if (argc < 6) throw std::runtime_error("usage: public_tools generate W H SEED CASE OUTPUT | reference W H INPUT OUTPUT | compare W H EXPECTED ACTUAL | selftest");
        std::string op = argv[1]; int w = std::stoi(argv[2]), h = std::stoi(argv[3]);
        elements(w,h);
        if (op == "generate" && argc == 7) write(argv[6], generate(w,h,uint32_t(std::stoul(argv[4])),argv[5]));
        else if (op == "reference" && argc == 6) write(argv[5], reference(read(argv[4],w,h),w,h));
        else if (op == "compare" && argc == 6) {
            auto expected = read(argv[4],w,h), actual = read(argv[5],w,h);
            double rgb = 0, alpha = 0;
            for (size_t i = 0; i < actual.size(); ++i) {
                if (i % 4 == 3) alpha = std::max(alpha, std::abs(double(actual[i]) - 1));
                else rgb = std::max(rgb, std::abs(double(actual[i]) - expected[i]));
            }
            bool pass = rgb <= 0.002 && alpha <= 0.002;
            std::cout << std::setprecision(10) << "{\"max_absolute_rgb_error\":" << rgb << ",\"max_alpha_error\":" << alpha << ",\"pass\":" << (pass ? "true" : "false") << "}\n";
            return pass ? 0 : 2;
        } else throw std::runtime_error("invalid public_tools arguments");
        return 0;
    } catch (const std::exception& error) { std::cerr << "public_tools: " << error.what() << '\n'; return 1; }
}
