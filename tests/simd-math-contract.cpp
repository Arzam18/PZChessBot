#include <array>
#include <cassert>
#include <cstdint>
#include <iostream>
#include <limits>
#include <random>

static int32_t dot_u8_s8_scalar(const uint8_t* a, const int8_t* b, int32_t accumulator) {
    int64_t sum = accumulator;
    for (int i = 0; i < 4; ++i)
        sum += static_cast<int32_t>(a[i]) * static_cast<int32_t>(b[i]);
    assert(sum >= std::numeric_limits<int32_t>::min());
    assert(sum <= std::numeric_limits<int32_t>::max());
    return static_cast<int32_t>(sum);
}

// Algebra used by the ARMv8.2-A SDOT path:
// u8 = (u8 interpreted as signed after XOR 0x80) + 128.
static int32_t dot_u8_s8_sdot_identity(
    const uint8_t* a, const int8_t* b, int32_t accumulator) {
    int64_t signed_dot = accumulator;
    int64_t correction_sum = 0;
    for (int i = 0; i < 4; ++i) {
        const int16_t rebased_a = static_cast<int16_t>(a[i]) - 128;
        signed_dot += static_cast<int32_t>(rebased_a) * static_cast<int32_t>(b[i]);
        correction_sum += b[i];
    }
    const int64_t corrected = signed_dot + correction_sum * 128;
    assert(corrected >= std::numeric_limits<int32_t>::min());
    assert(corrected <= std::numeric_limits<int32_t>::max());
    return static_cast<int32_t>(corrected);
}

static int16_t rounded_mulhi_reference(uint8_t a, uint8_t b) {
    // Equivalent to signed saturating rounded doubling multiply-high after
    // the first operand has been shifted left by seven bits.
    const int32_t lhs = static_cast<int32_t>(a) << 7;
    const int32_t rounded = (lhs * static_cast<int32_t>(b) + 0x4000) >> 15;
    if (rounded > 32767) return 32767;
    if (rounded < -32768) return -32768;
    return static_cast<int16_t>(rounded);
}

int main() {
    // Exercise both the signed-rebias correction and all SIMD four-byte lanes.
    std::mt19937 rng(0x505A4348u);
    std::uniform_int_distribution<int> u8dist(0, 255);
    std::uniform_int_distribution<int> s8dist(-128, 127);
    std::uniform_int_distribution<int32_t> accdist(-1000000, 1000000);

    std::array<uint8_t, 16> a{};
    std::array<int8_t, 16> b{};
    for (int group = 0; group < 4; ++group) {
        a[group] = 0;       b[group] = -128;
        a[group + 4] = 255; b[group + 4] = 127;
        a[group + 8] = 128; b[group + 8] = -1;
        a[group + 12] = 1;  b[group + 12] = 1;
    }
    for (int lane = 0; lane < 4; ++lane) {
        const int32_t initial = lane * 12345;
        assert(dot_u8_s8_scalar(&a[lane * 4], &b[lane * 4], initial) ==
               dot_u8_s8_sdot_identity(&a[lane * 4], &b[lane * 4], initial));
    }

    constexpr int kIterations = 1000000;
    for (int iteration = 0; iteration < kIterations; ++iteration) {
        for (int i = 0; i < 16; ++i) {
            a[i] = static_cast<uint8_t>(u8dist(rng));
            b[i] = static_cast<int8_t>(s8dist(rng));
        }
        for (int lane = 0; lane < 4; ++lane) {
            const int32_t initial = accdist(rng);
            const auto* ap = a.data() + lane * 4;
            const auto* bp = b.data() + lane * 4;
            assert(dot_u8_s8_scalar(ap, bp, initial) ==
                   dot_u8_s8_sdot_identity(ap, bp, initial));
        }
    }

    // The paired activation multiply is only called with clipped unsigned
    // values in [0, 255]. Verify the fixed-point rounding for the full domain.
    for (int av = 0; av <= 255; ++av) {
        for (int bv = 0; bv <= 255; ++bv) {
            const int16_t value = rounded_mulhi_reference(
                static_cast<uint8_t>(av), static_cast<uint8_t>(bv));
            assert(value >= 0 && value <= 255);
        }
    }

    std::cout << "PASS: SDOT unsigned-input correction (1,000,000 random groups)\n";
    std::cout << "PASS: fixed-point rounded multiply-high domain (65,536 pairs)\n";
}
