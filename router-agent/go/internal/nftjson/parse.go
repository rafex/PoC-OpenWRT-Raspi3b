// Package nftjson parses the JSON emitted by `nft -j list set` for the
// router's "ip captive allowed_clients" set (a `type ipv4_addr; flags
// timeout;` set) into a flat list of clients.
//
// libnftables JSON schema, as relevant here: the top-level document is
// {"nftables": [...]}, an array of "objects" of which we care about the one
// shaped {"set": {..., "elem": [...]}}. Each entry in "elem" is either:
//
//   - a bare JSON string, e.g. "192.168.1.50" — an element with no timeout
//     (permanent), OR
//   - an object {"elem": {"val": "192.168.1.146", "expires": 1740, ...}} —
//     an element with an active timeout, where "expires" is the remaining
//     time. Depending on nft version this shows up either as a plain
//     integer number of seconds, or as a duration string such as "29m50s",
//     "1h2m3s", or "45s".
//
// Presence of an "expires" field is what we key off of to decide
// permanent vs. not — not the "timeout" field, since "timeout" (the
// configured timeout when the element was added) can be present without
// "expires" in some nft output modes, whereas "expires" only appears while
// a timeout is actually counting down.
package nftjson

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
)

// Client is one element of the "allowed_clients" nftables set.
type Client struct {
	IP           string `json:"ip"`
	Permanent    bool   `json:"permanent"`
	ExpiresInSec *int   `json:"expires_in_sec"`
}

type nftablesDoc struct {
	Nftables []nftablesEntry `json:"nftables"`
}

type nftablesEntry struct {
	Set *nftSet `json:"set"`
}

type nftSet struct {
	Elem []json.RawMessage `json:"elem"`
}

type elemWrapper struct {
	Elem elemDetail `json:"elem"`
}

type elemDetail struct {
	Val     string          `json:"val"`
	Expires json.RawMessage `json:"expires"`
}

var durationRe = regexp.MustCompile(`^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$`)

// Parse parses raw `nft -j list set` output (or the dispatcher's
// `{"nftables":[]}` fallback for a missing/empty set) into a list of
// clients. It is defensive about unrecognized element shapes: rather than
// silently dropping data it doesn't understand, it returns an error so the
// caller surfaces a router_command_failed rather than a subtly wrong
// client list.
func Parse(raw []byte) ([]Client, error) {
	var doc nftablesDoc
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("nftjson: invalid nft -j document: %w", err)
	}

	clients := make([]Client, 0)
	for _, entry := range doc.Nftables {
		if entry.Set == nil {
			continue
		}
		for _, rawElem := range entry.Set.Elem {
			c, err := parseElem(rawElem)
			if err != nil {
				return nil, err
			}
			clients = append(clients, c)
		}
	}
	return clients, nil
}

func parseElem(raw json.RawMessage) (Client, error) {
	// Bare string form: a permanent element with no timeout metadata at all.
	var bare string
	if err := json.Unmarshal(raw, &bare); err == nil {
		return Client{IP: bare, Permanent: true, ExpiresInSec: nil}, nil
	}

	var wrapper elemWrapper
	if err := json.Unmarshal(raw, &wrapper); err != nil || wrapper.Elem.Val == "" {
		return Client{}, fmt.Errorf("nftjson: unrecognized set element shape: %s", raw)
	}

	if len(wrapper.Elem.Expires) == 0 {
		return Client{IP: wrapper.Elem.Val, Permanent: true, ExpiresInSec: nil}, nil
	}

	secs, err := parseExpires(wrapper.Elem.Expires)
	if err != nil {
		return Client{}, err
	}
	return Client{IP: wrapper.Elem.Val, Permanent: false, ExpiresInSec: &secs}, nil
}

// parseExpires handles both JSON encodings nft is known to use for the
// "expires" field: a plain integer number of seconds, or a duration string
// like "29m50s".
func parseExpires(raw json.RawMessage) (int, error) {
	var n int
	if err := json.Unmarshal(raw, &n); err == nil {
		return n, nil
	}

	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		secs, err := parseDurationString(s)
		if err != nil {
			return 0, fmt.Errorf("nftjson: unrecognized expires duration %q: %w", s, err)
		}
		return secs, nil
	}

	return 0, fmt.Errorf("nftjson: unrecognized expires value: %s", raw)
}

// parseDurationString parses nft's "XhYmZs" duration format (any of the
// three components may be absent, but at least one must be present).
func parseDurationString(s string) (int, error) {
	m := durationRe.FindStringSubmatch(s)
	if m == nil || (m[1] == "" && m[2] == "" && m[3] == "") {
		return 0, fmt.Errorf("does not match XhYmZs")
	}
	total := 0
	if m[1] != "" {
		h, _ := strconv.Atoi(m[1])
		total += h * 3600
	}
	if m[2] != "" {
		mm, _ := strconv.Atoi(m[2])
		total += mm * 60
	}
	if m[3] != "" {
		ss, _ := strconv.Atoi(m[3])
		total += ss
	}
	return total, nil
}
