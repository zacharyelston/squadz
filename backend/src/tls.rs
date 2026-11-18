//! HTTPS support
//!
//! Browsers only expose geolocation and WebCrypto to pages loaded over HTTPS
//! (or from localhost), so a server reached by LAN/mesh IP has to speak TLS.
//! With no certificate supplied, a self-signed one is generated once and kept
//! on disk so phones only have to accept it the first time.

use std::fs;
use std::path::Path;

use anyhow::Context;
use chrono::{Datelike, Duration, Utc};
use axum_server::tls_rustls::RustlsConfig;
use tracing::info;

use crate::config::Config;

const VALID_DAYS: i64 = 820;
const GENERATED_CN: &str = "Squadz self-signed";

fn ymd(t: chrono::DateTime<Utc>) -> time::OffsetDateTime {
    rcgen::date_time_ymd(t.year(), t.month() as u8, t.day() as u8)
}

/// True for a certificate this server generated that is within 30 days of its
/// end date. Certificates supplied by the operator are never touched.
fn is_expiring_generated_cert(cert: &Path) -> bool {
    let Ok(pem) = fs::read(cert) else { return false };
    let Ok((_, pem)) = x509_parser::pem::parse_x509_pem(&pem) else { return false };
    let Ok(parsed) = pem.parse_x509() else { return false };
    let ours = parsed
        .subject()
        .iter_common_name()
        .any(|cn| cn.as_str() == Ok(GENERATED_CN));
    let cutoff = (Utc::now() + Duration::days(30)).timestamp();
    ours && parsed.validity().not_after.timestamp() < cutoff
}

pub async fn load_or_generate(config: &Config) -> anyhow::Result<RustlsConfig> {
    // A process-wide provider may already be installed; that is fine.
    let _ = rustls::crypto::ring::default_provider().install_default();

    let (cert, key) = (&config.tls_cert, &config.tls_key);
    if cert.exists() && key.exists() && is_expiring_generated_cert(cert) {
        info!("Self-signed TLS certificate {} is near expiry; regenerating", cert.display());
        fs::remove_file(cert)?;
        fs::remove_file(key)?;
    }
    match (cert.exists(), key.exists()) {
        (true, true) => info!("Using TLS certificate {}", cert.display()),
        (false, false) => generate(cert, key, &config.tls_hosts)?,
        _ => anyhow::bail!(
            "only one of {} and {} exists; supply both or neither",
            cert.display(),
            key.display()
        ),
    }

    RustlsConfig::from_pem_file(cert, key)
        .await
        .with_context(|| format!("loading TLS certificate {}", cert.display()))
}

fn generate(cert: &Path, key: &Path, hosts: &[String]) -> anyhow::Result<()> {
    // Apple platforms reject server certificates valid for more than 825 days
    // or lacking the serverAuth extended key usage, so set both explicitly.
    let mut params = rcgen::CertificateParams::new(hosts.to_vec())
        .context("building certificate parameters")?;
    let now = Utc::now();
    params.not_before = ymd(now - Duration::days(1));
    params.not_after = ymd(now + Duration::days(VALID_DAYS));
    params.extended_key_usages = vec![rcgen::ExtendedKeyUsagePurpose::ServerAuth];
    params
        .distinguished_name
        .push(rcgen::DnType::CommonName, GENERATED_CN);
    let key_pair = rcgen::KeyPair::generate().context("generating TLS key")?;
    let certificate = params
        .self_signed(&key_pair)
        .context("generating self-signed certificate")?;

    for path in [cert, key] {
        if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
            fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        }
    }
    write_private(key, key_pair.serialize_pem().as_bytes())?;
    fs::write(cert, certificate.pem()).with_context(|| format!("writing {}", cert.display()))?;

    info!(
        "Generated self-signed TLS certificate {} for {}",
        cert.display(),
        hosts.join(", ")
    );
    Ok(())
}

#[cfg(unix)]
fn write_private(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;

    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("writing {}", path.display()))?;
    file.write_all(bytes)?;
    Ok(())
}

#[cfg(not(unix))]
fn write_private(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    fs::write(path, bytes).with_context(|| format!("writing {}", path.display()))
}
