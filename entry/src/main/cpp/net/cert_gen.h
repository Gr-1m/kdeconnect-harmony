// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef KDECONNECT_CERT_GEN_H
#define KDECONNECT_CERT_GEN_H

#include <string>
#include <vector>
#include <bearssl.h>
#include <bearssl_ec.h>

namespace kdeconnect {

// 区间内的闰日数（有效期计算用；导出以便单测）
int leapDaysBetween(int startYear, int years);

struct CertPair {
    std::string certPem;
    std::string keyPem;
};

class CertGen {
public:
    static CertPair generateSelfSignedEc(const std::string &deviceId,
                                         int validYears = 10);

private:
    static std::vector<uint8_t> buildSelfSignedCertDer(const std::string &cn,
                                                       const std::vector<uint8_t> &pubKey,
                                                       const br_ec_private_key &sk,
                                                       int validYears);
    static std::string derToPem(const std::vector<uint8_t> &der, const std::string &label);
};

} // namespace kdeconnect

#endif
