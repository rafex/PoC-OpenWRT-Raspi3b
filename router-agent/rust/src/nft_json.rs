//! Parser for the `nft -j list set` JSON emitted by `agent-dispatch.sh list`.
//!
//! Shape (nftables JSON schema, abbreviated to what we actually consume):
//!
//! ```json
//! {
//!   "nftables": [
//!     { "metainfo": { ... } },
//!     { "set": {
//!         "family": "ip", "name": "allowed_clients", "table": "captive",
//!         "elem": [
//!           "192.168.1.50",
//!           { "elem": { "val": "192.168.1.146", "expires": 1740 } }
//!         ]
//!     } }
//!   ]
//! }
//! ```
//!
//! A set element is either a bare string (a permanent element with no
//! timeout) or an object `{"elem": {"val": ..., "expires": ...}}`. When
//! `expires` is absent the element is permanent. `expires` itself may be
//! reported by nft either as an integer number of seconds or as a duration
//! string such as `"29m50s"`, `"1h"`, `"45s"` depending on nft version — we
//! handle both.
//!
//! An empty/absent set (e.g. the dispatcher's `{"nftables":[]}` fallback
//! when the table doesn't exist yet) parses to an empty client list, not an
//! error.

use serde::Serialize;
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ClientEntry {
    pub ip: String,
    pub permanent: bool,
    // Always present (as `null` when absent), matching the Go sibling's
    // `*int` field with no `omitempty` tag — unlike StatusResponse's
    // optional fields, this key is never omitted.
    pub expires_in_sec: Option<u64>,
}

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum NftParseError {
    #[error("invalid JSON: {0}")]
    Json(String),
    #[error("set element missing required field: {0}")]
    MissingField(&'static str),
    #[error("set element has unexpected shape: {0}")]
    UnexpectedShape(String),
    #[error("could not parse expires value: {0}")]
    InvalidExpires(String),
}

impl From<serde_json::Error> for NftParseError {
    fn from(e: serde_json::Error) -> Self {
        NftParseError::Json(e.to_string())
    }
}

/// Parse the raw stdout of `nft -j list set ...` into a flat client list.
pub fn parse_nft_list_json(raw: &str) -> Result<Vec<ClientEntry>, NftParseError> {
    let root: Value = serde_json::from_str(raw)?;

    let Some(nftables) = root.get("nftables").and_then(Value::as_array) else {
        return Ok(Vec::new());
    };

    // Accumulate across every "set" entry present (in practice there is
    // exactly one, since the dispatcher runs `nft -j list set <table> <set>`
    // for one specific set), tolerating entries with no "set" key at all
    // (e.g. a leading {"metainfo": {...}} object) rather than erroring.
    let mut clients = Vec::new();
    for item in nftables {
        let Some(set) = item.get("set") else {
            continue;
        };
        let Some(elems) = set.get("elem").and_then(Value::as_array) else {
            // A set with no `elem` key at all has no members.
            continue;
        };
        for e in elems {
            clients.push(parse_element(e)?);
        }
    }

    Ok(clients)
}

fn parse_element(e: &Value) -> Result<ClientEntry, NftParseError> {
    match e {
        Value::String(ip) => Ok(ClientEntry {
            ip: ip.clone(),
            permanent: true,
            expires_in_sec: None,
        }),
        Value::Object(_) => {
            let elem = e.get("elem").ok_or(NftParseError::MissingField("elem"))?;
            let ip = elem
                .get("val")
                .and_then(Value::as_str)
                .ok_or(NftParseError::MissingField("elem.val"))?
                .to_string();

            match elem.get("expires") {
                None => Ok(ClientEntry {
                    ip,
                    permanent: true,
                    expires_in_sec: None,
                }),
                Some(v) => {
                    let secs = parse_expires(v)?;
                    Ok(ClientEntry {
                        ip,
                        permanent: false,
                        expires_in_sec: Some(secs),
                    })
                }
            }
        }
        other => Err(NftParseError::UnexpectedShape(other.to_string())),
    }
}

fn parse_expires(v: &Value) -> Result<u64, NftParseError> {
    if let Some(n) = v.as_u64() {
        return Ok(n);
    }
    if let Some(f) = v.as_f64()
        && f >= 0.0
    {
        return Ok(f as u64);
    }
    if let Some(s) = v.as_str() {
        return parse_duration_string(s);
    }
    Err(NftParseError::InvalidExpires(v.to_string()))
}

/// Parse a duration string like `"29m50s"`, `"1h"`, `"1h2m3s"`, `"45s"`
/// into a total number of seconds. Each component is `<digits><unit>`
/// with unit in {h, m, s}, concatenated with no separator.
fn parse_duration_string(s: &str) -> Result<u64, NftParseError> {
    let mut total: u64 = 0;
    let mut digits = String::new();
    let mut saw_unit = false;

    for c in s.chars() {
        if c.is_ascii_digit() {
            digits.push(c);
            continue;
        }
        if digits.is_empty() {
            return Err(NftParseError::InvalidExpires(s.to_string()));
        }
        let n: u64 = digits
            .parse()
            .map_err(|_| NftParseError::InvalidExpires(s.to_string()))?;
        digits.clear();
        match c {
            'h' => total += n * 3600,
            'm' => total += n * 60,
            's' => total += n,
            _ => return Err(NftParseError::InvalidExpires(s.to_string())),
        }
        saw_unit = true;
    }

    if !digits.is_empty() || !saw_unit {
        return Err(NftParseError::InvalidExpires(s.to_string()));
    }

    Ok(total)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_nftables_array_yields_no_clients() {
        let raw = r#"{"nftables":[]}"#;
        assert_eq!(parse_nft_list_json(raw).unwrap(), Vec::new());
    }

    #[test]
    fn mixed_permanent_string_and_timeout_object_integer_seconds() {
        let raw = r#"
        {
          "nftables": [
            {"metainfo": {"version": "1.0.9", "release_name": "Old Doc's Data"}},
            {"set": {
              "family": "ip",
              "name": "allowed_clients",
              "table": "captive",
              "type": "ipv4_addr",
              "handle": 3,
              "elem": [
                "192.168.1.50",
                {"elem": {"val": "192.168.1.146", "expires": 1740}}
              ]
            }}
          ]
        }
        "#;

        let clients = parse_nft_list_json(raw).unwrap();
        assert_eq!(
            clients,
            vec![
                ClientEntry {
                    ip: "192.168.1.50".to_string(),
                    permanent: true,
                    expires_in_sec: None,
                },
                ClientEntry {
                    ip: "192.168.1.146".to_string(),
                    permanent: false,
                    expires_in_sec: Some(1740),
                },
            ]
        );
    }

    #[test]
    fn expires_as_duration_string_minutes_seconds() {
        let raw = r#"
        {"nftables":[{"set":{"elem":[
            {"elem":{"val":"10.0.0.5","expires":"29m50s"}}
        ]}}]}
        "#;
        let clients = parse_nft_list_json(raw).unwrap();
        assert_eq!(clients.len(), 1);
        assert_eq!(clients[0].ip, "10.0.0.5");
        assert!(!clients[0].permanent);
        assert_eq!(clients[0].expires_in_sec, Some(29 * 60 + 50));
    }

    #[test]
    fn expires_as_duration_string_hours_minutes_seconds() {
        let raw =
            r#"{"nftables":[{"set":{"elem":[{"elem":{"val":"10.0.0.6","expires":"1h2m3s"}}]}}]}"#;
        let clients = parse_nft_list_json(raw).unwrap();
        assert_eq!(clients[0].expires_in_sec, Some(3600 + 120 + 3));
    }

    #[test]
    fn expires_as_duration_string_hours_only() {
        let raw = r#"{"nftables":[{"set":{"elem":[{"elem":{"val":"10.0.0.7","expires":"2h"}}]}}]}"#;
        let clients = parse_nft_list_json(raw).unwrap();
        assert_eq!(clients[0].expires_in_sec, Some(7200));
    }

    #[test]
    fn set_with_no_elem_key_yields_no_clients() {
        let raw =
            r#"{"nftables":[{"set":{"family":"ip","name":"allowed_clients","table":"captive"}}]}"#;
        assert_eq!(parse_nft_list_json(raw).unwrap(), Vec::new());
    }

    #[test]
    fn all_permanent_elements_as_bare_strings() {
        let raw = r#"{"nftables":[{"set":{"elem":["192.168.1.10","192.168.1.11"]}}]}"#;
        let clients = parse_nft_list_json(raw).unwrap();
        assert_eq!(clients.len(), 2);
        assert!(clients.iter().all(|c| c.permanent));
    }

    #[test]
    fn malformed_json_is_an_error() {
        let raw = "not json";
        assert!(parse_nft_list_json(raw).is_err());
    }

    #[test]
    fn invalid_duration_string_is_an_error() {
        let raw =
            r#"{"nftables":[{"set":{"elem":[{"elem":{"val":"10.0.0.8","expires":"soon"}}]}}]}"#;
        assert!(parse_nft_list_json(raw).is_err());
    }

    #[test]
    fn document_with_no_set_entry_at_all_yields_no_clients() {
        // Shouldn't happen from agent-dispatch.sh, but the parser should
        // tolerate it rather than error.
        let raw = r#"{"nftables": [{"metainfo": {"version": "1.0.9"}}]}"#;
        assert_eq!(parse_nft_list_json(raw).unwrap(), Vec::new());
    }

    #[test]
    fn unrecognized_element_shape_bare_number_is_an_error() {
        let raw = r#"{"nftables": [{"set": {"elem": [42]}}]}"#;
        assert!(parse_nft_list_json(raw).is_err());
    }
}
