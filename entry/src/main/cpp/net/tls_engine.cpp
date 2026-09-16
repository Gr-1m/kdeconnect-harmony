#include "tls_engine.h"

#include "cert_util.h"
#include "net_log.h"
#include <bearssl_pem.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cstring>
#include <cerrno>
#include <thread>
#include <chrono>

namespace kdeconnect {

// X.500 name element OID：2.5.4.3 = id-at-commonName
// （DER 编码 06 03 55 04 03；br_name_element.oid 要求「长度 + 值」，不含 tag 06）
static const unsigned char kOidCommonName[] = { 0x03, 0x55, 0x04, 0x03 };

// 对端证书 subject DN 未知时使用的占位 CA 名（DER，CN=kdeconnect）。
// 目的只是让 num_tas>0 触发 CertificateRequest（bearssl_ssl.h 语义）。
static const unsigned char kPlaceholderCaDn[] = {
    0x30, 0x15,                                            // SEQUENCE (RDNSequence)
    0x31, 0x13,                                            // SET
    0x30, 0x11,                                            // SEQUENCE (AttributeTypeAndValue)
    0x06, 0x03, 0x55, 0x04, 0x03,                          // OID 2.5.4.3 (CN)
    0x0C, 0x0A, 'k',  'd',  'e',  'c',  'o',  'n',  'n',
    'e',  'c',  't'                                        // UTF8String "kdeconnect"
};

// TOFU x509 验证器：复制 br_x509_minimal_vtable 的所有方法，但 end_chain
// 忽略 NOT_TRUSTED 错误（KDE Connect 首次连接不验证自签证书链）。
static unsigned tofu_end_chain(const br_x509_class **ctx)
{
    unsigned err = br_x509_minimal_vtable.end_chain(ctx);
    if (err == BR_ERR_X509_NOT_TRUSTED) {
        auto *cc = reinterpret_cast<br_x509_minimal_context *>(const_cast<br_x509_class **>(ctx));
        cc->err = BR_ERR_X509_OK;
        return 0;
    }
    return err;
}

// ——— 对端证书捕获（REVIEW §8 D2）———
// vtable 回调只拿到「上下文地址」，而 br_x509_minimal_context 是 X509Ctx 的首成员、
// vtable 又是它的首字段，故该地址即 X509Ctx 地址（BearSSL 内部同款 container 转换）。
static X509Ctx *x509Wrap(const br_x509_class **ctx)
{
    return reinterpret_cast<X509Ctx *>(const_cast<br_x509_class **>(ctx));
}

static void capture_start_cert(const br_x509_class **ctx, uint32_t length)
{
    X509Ctx *w = x509Wrap(ctx);
    if (w->certIndex == 0) {
        w->curLen = 0;
        w->overflow = (length > sizeof(w->leafDer));
    }
    br_x509_minimal_vtable.start_cert(ctx, length);
}

static void capture_append(const br_x509_class **ctx, const unsigned char *buf, size_t len)
{
    X509Ctx *w = x509Wrap(ctx);
    if (w->certIndex == 0 && !w->overflow) {
        if (static_cast<size_t>(w->curLen) + len <= sizeof(w->leafDer)) {
            std::memcpy(w->leafDer + w->curLen, buf, len);
            w->curLen += static_cast<uint32_t>(len);
        } else {
            w->overflow = true;
        }
    }
    br_x509_minimal_vtable.append(ctx, buf, len);
}

static void capture_end_cert(const br_x509_class **ctx)
{
    X509Ctx *w = x509Wrap(ctx);
    if (w->certIndex == 0 && !w->overflow) {
        w->leafLen = w->curLen;  // 链首 = EE 证书
    }
    w->certIndex++;
    br_x509_minimal_vtable.end_cert(ctx);
}

// 直通转发：必须写成函数而不是「抄 br_x509_minimal_vtable 的字段值」。
// 抄字段会让本 vtable 变成**动态初始化**对象（字段值来自另一个 TU 的运行期数据），
// 任何在动态初始化之前使用 TlsEngine 的路径（如 host 测试的静态初始化期）都会拿到
// 前两个槽为 0 的 vtable → x509-start-chain 处 call null（已实测复现）。
// 运行期查表转发则让本 vtable 完全静态初始化（.rodata 常量）。
static void capture_start_chain(const br_x509_class **ctx, const char *server_name)
{
    br_x509_minimal_vtable.start_chain(ctx, server_name);
}

static const br_x509_pkey *capture_get_pkey(const br_x509_class *const *ctx, unsigned *usages)
{
    return br_x509_minimal_vtable.get_pkey(ctx, usages);
}

// 捕获 + TOFU（忽略 NOT_TRUSTED）：除 start_chain/get_pkey 直通外，
// 其余钩子在转发给 minimal 实现的同时把 EE 证书原文留在 X509Ctx。
static const br_x509_class capture_x509_vtable = {
    sizeof(br_x509_minimal_context),   // 编译期常量（br_x509_class.context_size）
    capture_start_chain,
    capture_start_cert,
    capture_append,
    capture_end_cert,
    tofu_end_chain,
    capture_get_pkey,
};

TlsEngine::TlsEngine(int fd, TlsRole role)
    : fd_(fd), role_(role)
{
}

TlsEngine::~TlsEngine() = default;

// 对端 EE 证书原始 DER（REVIEW §8 D2）。握手完成后由 capture_* 钩子填充；
// 供 WP-2 证书钉扎与 payload 通道「CN == deviceId」校验使用。
std::vector<uint8_t> TlsEngine::peerLeafCertDer() const
{
    const uint8_t *p = x509Ctx_.leafDer;
    return std::vector<uint8_t>(p, p + x509Ctx_.leafLen);
}

// 对端 EE 证书 subject CN（由 BearSSL 在解析 EE 证书时写入 peerCnBuf_）
std::string TlsEngine::peerCommonName() const
{
    if (peerCnName_.status != 1) {
        return {};
    }
    return std::string(peerCnBuf_);
}

bool TlsEngine::loadCertAndKey(const std::string &certPem, const std::string &keyPem)
{
    // S2（代码评审）：PEM→DER 统一使用 cert_util 的实现（此前本文件另有一份 BearSSL 版，
    // 与此处逻辑重复且行为/边界不一致风险高）。cert_util::pemToDer 已覆盖多对象与 '=' 补齐。
    const std::string certDer = kdeconnect::pemToDer(certPem, "CERTIFICATE");
    if (certDer.empty()) {
        LOGE("failed to parse CERTIFICATE PEM");
        return false;
    }
    certDer_.assign(certDer.begin(), certDer.end());

    std::string keyDer = kdeconnect::pemToDer(keyPem, "EC PRIVATE KEY");
    if (keyDer.empty()) {
        keyDer = kdeconnect::pemToDer(keyPem, "PRIVATE KEY");
    }
    if (keyDer.empty()) {
        LOGE("failed to parse PRIVATE KEY PEM");
        return false;
    }
    keyDer_.assign(keyDer.begin(), keyDer.end());

    br_skey_decoder_context skeyDec;
    br_skey_decoder_init(&skeyDec);
    br_skey_decoder_push(&skeyDec, keyDer_.data(), keyDer_.size());
    int skeyErr = br_skey_decoder_last_error(&skeyDec);
    if (skeyErr != 0) {
        LOGE("failed to decode EC private key: %d", skeyErr);
        return false;
    }
    const br_ec_private_key *ec = br_skey_decoder_get_ec(&skeyDec);
    if (ec == nullptr) {
        LOGE("private key is not EC");
        return false;
    }
    // ec->x 指向 skeyDec 内部 key_data 缓冲，而 skeyDec 是局部变量，
    // 本函数返回后即失效；把私钥标量拷入成员 ecKeyData_ 长期持有，
    // 否则握手做 ECDSA 签名时会 use-after-free（段错误/握手卡死）。
    ecKeyData_.assign(ec->x, ec->x + ec->xlen);
    ecKey_ = *ec;
    ecKey_.x = ecKeyData_.data();
    return true;
}

bool TlsEngine::init(const std::string &certPem, const std::string &keyPem,
                     const ServerClientAuth *clientAuth)
{
    if (!loadCertAndKey(certPem, keyPem)) {
        return false;
    }

    // 注意：chain 数据来自 certDer_（成员，长期有效），且结构体本身必须是
    // 成员 certChain_ —— 引擎只存指针，若用局部变量，init() 返回后
    // ssl_hs_server 发 ServerHello 时会 use-after-return（ASan 已实锤）。
    certChain_.data = certDer_.data();
    certChain_.data_len = certDer_.size();

    if (role_ == TlsRole::Server) {
        br_ssl_server_init_full_ec(&serverCtx_, &certChain_, 1, BR_KEYTYPE_EC, &ecKey_);

        if (clientAuth != nullptr) {
            // P0-2：server 端启用客户端证书认证（对等 KDE CompositeUploadJob::configureSslSocket
            // 的 VerifyPeer + Android SslHelper 的 needClientAuth=true）。
            //
            // ① 引擎必须先装 *验证* 实现：CertificateRequest 的算法列表由
            //    supports-rsa-sign?(ENG->irsavrfy) / supports-ecdsa?(ENG->iecdsa) 决定
            //    （ssl_hs_server.t0 write-list-signhash）。纯 EC 的 full_ec 初始化只把签名
            //    实现放进 *policy*（ssl_scert_single_ec.c:140），eng->iecdsa 仍为 NULL →
            //    证书请求里不含 ECDSA → Qt/OpenSSL 客户端回空 Certificate →
            //    server 端 ERR_NO_CLIENT_AUTH(29)。host 实验已实证（MSG59）。
            //    这两个 impl 仅用于校验（本机证书签名走 policy 上下文），不冲突。
            br_ssl_engine_set_default_rsavrfy(&serverCtx_.eng);
            br_ssl_engine_set_default_ecdsa(&serverCtx_.eng);

            // ② x509 验证器：自签对端证书无锚 → 沿用 client 侧同款 TOFU vtable
            //    （end_chain 忽略 NOT_TRUSTED），同时捕获 EE 证书原文与 subject CN。
            br_x509_minimal_init_full(&x509Ctx_.x509, nullptr, 0);
            x509Ctx_.x509.vtable = &capture_x509_vtable;
            peerCnName_.oid = kOidCommonName;
            peerCnName_.buf = peerCnBuf_;
            peerCnName_.len = sizeof(peerCnBuf_);
            peerCnName_.status = 0;
            br_x509_minimal_set_name_elements(&x509Ctx_.x509, &peerCnName_, 1);
            br_ssl_engine_set_x509(&serverCtx_.eng, &x509Ctx_.x509.vtable);

            // ③ 触发 CertificateRequest：num_tas>0 才发（bearssl_ssl.h 文档）。
            //    CA 名用对端证书 subject DN（KDE/Android 同款语义）；未知时用占位名——
            //    Qt/OpenSSL 客户端不按 CA 列表过滤（host 实测 ca=bogus 仍出示证书），
            //    但 Java(SunJSSE) 会过滤，故未知场景仅作降级。
            clientCaDn_ = clientAuth->caDnDer.empty() ? std::vector<uint8_t>(kPlaceholderCaDn,
                                                                            kPlaceholderCaDn + sizeof(kPlaceholderCaDn))
                                                      : clientAuth->caDnDer;
            clientCaName_.data = clientCaDn_.data();
            clientCaName_.len = clientCaDn_.size();
            br_ssl_server_set_trust_anchor_names(&serverCtx_, &clientCaName_, 1);
            if (clientAuth->tolerateNoCert) {
                br_ssl_engine_add_flags(&serverCtx_.eng, BR_OPT_TOLERATE_NO_CLIENT_AUTH);
            }
            LOGI("tls server client-auth: caDn=%zu bytes, tolerate=%d",
                 clientCaDn_.size(), clientAuth->tolerateNoCert ? 1 : 0);
        }
        engine_ = &serverCtx_.eng;
    } else {
        // 客户端：装信任锚（此处为空，TOFU 由 capture_x509_vtable 的 end_chain 兜底）
        br_ssl_client_init_full(&clientCtx_, &x509Ctx_.x509, nullptr, 0);

        // 对端 EE 证书捕获 + subject CN 收集（REVIEW §8 D2）：
        // 必须在上面的 init_full 之后设置——init_full 内部会把 vtable 重置成 minimal 版。
        x509Ctx_.x509.vtable = &capture_x509_vtable;
        peerCnName_.oid = kOidCommonName;
        peerCnName_.buf = peerCnBuf_;
        peerCnName_.len = sizeof(peerCnBuf_);
        peerCnName_.status = 0;
        br_x509_minimal_set_name_elements(&x509Ctx_.x509, &peerCnName_, 1);

        // 客户端证书（REVIEW §8 D1）：KDE/Android 的 payload server 用 VerifyPeer，
        // 会要求本机出示证书；不装则握手被拒。自签证书 issuer = 自身（EC）。
        br_ssl_client_set_single_ec(&clientCtx_, &certChain_, 1, &ecKey_,
                                    BR_KEYTYPE_KEYX | BR_KEYTYPE_SIGN, BR_KEYTYPE_EC,
                                    br_ec_get_default(), br_ecdsa_sign_asn1_get_default());
        engine_ = &clientCtx_.eng;
    }

    br_ssl_engine_set_buffer(engine_, iobuf_, sizeof(iobuf_), 1);

    if (role_ == TlsRole::Server) {
        br_ssl_server_reset(&serverCtx_);
    } else {
        br_ssl_client_reset(&clientCtx_, nullptr, 0);
    }

    LOGI("tls engine init: role=%s cert=%zu bytes",
         role_ == TlsRole::Server ? "server" : "client",
         certDer_.size());
    return true;
}

int TlsEngine::runUntil(unsigned target)
{
    // P0-a（根因）：本循环原先在「引擎无任何可推进状态」时会 flush→continue 空转
    // （state 不变 ⇒ 死循环烧满一个核；真机实测单次迭代 ≈5.4s CPU，见 DevEco MSG160 §1.2）。
    // 三道防御：① 停摆（state 四位全不命中）立即返回；② flush 后状态未变 ⇒ 无进展返回；
    // ③ 迭代上限兜底，任何病态路径都不再占满 CPU。
    constexpr unsigned kMaxDrives = 4096;
    unsigned drives = 0;
    for (;;) {
        if (++drives > kMaxDrives) {
            LOGI("tls runUntil: drive guard hit (target=0x%x) — 无进展，按暂不可用返回", target);
            return 0;
        }
        unsigned state = br_ssl_engine_current_state(engine_);
        if (state & BR_SSL_CLOSED) {
            int err = br_ssl_engine_last_error(engine_);
            if (err != 0) {
                lastError_ = err;
                LOGE("tls engine closed with error: %d", err);
            }
            return -1;
        }

        if (state & BR_SSL_SENDREC) {
            size_t len;
            unsigned char *buf = br_ssl_engine_sendrec_buf(engine_, &len);
            ssize_t wlen = ::send(fd_, buf, len, MSG_NOSIGNAL);
            if (wlen < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
                lastError_ = errno;
                engine_->err = BR_ERR_IO;
                return -1;
            }
            if (wlen == 0) {
                lastError_ = EPIPE;
                engine_->err = BR_ERR_IO;
                return -1;
            }
            br_ssl_engine_sendrec_ack(engine_, static_cast<size_t>(wlen));
            continue;
        }

        if (state & target) {
            return 1;
        }

        if (state & BR_SSL_RECVAPP) {
            // 应用数据已在引擎缓冲里（只有 write 路径会走到这里：target=SENDAPP
            // 与 RECVAPP 互斥，无法原地接收新数据）。不能当错误返回，把数据
            // 移到 pendingApp_ 供 read() 后续取出，然后继续推进状态机。
            size_t len;
            unsigned char *appBuf = br_ssl_engine_recvapp_buf(engine_, &len);
            pendingApp_.insert(pendingApp_.end(), appBuf, appBuf + len);
            br_ssl_engine_recvapp_ack(engine_, len);
            br_ssl_engine_flush(engine_, 0);
            continue;
        }

        if (state & BR_SSL_RECVREC) {
            size_t len;
            unsigned char *buf = br_ssl_engine_recvrec_buf(engine_, &len);
            ssize_t rlen = ::recv(fd_, buf, len, 0);
            if (rlen < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
                lastError_ = errno;
                engine_->err = BR_ERR_IO;
                return -1;
            }
            if (rlen == 0) {
                lastError_ = EPIPE;
                engine_->err = BR_ERR_IO;
                return -1;
            }
            br_ssl_engine_recvrec_ack(engine_, static_cast<size_t>(rlen));
            continue;
        }

        // 兜底：既无可读写缓冲区（SENDAPP/RECVAPP/SENDREC/RECVREC 全不命中）、target 又未满足
        // ⇒ 引擎停摆，交回调用方等下次事件/tick。原实现此处 br_ssl_engine_flush + continue，
        // state 不变时即无限空转（本次卡顿 CPU 饱和的直接来源）。
        if (!(state & (BR_SSL_SENDAPP | BR_SSL_RECVAPP | BR_SSL_SENDREC | BR_SSL_RECVREC))) {
            return 0;
        }
        br_ssl_engine_flush(engine_, 0);
        if (br_ssl_engine_current_state(engine_) == state) {
            return 0;  // flush 未能改变引擎状态 ⇒ 本轮无进展，退出而非空转
        }
    }
}

bool TlsEngine::doHandshake()
{
    if (handshakeDone_) return true;

    int r = runUntil(BR_SSL_SENDAPP | BR_SSL_RECVAPP);
    if (r == 1) {
        handshakeDone_ = true;
        LOGI("tls handshake done (role=%s)",
             role_ == TlsRole::Server ? "server" : "client");
        return true;
    }
    return false;
}

ssize_t TlsEngine::read(std::vector<uint8_t> &buf)
{
    if (!handshakeDone_) return -1;

    int r = runUntil(BR_SSL_RECVAPP);
    if (r < 0) return -1;
    if (r == 1) {
        size_t len;
        unsigned char *appBuf = br_ssl_engine_recvapp_buf(engine_, &len);
        if (len > buf.size()) len = buf.size();
        std::memcpy(buf.data(), appBuf, len);
        br_ssl_engine_recvapp_ack(engine_, len);
        return static_cast<ssize_t>(len);
    }
    // r == 0：引擎在等更多 socket 数据，但 write 路径可能暂存过应用数据
    if (!pendingApp_.empty()) {
        size_t n = pendingApp_.size();
        if (n > buf.size()) n = buf.size();
        std::memcpy(buf.data(), pendingApp_.data(), n);
        pendingApp_.erase(pendingApp_.begin(), pendingApp_.begin() + n);
        return static_cast<ssize_t>(n);
    }
    return 0;
}

// 非阻塞尽力写（详见头文件语义）。旧实现是「拷贝一次 + 30s 睡眠重试」，
// 会把 >16 KiB 的帧截断并污染后续帧流（REVIEW §4 P1-3），且在 JS 主线程上阻塞
// 最长 30 s（§4 P1-6）。现在只做一次尽力，剩余字节由上层 TX 队列在 EPOLLOUT 续传。
ssize_t TlsEngine::write(const uint8_t *data, size_t len)
{
    if (!handshakeDone_) return -1;
    if (len == 0) return 0;

    int r = runUntil(BR_SSL_SENDAPP);
    if (r < 0) return -1;
    if (r == 0) return 0;  // 引擎暂不可写（输出缓冲满 / socket 不可写）

    size_t avail;
    unsigned char *appBuf = br_ssl_engine_sendapp_buf(engine_, &avail);
    if (avail > len) avail = len;
    std::memcpy(appBuf, data, avail);
    br_ssl_engine_sendapp_ack(engine_, avail);
    br_ssl_engine_flush(engine_, 0);

    // 尽力泵到 socket；EAGAIN 时记录留在引擎缓冲，等待 EPOLLOUT / tick 续传
    if (!pump()) {
        return -1;
    }
    return static_cast<ssize_t>(avail);
}

// 推进发送侧状态机：把 SENDREC 里残留的加密记录写出。
// 无待发数据时是廉价空操作（引擎处于 SENDAPP 即返回）。
bool TlsEngine::pump()
{
    if (!handshakeDone_) return true;
    int r = runUntil(BR_SSL_SENDAPP);
    return r >= 0;
}

} // namespace kdeconnect
