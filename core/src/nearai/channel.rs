//! One HTTPS connection to a NEAR AI model host.
//!
//! The attestation, the chat request, and the response signature all travel
//! over the same connection, so the enclave that proved itself is the one that
//! receives the prompt. The certificate must also pass normal WebPKI checks for
//! the host name; the attestation adds to that, it does not replace it.
use std::sync::Arc;
use std::time::Duration;

use http_body_util::{BodyExt, Full, Limited};
use hyper::body::Bytes;
use hyper::client::conn::http1::SendRequest;
use hyper::{Method, Request};
use hyper_util::rt::TokioIo;
use sha2::{Digest, Sha256};
use socket2::{SockRef, TcpKeepalive};
use tokio::net::TcpStream;
use tokio_rustls::TlsConnector;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(20);
/// The chat reply arrives in one piece after minutes of silence; keepalive
/// probes stop routers dropping the idle connection and notice one that's gone.
const KEEPALIVE_IDLE: Duration = Duration::from_secs(60);
const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(20);

pub(crate) struct Channel {
    host: String,
    sender: SendRequest<Full<Bytes>>,
    spki_sha256: [u8; 32],
}

pub(crate) struct Response {
    pub status: u16,
    pub body: Bytes,
}

impl Channel {
    pub async fn open(host: &str) -> Result<Self, String> {
        let server_name = rustls::pki_types::ServerName::try_from(host.to_string())
            .map_err(|_| format!("Invalid host name: {host}"))?;
        let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
        let mut config = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .map_err(|e| format!("TLS setup failed: {e}"))?
        .with_root_certificates(roots)
        .with_no_client_auth();
        config.alpn_protocols = vec![b"http/1.1".to_vec()];

        let connect = async {
            let tcp = TcpStream::connect((host, 443)).await?;
            let keepalive = TcpKeepalive::new().with_time(KEEPALIVE_IDLE).with_interval(KEEPALIVE_INTERVAL);
            SockRef::from(&tcp).set_tcp_keepalive(&keepalive)?;
            TlsConnector::from(Arc::new(config)).connect(server_name, tcp).await
        };
        let tls = tokio::time::timeout(CONNECT_TIMEOUT, connect)
            .await
            .map_err(|_| format!("Timed out connecting to {host}"))?
            .map_err(|e| format!("Could not connect to {host}: {e}"))?;

        let leaf = tls
            .get_ref()
            .1
            .peer_certificates()
            .and_then(|certs| certs.first())
            .ok_or("The server presented no certificate")?;
        let spki_sha256 = spki_sha256(leaf.as_ref())?;

        let (sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(tls))
            .await
            .map_err(|e| format!("HTTP handshake with {host} failed: {e}"))?;
        tokio::spawn(async move {
            let _ = connection.await;
        });
        Ok(Self { host: host.to_string(), sender, spki_sha256 })
    }

    /// Whether the connection can still take a request. Nothing is sent.
    pub async fn is_usable(&mut self) -> bool {
        self.sender.ready().await.is_ok()
    }

    /// SHA-256 of the server certificate's SubjectPublicKeyInfo.
    pub fn spki_sha256(&self) -> [u8; 32] {
        self.spki_sha256
    }

    pub async fn send(
        &mut self,
        method: Method,
        path: &str,
        api_key: Option<&str>,
        body: Option<Vec<u8>>,
        max_response_bytes: usize,
        timeout: Duration,
    ) -> Result<Response, String> {
        let mut request = Request::builder()
            .method(method)
            .uri(path)
            .header(hyper::header::HOST, &self.host)
            .header(hyper::header::ACCEPT, "application/json");
        if let Some(key) = api_key {
            request = request.header(hyper::header::AUTHORIZATION, format!("Bearer {key}"));
        }
        if body.is_some() {
            request = request.header(hyper::header::CONTENT_TYPE, "application/json");
        }
        let request = request
            .body(Full::new(Bytes::from(body.unwrap_or_default())))
            .map_err(|e| format!("Could not build request: {e}"))?;

        let exchange = async {
            self.sender
                .ready()
                .await
                .map_err(|e| format!("Connection to {} closed: {e}", self.host))?;
            let response = self
                .sender
                .send_request(request)
                .await
                .map_err(|e| format!("Request to {} failed: {e}", self.host))?;
            let status = response.status().as_u16();
            let body = Limited::new(response.into_body(), max_response_bytes)
                .collect()
                .await
                .map_err(|e| format!("Could not read response from {}: {e}", self.host))?
                .to_bytes();
            Ok(Response { status, body })
        };
        tokio::time::timeout(timeout, exchange)
            .await
            .map_err(|_| format!("Request to {} timed out", self.host))?
    }
}

pub(crate) fn spki_sha256(cert_der: &[u8]) -> Result<[u8; 32], String> {
    let (_, cert) = x509_parser::parse_x509_certificate(cert_der)
        .map_err(|e| format!("Could not parse the server certificate: {e}"))?;
    Ok(Sha256::digest(cert.tbs_certificate.subject_pki.raw).into())
}
