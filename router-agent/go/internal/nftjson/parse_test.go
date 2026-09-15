package nftjson

import (
	"testing"
)

func intPtr(n int) *int { return &n }

func TestParse_EmptyFallback(t *testing.T) {
	// This is exactly what agent-dispatch.sh emits when the set is missing
	// or nft itself fails: `nft -j list set ... || echo '{"nftables":[]}'`.
	got, err := Parse([]byte(`{"nftables":[]}`))
	if err != nil {
		t.Fatalf("Parse() error = %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("Parse() = %#v, want empty slice", got)
	}
}

func TestParse_MixedPermanentAndTimeout_IntegerExpires(t *testing.T) {
	// A realistic `nft -j list set` payload for
	// `type ipv4_addr; flags timeout;` with one permanent (bare string)
	// element and one timed-out element whose "expires" is a plain integer
	// number of seconds.
	raw := `{
		"nftables": [
			{"metainfo": {"version": "1.0.9", "release_name": "Old Doc Yak", "json_schema_version": 1}},
			{
				"set": {
					"family": "ip",
					"name": "allowed_clients",
					"table": "captive",
					"type": "ipv4_addr",
					"handle": 3,
					"flags": ["timeout"],
					"elem": [
						"192.168.1.50",
						{"elem": {"val": "192.168.1.146", "expires": 1740, "timeout": 1800}}
					]
				}
			}
		]
	}`

	got, err := Parse([]byte(raw))
	if err != nil {
		t.Fatalf("Parse() error = %v", err)
	}

	want := []Client{
		{IP: "192.168.1.50", Permanent: true, ExpiresInSec: nil},
		{IP: "192.168.1.146", Permanent: false, ExpiresInSec: intPtr(1740)},
	}

	if len(got) != len(want) {
		t.Fatalf("Parse() returned %d clients, want %d: %#v", len(got), len(want), got)
	}
	for i := range want {
		assertClientEqual(t, i, got[i], want[i])
	}
}

func TestParse_DurationStringExpires(t *testing.T) {
	// Some nft versions render "expires" as a human duration string instead
	// of a raw integer.
	raw := `{
		"nftables": [
			{
				"set": {
					"family": "ip",
					"name": "allowed_clients",
					"table": "captive",
					"type": "ipv4_addr",
					"elem": [
						{"elem": {"val": "10.0.0.5", "expires": "29m50s"}},
						{"elem": {"val": "10.0.0.6", "expires": "1h2m3s"}},
						{"elem": {"val": "10.0.0.7", "expires": "45s"}},
						{"elem": {"val": "10.0.0.8", "expires": "2h"}}
					]
				}
			}
		]
	}`

	got, err := Parse([]byte(raw))
	if err != nil {
		t.Fatalf("Parse() error = %v", err)
	}

	want := []Client{
		{IP: "10.0.0.5", Permanent: false, ExpiresInSec: intPtr(29*60 + 50)},
		{IP: "10.0.0.6", Permanent: false, ExpiresInSec: intPtr(3600 + 2*60 + 3)},
		{IP: "10.0.0.7", Permanent: false, ExpiresInSec: intPtr(45)},
		{IP: "10.0.0.8", Permanent: false, ExpiresInSec: intPtr(2 * 3600)},
	}

	if len(got) != len(want) {
		t.Fatalf("Parse() returned %d clients, want %d: %#v", len(got), len(want), got)
	}
	for i := range want {
		assertClientEqual(t, i, got[i], want[i])
	}
}

func TestParse_NoSetEntry(t *testing.T) {
	// A document with only metainfo and no "set" object at all (shouldn't
	// happen from agent-dispatch.sh, but the parser should tolerate it
	// rather than panic).
	raw := `{"nftables": [{"metainfo": {"version": "1.0.9"}}]}`
	got, err := Parse([]byte(raw))
	if err != nil {
		t.Fatalf("Parse() error = %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("Parse() = %#v, want empty slice", got)
	}
}

func TestParse_UnrecognizedElementShape(t *testing.T) {
	raw := `{"nftables": [{"set": {"elem": [42]}}]}`
	if _, err := Parse([]byte(raw)); err == nil {
		t.Fatal("Parse() error = nil, want error for unrecognized element shape")
	}
}

func TestParse_InvalidJSON(t *testing.T) {
	if _, err := Parse([]byte(`not json`)); err == nil {
		t.Fatal("Parse() error = nil, want error for invalid JSON")
	}
}

func assertClientEqual(t *testing.T, i int, got, want Client) {
	t.Helper()
	if got.IP != want.IP || got.Permanent != want.Permanent {
		t.Errorf("client[%d] = %#v, want %#v", i, got, want)
		return
	}
	switch {
	case got.ExpiresInSec == nil && want.ExpiresInSec == nil:
		// ok
	case got.ExpiresInSec == nil || want.ExpiresInSec == nil:
		t.Errorf("client[%d].ExpiresInSec = %v, want %v", i, ptrOrNil(got.ExpiresInSec), ptrOrNil(want.ExpiresInSec))
	case *got.ExpiresInSec != *want.ExpiresInSec:
		t.Errorf("client[%d].ExpiresInSec = %d, want %d", i, *got.ExpiresInSec, *want.ExpiresInSec)
	}
}

func ptrOrNil(p *int) any {
	if p == nil {
		return nil
	}
	return *p
}
