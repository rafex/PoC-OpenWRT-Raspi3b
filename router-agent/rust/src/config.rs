//! Environment-variable configuration for router-agent.
//!
//! Mirrors the sibling Go implementation's env var names/semantics exactly
//! (see router-agent/go). Fails fast with a clear error message on any
//! missing/invalid required value so a bad deployment never starts serving.

use std::env;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use ipnet::IpNet;

const DEFAULT_LISTEN_ADDR: &str = "0.0.0.0:8443";
const DEFAULT_SSH_PORT: u16 = 22;
const DEFAULT_SSH_USER: &str = "root";
const DEFAULT_SSH_TIMEOUT_MS: u64 = 5000;
const DEFAULT_LOG_LEVEL: &str = "info";

#[derive(Debug, Clone)]
pub struct Config {
    pub listen_addr: SocketAddr,
    pub api_token: String,
    pub allowed_cidrs: Vec<IpNet>,
    pub ssh_host: String,
    pub ssh_port: u16,
    pub ssh_user: String,
    pub ssh_key_path: PathBuf,
    pub ssh_known_hosts_path: PathBuf,
    pub ssh_timeout: Duration,
    pub log_level: String,
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("missing required environment variable {0}")]
    Missing(&'static str),
    #[error("invalid value for {name}: {value:?} ({reason})")]
    Invalid {
        name: &'static str,
        value: String,
        reason: String,
    },
}

fn required(name: &'static str) -> Result<String, ConfigError> {
    match env::var(name) {
        Ok(v) if !v.trim().is_empty() => Ok(v),
        _ => Err(ConfigError::Missing(name)),
    }
}

fn optional(name: &'static str, default: &str) -> String {
    env::var(name)
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| default.to_string())
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let listen_addr_raw = optional("ROUTER_AGENT_LISTEN_ADDR", DEFAULT_LISTEN_ADDR);
        let listen_addr =
            listen_addr_raw
                .parse::<SocketAddr>()
                .map_err(|e| ConfigError::Invalid {
                    name: "ROUTER_AGENT_LISTEN_ADDR",
                    value: listen_addr_raw.clone(),
                    reason: e.to_string(),
                })?;

        let api_token = required("ROUTER_AGENT_API_TOKEN")?;
        if api_token.len() < 8 {
            return Err(ConfigError::Invalid {
                name: "ROUTER_AGENT_API_TOKEN",
                value: "<redacted>".to_string(),
                reason: "token must be at least 8 characters".to_string(),
            });
        }

        let allowed_cidrs_raw = required("ROUTER_AGENT_ALLOWED_CIDRS")?;
        let allowed_cidrs = allowed_cidrs_raw
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(|s| {
                s.parse::<IpNet>().map_err(|e| ConfigError::Invalid {
                    name: "ROUTER_AGENT_ALLOWED_CIDRS",
                    value: s.to_string(),
                    reason: e.to_string(),
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        if allowed_cidrs.is_empty() {
            return Err(ConfigError::Invalid {
                name: "ROUTER_AGENT_ALLOWED_CIDRS",
                value: allowed_cidrs_raw,
                reason: "must contain at least one CIDR".to_string(),
            });
        }

        let ssh_host = required("ROUTER_AGENT_SSH_HOST")?;

        let ssh_port_raw = optional("ROUTER_AGENT_SSH_PORT", &DEFAULT_SSH_PORT.to_string());
        let ssh_port = ssh_port_raw
            .parse::<u16>()
            .map_err(|e| ConfigError::Invalid {
                name: "ROUTER_AGENT_SSH_PORT",
                value: ssh_port_raw.clone(),
                reason: e.to_string(),
            })?;

        let ssh_user = optional("ROUTER_AGENT_SSH_USER", DEFAULT_SSH_USER);

        let ssh_key_path_raw = required("ROUTER_AGENT_SSH_KEY_PATH")?;
        let ssh_key_path = PathBuf::from(&ssh_key_path_raw);
        if !ssh_key_path.is_file() {
            return Err(ConfigError::Invalid {
                name: "ROUTER_AGENT_SSH_KEY_PATH",
                value: ssh_key_path_raw,
                reason: "file does not exist".to_string(),
            });
        }

        let ssh_known_hosts_path_raw = required("ROUTER_AGENT_SSH_KNOWN_HOSTS_PATH")?;
        let ssh_known_hosts_path = PathBuf::from(&ssh_known_hosts_path_raw);
        if !ssh_known_hosts_path.is_file() {
            return Err(ConfigError::Invalid {
                name: "ROUTER_AGENT_SSH_KNOWN_HOSTS_PATH",
                value: ssh_known_hosts_path_raw,
                reason: "file does not exist".to_string(),
            });
        }

        let ssh_timeout_ms_raw = optional(
            "ROUTER_AGENT_SSH_TIMEOUT_MS",
            &DEFAULT_SSH_TIMEOUT_MS.to_string(),
        );
        let ssh_timeout_ms =
            ssh_timeout_ms_raw
                .parse::<u64>()
                .map_err(|e| ConfigError::Invalid {
                    name: "ROUTER_AGENT_SSH_TIMEOUT_MS",
                    value: ssh_timeout_ms_raw.clone(),
                    reason: e.to_string(),
                })?;
        if ssh_timeout_ms == 0 {
            return Err(ConfigError::Invalid {
                name: "ROUTER_AGENT_SSH_TIMEOUT_MS",
                value: ssh_timeout_ms_raw,
                reason: "must be greater than zero".to_string(),
            });
        }

        let log_level = optional("ROUTER_AGENT_LOG_LEVEL", DEFAULT_LOG_LEVEL);

        Ok(Config {
            listen_addr,
            api_token,
            allowed_cidrs,
            ssh_host,
            ssh_port,
            ssh_user,
            ssh_key_path,
            ssh_known_hosts_path,
            ssh_timeout: Duration::from_millis(ssh_timeout_ms),
            log_level,
        })
    }

    pub fn ip_allowed(&self, ip: std::net::IpAddr) -> bool {
        self.allowed_cidrs.iter().any(|net| net.contains(&ip))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ip_allowed_matches_cidr() {
        let cfg = Config {
            listen_addr: DEFAULT_LISTEN_ADDR.parse().unwrap(),
            api_token: "supersecrettoken".to_string(),
            allowed_cidrs: vec![
                "10.20.0.0/24".parse().unwrap(),
                "127.0.0.1/32".parse().unwrap(),
            ],
            ssh_host: "192.168.1.1".to_string(),
            ssh_port: 22,
            ssh_user: "root".to_string(),
            ssh_key_path: PathBuf::from("/dev/null"),
            ssh_known_hosts_path: PathBuf::from("/dev/null"),
            ssh_timeout: Duration::from_millis(5000),
            log_level: "info".to_string(),
        };

        assert!(cfg.ip_allowed("10.20.0.5".parse().unwrap()));
        assert!(cfg.ip_allowed("127.0.0.1".parse().unwrap()));
        assert!(!cfg.ip_allowed("10.20.1.5".parse().unwrap()));
        assert!(!cfg.ip_allowed("8.8.8.8".parse().unwrap()));
    }
}
