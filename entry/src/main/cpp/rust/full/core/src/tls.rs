// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! rustls 封装：KDE Connect 的双向自签证书模型。
//!
//! 与 BearSSL 基线的语义对齐：
//! - 拨号方 = TLS server（`TlsRole::Server`），必须请求/捕获对端证书；
//! - 被拨方 = TLS client（`TlsRole::Client`），接受对端自签证书并捕获；
//! - 证书链校验不是信任决策：协议用 CN == deviceId + ArkTS TrustStore 钉扎。
//!   因此两个 verifier 都「接受任意证书」，但仍委托 rustls 校验握手签名。
//! - 对端叶证书在握手完成后从 `peer_certificates()` 取；这是唯一的证书来源
//!   （identity 帧不含证书）。

use std::io::{BufReader, Read, Write};
use std::sync::Arc;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::ring;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{
    ClientConfig, ClientConnection, DigitallySignedStruct, DistinguishedName, Error, RootCertStore,
    ServerConfig, ServerConnection, SignatureScheme,
};

use crate::cert_ext;

#[derive(Clone)]
pub struct TlsContext {
    pub server: Arc<ServerConfig>,
    pub client: Arc<ClientConfig>,
    pub cert_der: CertificateDer<'static>,
}

impl std::fmt::Debug for TlsContext {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TlsContext")
            .field("cert_der_len", &self.cert_der.as_ref().len())
            .finish()
    }
}

#[derive(Debug)]
struct AcceptAnyServerVerifier;

impl ServerCertVerifier for AcceptAnyServerVerifier {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &ring::default_provider().signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &ring::default_provider().signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

/// CertificateRequest 的占位 CA 名（CN=KDE Connect 的 RDNSequence 内容）。
///
/// 为什么不能返回空列表：SunJSSE（Android）会按 CA 列表过滤客户端证书，空列表可能
/// 导致对端**不出示证书**，从而 CN 校验失败。Qt/OpenSSL 不按列表过滤，但占位名对两者
/// 都无副作用（与旧 BearSSL 基线的 `tolerateNoCert` + placeholder 语义一致）。
fn client_ca_hint() -> DistinguishedName {
    // SET { SEQUENCE { OID 2.5.4.3, UTF8String "KDE Connect" } }
    // 长度核对：OID TLV=5B，UTF8String TLV=13B ⇒ SEQUENCE 内容 18B (0x12)；
    // 加头 2B ⇒ SET 内容 20B (0x14)。写错一个字节 Qt 会回 TLS decode_error。
    const CN_RDN_SEQUENCE: &[u8] = &[
        0x31, 0x14, // SET
        0x30, 0x12, // SEQUENCE (AttributeTypeAndValue)
        0x06, 0x03, 0x55, 0x04, 0x03, // OID 2.5.4.3
        0x0c, 0x0b, b'K', b'D', b'E', b' ', b'C', b'o', b'n', b'n', b'e', b'c', b't',
    ];
    DistinguishedName::in_sequence(CN_RDN_SEQUENCE)
}

#[derive(Debug)]
struct AcceptAnyClientVerifier;

impl ClientCertVerifier for AcceptAnyClientVerifier {
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        static HINT: std::sync::LazyLock<Vec<DistinguishedName>> =
            std::sync::LazyLock::new(|| vec![client_ca_hint()]);
        &HINT
    }

    fn verify_client_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> Result<ClientCertVerified, Error> {
        Ok(ClientCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &ring::default_provider().signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &ring::default_provider().signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }

    fn offer_client_auth(&self) -> bool {
        true
    }

    fn client_auth_mandatory(&self) -> bool {
        // 容忍缺失（与 C++ `tolerateNoCert=true` 对齐）；上层用 CN 校验 fail-closed。
        false
    }
}

fn read_certs(pem: &str) -> Result<Vec<CertificateDer<'static>>, String> {
    let mut reader = BufReader::new(pem.as_bytes());
    let certs: Vec<_> = rustls_pemfile::certs(&mut reader)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| format!("parse cert PEM: {e}"))?;
    if certs.is_empty() {
        return Err("certPem contains no CERTIFICATE".to_owned());
    }
    Ok(certs)
}

fn read_key(pem: &str) -> Result<PrivateKeyDer<'static>, String> {
    let mut reader = BufReader::new(pem.as_bytes());
    rustls_pemfile::private_key(&mut reader)
        .map_err(|e| format!("parse key PEM: {e}"))?
        .ok_or_else(|| "keyPem contains no private key".to_owned())
}

pub fn build_context(cert_pem: &str, key_pem: &str) -> Result<TlsContext, String> {
    let certs = read_certs(cert_pem)?;
    let key = read_key(key_pem)?;
    let provider = Arc::new(ring::default_provider());

    // 显式 TLS1.2 + TLS1.3：KDE/Android 都有 TLS1.2 上限的实现；android 侧文档明确。
    let versions: &[&'static rustls::SupportedProtocolVersion] =
        &[&rustls::version::TLS13, &rustls::version::TLS12];

    let server = ServerConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(versions)
        .map_err(|e| format!("server protocol versions: {e}"))?
        .with_client_cert_verifier(Arc::new(AcceptAnyClientVerifier))
        .with_single_cert(certs.clone(), key.clone_key())
        .map_err(|e| format!("server config: {e}"))?;

    let client = ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(versions)
        .map_err(|e| format!("client protocol versions: {e}"))?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AcceptAnyServerVerifier))
        .with_client_auth_cert(certs.clone(), key)
        .map_err(|e| format!("client config: {e}"))?;

    Ok(TlsContext {
        server: Arc::new(server),
        client: Arc::new(client),
        cert_der: certs[0].clone(),
    })
}

/// 拨号方（TLS server）。`ServerName` 不需要。
pub fn server_connection(ctx: &TlsContext) -> Result<ServerConnection, Error> {
    ServerConnection::new(ctx.server.clone())
}

/// 被拨方（TLS client）。对端证书接受任意自签，`server_name` 仅用于 SNI（KDE 不用）。
pub fn client_connection(ctx: &TlsContext, host: &str) -> Result<ClientConnection, Error> {
    let name = ServerName::try_from(host.to_owned())
        .or_else(|_| ServerName::try_from("kdeconnect.invalid".to_owned()))
        .map_err(|e| Error::General(e.to_string()))?;
    ClientConnection::new(ctx.client.clone(), name)
}

/// 握手完成后取对端叶证书 DER。
pub fn peer_leaf_server(conn: &ServerConnection) -> Option<Vec<u8>> {
    conn.peer_certificates()
        .and_then(|certs| certs.first())
        .map(|c| c.as_ref().to_vec())
}

pub fn peer_leaf_client(conn: &ClientConnection) -> Option<Vec<u8>> {
    conn.peer_certificates()
        .and_then(|certs| certs.first())
        .map(|c| c.as_ref().to_vec())
}

/// 对端叶证书 subject CN。
pub fn peer_cn_server(conn: &ServerConnection) -> Option<String> {
    peer_leaf_server(conn).and_then(|der| cert_ext::subject_cn_from_der(&der))
}

pub fn peer_cn_client(conn: &ClientConnection) -> Option<String> {
    peer_leaf_client(conn).and_then(|der| cert_ext::subject_cn_from_der(&der))
}

/// 本机叶证书 PEM（与 `generateCert` 同一份）。
pub fn own_cert_pem(ctx: &TlsContext) -> String {
    cert_ext::cert_pem_from_der(ctx.cert_der.as_ref())
}

/// 便于测试：空 RootCertStore 仅用于满足类型系统的地方（当前未使用）。
#[allow(dead_code)]
fn empty_root_store() -> RootCertStore {
    RootCertStore::empty()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx() -> TlsContext {
        let pair = crate::cert_gen::generate_self_signed_ec(
            "0123456789abcdef0123456789abcdef",
            10,
        )
        .unwrap();
        build_context(&pair.cert_pem, &pair.key_pem).unwrap()
    }

    #[test]
    fn builds_both_configs() {
        let ctx = ctx();
        assert!(own_cert_pem(&ctx).starts_with("-----BEGIN CERTIFICATE-----"));
        assert!(server_connection(&ctx).is_ok());
        assert!(client_connection(&ctx, "127.0.0.1").is_ok());
    }
}

/// 统一 server/client 两种 rustls 连接，供控制链路与 payload 复用。
pub enum TlsSession {
    Server(ServerConnection),
    Client(ClientConnection),
}

impl TlsSession {
    pub fn read_tls(&mut self, stream: &mut std::net::TcpStream) -> std::io::Result<usize> {
        match self {
            TlsSession::Server(c) => c.read_tls(stream),
            TlsSession::Client(c) => c.read_tls(stream),
        }
    }

    pub fn write_tls(&mut self, stream: &mut std::net::TcpStream) -> std::io::Result<usize> {
        match self {
            TlsSession::Server(c) => c.write_tls(stream),
            TlsSession::Client(c) => c.write_tls(stream),
        }
    }

    pub fn process_new_packets(&mut self) -> Result<(), Error> {
        match self {
            TlsSession::Server(c) => c.process_new_packets().map(|_| ()),
            TlsSession::Client(c) => c.process_new_packets().map(|_| ()),
        }
    }

    pub fn is_handshaking(&self) -> bool {
        match self {
            TlsSession::Server(c) => c.is_handshaking(),
            TlsSession::Client(c) => c.is_handshaking(),
        }
    }

    pub fn wants_write(&self) -> bool {
        match self {
            TlsSession::Server(c) => c.wants_write(),
            TlsSession::Client(c) => c.wants_write(),
        }
    }

    pub fn writer_write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self {
            TlsSession::Server(c) => c.writer().write(buf),
            TlsSession::Client(c) => c.writer().write(buf),
        }
    }

    pub fn reader_read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            TlsSession::Server(c) => c.reader().read(buf),
            TlsSession::Client(c) => c.reader().read(buf),
        }
    }

    pub fn peer_leaf(&self) -> Option<Vec<u8>> {
        match self {
            TlsSession::Server(c) => peer_leaf_server(c),
            TlsSession::Client(c) => peer_leaf_client(c),
        }
    }

    pub fn peer_cn(&self) -> Option<String> {
        self.peer_leaf()
            .and_then(|der| cert_ext::subject_cn_from_der(&der))
    }
}
