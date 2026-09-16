#ifndef KDECONNECT_TLS_ENGINE_H
#define KDECONNECT_TLS_ENGINE_H

#include "net_types.h"
#include "bearssl.h"
#include "bearssl_ssl.h"
#include "bearssl_x509.h"
#include <string>
#include <vector>
#include <cstdint>

namespace kdeconnect {

class TlsEngine;

// X.509 验证上下文包装（REVIEW §8 D2）。br_x509_minimal_context 必须是首成员：
// BearSSL 的 vtable 回调只收到「上下文地址」，其约定就是 vtable 字段的地址 == 上下文地址
// （见 x509_minimal.c 的 container 转换），故可用同一地址反推本包装体，从而携带额外状态。
// 仅前段 x509 会被 br_x509_minimal_init 的 memset 清零（约定：附加字段一律我们自己初始化）。
struct X509Ctx {
    br_x509_minimal_context x509;
    // 对端证书链首个证书（TLS 顺序下即 EE 证书）的原始 DER
    uint8_t leafDer[4096];
    uint32_t leafLen = 0;
    uint32_t curLen = 0;      // 当前证书已累积字节
    uint32_t certIndex = 0;   // 证书序号：0 = EE（只捕获它）
    bool overflow = false;
};

// server 角色的对端（TLS 客户端）证书认证配置（P0-2）。
// 只对 TlsRole::Server 生效；控制连接（tcp_connection）不传即保持旧行为（不请求客户端证书）。
struct ServerClientAuth {
    // 写入 CertificateRequest 的可接受 CA 名 = 对端证书 subject DN 的完整 DER
    // （KDE/Android 均把「对端证书主体」作为 CA 列表，语义对等）。空则用占位名。
    std::vector<uint8_t> caDnDer;
    // true = 对端未出示证书/校验失败时容忍（继续握手，由上层做 CN 校验）；
    // false = 严格模式（BR_SSL_NO_CLIENT_AUTH 直接终止握手）。
    bool tolerateNoCert = false;
};

class TlsEngine {
public:
    TlsEngine(int fd, TlsRole role);
    ~TlsEngine();

    TlsEngine(const TlsEngine &) = delete;
    TlsEngine &operator=(const TlsEngine &) = delete;

    // clientAuth：仅 Server 角色生效；nullptr = 不请求客户端证书（控制连接语义不变）。
    bool init(const std::string &certPem, const std::string &keyPem,
              const ServerClientAuth *clientAuth = nullptr);
    // 推进握手。返回 true 表示完成；false 表示需要更多 socket 数据（EAGAIN）。
    bool doHandshake();
    bool handshakeDone() const { return handshakeDone_; }
    // 引擎是否还有待写出的记录（BR_SSL_SENDREC）。
    // 前置条件（隐式耦合，AtomCode P3）：本判据只看 SENDREC。若应用数据已进引擎但尚未 flush 成
    // 记录（SENDAPP 非零、SENDREC 为零），此处会返回 false —— 现有调用序（先 runUntil/flush 再判断）
    // 下正确；未来改调用序须一并考虑 SENDAPP（注意 SENDAPP 几乎常真，直接纳入会让 EPOLLOUT 常驻，
    // 反而回到本函数要解决的陷阱）。
    // 用途（P0-b2-c）：网络循环**按需**挂/摘 EPOLLOUT —— 只有真有可能写出东西时才注册可写兴趣。
    // 否则 EPOLLET + EPOLLOUT 会在「无可写内容」时被 epoll_wait 每轮重复上报（真机实测连接事件
    // ~1 万次/秒、烧掉约一个核，并把配对 ack 推迟到对端超时，见 DevEco MSG180）。
    bool wantsWrite() const;

    // 对端 EE 证书原始 DER（握手后有效；空 = 未捕获）。
    // WP-2 证书钉扎 / payload 通道「CN == deviceId」校验的取数据口（REVIEW §8 D2）。
    std::vector<uint8_t> peerLeafCertDer() const;
    // 对端 EE 证书 subject CN（握手后有效；空 = 未取到）
    std::string peerCommonName() const;

    // 返回 >0：读到的字节数；0：需要更多 socket 数据；-1：错误
    ssize_t read(std::vector<uint8_t> &buf);
    // 非阻塞尽力写：把数据交给引擎并尽力泵到 socket。
    //   返回 >0：已接收 N 字节（可能仍留在引擎输出缓冲，待 EPOLLOUT 续传）；
    //   返回  0：引擎暂不可写（输出缓冲满 / socket 不可写）→ 调用方稍后重试；
    //   返回 -1：错误。
    // 语义要求：调用方（网络线程）是唯一写者，未接收的字节由上层 TX 队列保留。
    ssize_t write(const uint8_t *data, size_t len);
    // 把引擎里残留的记录尽力发出（TX 队列已空时用于续传）。false = 错误。
    bool pump();
    int lastError() const { return lastError_; }
    // 当前 BearSSL 引擎状态位（BR_SSL_* 组合），诊断用
    unsigned state() const { return engine_ ? br_ssl_engine_current_state(engine_) : 0; }

private:
    int fd_ = -1;
    TlsRole role_;
    bool handshakeDone_ = false;
    int lastError_ = 0;

    br_ssl_server_context serverCtx_;
    br_ssl_client_context clientCtx_;
    X509Ctx x509Ctx_{};
    unsigned char iobuf_[BR_SSL_BUFSIZE_BIDI];
    br_ssl_engine_context *engine_ = nullptr;

    std::vector<uint8_t> certDer_;
    std::vector<uint8_t> keyDer_;
    std::vector<uint8_t> ecKeyData_;
    br_ec_private_key ecKey_{};
    // 引擎持有此结构指针（ssl_hs_server 发证书时读），必须是成员而非 init() 局部变量
    br_x509_certificate certChain_{};
    // 对端 EE 证书的 subject CN 收集槽（由 BearSSL 在解析 EE 证书时填充）
    br_name_element peerCnName_{};
    char peerCnBuf_[128] = {0};
    // server 角色 client-auth：CertificateRequest 里可接受 CA 名的持有者。
    // BearSSL 只链指针不拷贝（bearssl_ssl.h br_ssl_server_set_trust_anchor_names），
    // 故 DN 缓冲与 br_x500_name 都必须是成员。
    std::vector<uint8_t> clientCaDn_;
    br_x500_name clientCaName_{};
    // write 路径路过 RECVAPP 时暂存的应用数据（SENDAPP/RECVAPP 互斥，无法原地继续），read() 后续取出
    std::vector<uint8_t> pendingApp_;

    bool loadCertAndKey(const std::string &certPem, const std::string &keyPem);
    // 返回 1：达到 target 状态；0：EAGAIN；-1：错误
    int runUntil(unsigned target);
};

} // namespace kdeconnect

#endif
